// 静的検査用の最小 JS 字句解析器（テスト専用。node: 組み込みのみ）
//
// なぜ正規表現ではなく字句解析か（lessons #9 / #10）:
//   「コメントや文字列の中の `prepare(` + バッククォート + `${`」は無害、「本物のコード」は有害。
//   これを正規表現で区別すると、コメント内の `don't` や文字列内の `//` で後続が消えて検知漏れになる。
//   検知漏れは誤爆より高コスト。なのでコメント・文字列・テンプレート・正規表現リテラルを
//   正しく読み飛ばす字句解析を置き、検査自体を static.test.mjs の自己診断で縛る。

const REGEX_PREV_KEYWORDS = new Set([
  'return', 'typeof', 'case', 'of', 'in', 'delete', 'void', 'throw', 'new', 'else', 'do', 'yield', 'await',
]);
const REGEX_PREV_PUNCT = new Set(['(', ',', '=', ':', '[', '!', '&', '|', '?', '{', '}', ';', '+', '-', '*', '%', '<', '>', '~', '^']);

const isIdStart = (c) => /[A-Za-z_$]/.test(c);
const isIdPart = (c) => /[A-Za-z0-9_$]/.test(c);

/**
 * @returns {{tokens: object[], end: number}}
 * token: {type:'id'|'str'|'tpl'|'num'|'regex'|'punct', value, hasSubst?, inner?}
 */
function lex(src, start, stopAtBrace) {
  const tokens = [];
  let i = start;
  let braceDepth = 0;
  const prevSignificant = () => tokens[tokens.length - 1];

  while (i < src.length) {
    const c = src[i];
    const n = src[i + 1];

    if (/\s/.test(c)) { i += 1; continue; }

    if (c === '/' && n === '/') {
      while (i < src.length && src[i] !== '\n') i += 1;
      continue;
    }
    if (c === '/' && n === '*') {
      const close = src.indexOf('*/', i + 2);
      i = close === -1 ? src.length : close + 2;
      continue;
    }

    if (c === '"' || c === "'") {
      let j = i + 1;
      let value = '';
      while (j < src.length && src[j] !== c && src[j] !== '\n') {
        if (src[j] === '\\') { value += src[j + 1] ?? ''; j += 2; continue; }
        value += src[j];
        j += 1;
      }
      tokens.push({ type: 'str', value });
      i = j + 1;
      continue;
    }

    if (c === '`') {
      let j = i + 1;
      let text = '';
      let hasSubst = false;
      const inner = [];
      while (j < src.length && src[j] !== '`') {
        if (src[j] === '\\') { text += src[j + 1] ?? ''; j += 2; continue; }
        if (src[j] === '$' && src[j + 1] === '{') {
          hasSubst = true;
          const sub = lex(src, j + 2, true);
          inner.push(...sub.tokens);
          j = sub.end + 1;
          continue;
        }
        text += src[j];
        j += 1;
      }
      tokens.push({ type: 'tpl', value: text, hasSubst, inner });
      i = j + 1;
      continue;
    }

    if (c === '/') {
      const prev = prevSignificant();
      const regexAllowed =
        prev === undefined ||
        (prev.type === 'punct' && REGEX_PREV_PUNCT.has(prev.value)) ||
        (prev.type === 'id' && REGEX_PREV_KEYWORDS.has(prev.value));
      if (regexAllowed) {
        let j = i + 1;
        let inClass = false;
        while (j < src.length && src[j] !== '\n') {
          if (src[j] === '\\') { j += 2; continue; }
          if (src[j] === '[') inClass = true;
          else if (src[j] === ']') inClass = false;
          else if (src[j] === '/' && !inClass) break;
          j += 1;
        }
        j += 1;
        while (j < src.length && isIdPart(src[j])) j += 1;
        tokens.push({ type: 'regex', value: src.slice(i, j) });
        i = j;
        continue;
      }
    }

    if (isIdStart(c)) {
      let j = i + 1;
      while (j < src.length && isIdPart(src[j])) j += 1;
      tokens.push({ type: 'id', value: src.slice(i, j) });
      i = j;
      continue;
    }

    if (/[0-9]/.test(c)) {
      let j = i + 1;
      while (j < src.length && /[\w.]/.test(src[j])) j += 1;
      tokens.push({ type: 'num', value: src.slice(i, j) });
      i = j;
      continue;
    }

    if (stopAtBrace) {
      if (c === '{') braceDepth += 1;
      if (c === '}') {
        if (braceDepth === 0) return { tokens, end: i };
        braceDepth -= 1;
      }
    }
    tokens.push({ type: 'punct', value: c });
    i += 1;
  }
  return { tokens, end: i };
}

export function tokenize(src) {
  return lex(src, 0, false).tokens;
}

/** テンプレートの置換式の中のトークンも含め、全レベルを巡回する */
function* walkLevels(tokens) {
  yield tokens;
  for (const t of tokens) {
    if (t.type === 'tpl' && t.inner.length > 0) yield* walkLevels(t.inner);
  }
}

const SQL_PATTERN =
  /\b(SELECT\s[\s\S]*\sFROM|INSERT\s+(OR\s+\w+\s+)?INTO|UPDATE\s+\w+\s+SET|DELETE\s+FROM|CREATE\s+(TABLE|INDEX|UNIQUE)|DROP\s+(TABLE|INDEX)|ALTER\s+TABLE|PRAGMA\s+\w+|REPLACE\s+INTO)\b/i;

/** SQL 文字列に動的な値が混ざりうる書き方を列挙して返す（空配列なら安全） */
export function findSqlInjectionRisks(src) {
  const findings = [];
  for (const level of walkLevels(tokenize(src))) {
    for (let i = 0; i < level.length; i += 1) {
      const t = level[i];

      // (1) prepare( / exec( の第1引数は「単一の文字列リテラル」「置換なしテンプレート」「識別子の連なり」のみ
      if (t.type === 'id' && (t.value === 'prepare' || t.value === 'exec') && level[i + 1]?.value === '(' && level[i + 1].type === 'punct') {
        const args = [];
        let depth = 0;
        for (let j = i + 2; j < level.length; j += 1) {
          const a = level[j];
          if (a.type === 'punct') {
            if ('([{'.includes(a.value)) depth += 1;
            else if (')]}'.includes(a.value)) {
              if (depth === 0) break;
              depth -= 1;
            } else if (a.value === ',' && depth === 0) break;
          }
          args.push(a);
        }
        const isLiteral = args.length === 1 && (args[0].type === 'str' || (args[0].type === 'tpl' && !args[0].hasSubst));
        const isIdentChain =
          args.length >= 1 &&
          args.every((a, k) => (k % 2 === 0 ? a.type === 'id' : a.type === 'punct' && a.value === '.')) &&
          args.length % 2 === 1;
        if (!isLiteral && !isIdentChain) findings.push(`${t.value}() の引数が静的でない`);
        if (args.some((a) => a.type === 'tpl' && a.hasSubst)) findings.push(`${t.value}() にテンプレート埋め込み`);
      }

      // (2) 置換付きテンプレートが SQL らしい
      if (t.type === 'tpl' && t.hasSubst && SQL_PATTERN.test(t.value)) findings.push('SQL らしいテンプレートに ${} がある');

      // (3) SQL らしい文字列リテラルが + で連結されている
      if ((t.type === 'str' || t.type === 'tpl') && SQL_PATTERN.test(t.value)) {
        const prev = level[i - 1];
        const next = level[i + 1];
        if ((prev?.type === 'punct' && prev.value === '+') || (next?.type === 'punct' && next.value === '+')) {
          findings.push('SQL らしい文字列が + で連結されている');
        }
      }
    }
  }
  return findings;
}

/** import / export-from / 動的 import / require の指定子を集める */
export function findImports(src) {
  const specifiers = [];
  const problems = [];
  for (const level of walkLevels(tokenize(src))) {
    for (let i = 0; i < level.length; i += 1) {
      const t = level[i];
      const next = level[i + 1];
      if (t.type !== 'id') continue;

      if (t.value === 'import') {
        if (next?.type === 'punct' && next.value === '(') {
          const arg = level[i + 2];
          const after = level[i + 3];
          const literal = arg && (arg.type === 'str' || (arg.type === 'tpl' && !arg.hasSubst));
          if (literal && after?.type === 'punct' && (after.value === ')' || after.value === ',')) specifiers.push(arg.value);
          else problems.push('動的 import の指定子がリテラルでない');
        } else if (next?.type === 'str') {
          specifiers.push(next.value); // import "x"
        }
      } else if (t.value === 'from' && next?.type === 'str') {
        specifiers.push(next.value); // import ... from "x" / export ... from "x"
      } else if (t.value === 'require' && next?.type === 'punct' && next.value === '(') {
        problems.push('require() を使っている');
      } else if (t.value === 'createRequire') {
        problems.push('createRequire を使っている');
      }
    }
  }
  return { specifiers, problems };
}

export function isAllowedSpecifier(spec) {
  return spec.startsWith('node:') || spec.startsWith('./') || spec.startsWith('../');
}
