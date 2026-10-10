// 保存済みレコードから現在の状態を導出する（純関数）。時計にも DB にも触れない。
// 順序は seq の昇順だけで決める（配列の並び・received_at・送信側の値は使わない）。

import { estimateModelCost } from './cost.mjs';

const MAIN_TYPE = 'main';
const MAIN_KEY = ''; // agent_id は [A-Za-z0-9]+ なので空文字はサブと衝突しない

/** UsageSnapshot のレコードを、ノードに載せる usage の形にする */
function toUsage(record) {
  if (record === undefined) return null;
  if (record.usage_status === 'unknown') return { status: 'unknown', reason: record.unknown_reason };
  return {
    status: 'ok',
    models: record.models.map((m) => ({
      model: m.model,
      message_count: m.message_count,
      input_tokens: m.input_tokens,
      output_tokens: m.output_tokens,
      cache_creation_5m_input_tokens: m.cache_creation_5m_input_tokens,
      cache_creation_1h_input_tokens: m.cache_creation_1h_input_tokens,
      cache_read_input_tokens: m.cache_read_input_tokens,
      cost: estimateModelCost(m),
    })),
  };
}

/** ツリー全ノードの usage を合算する（メイン + 全サブの単純合算） */
function totalUsage(tree) {
  const total = {
    estimate: true,
    tokens: { input: 0, output: 0, cache_creation: 0, cache_read: 0 },
    unknown_snapshots: 0,
    cost: { known_micro_usd: 0, known_count: 0, unknown_count: 0 },
  };
  const visit = (node) => {
    const { usage } = node;
    if (usage?.status === 'unknown') {
      total.unknown_snapshots += 1;
      total.cost.unknown_count += 1;
    } else if (usage) {
      for (const m of usage.models) {
        total.tokens.input += m.input_tokens;
        total.tokens.output += m.output_tokens;
        total.tokens.cache_creation += m.cache_creation_5m_input_tokens + m.cache_creation_1h_input_tokens;
        total.tokens.cache_read += m.cache_read_input_tokens;
        if (m.cost.status === 'known') {
          total.cost.known_micro_usd += m.cost.micro_usd;
          total.cost.known_count += 1;
        } else {
          total.cost.unknown_count += 1;
        }
      }
    }
    node.children.forEach(visit);
  };
  visit(tree);
  return total;
}

const newNode = (agentId, agentType, status) => ({
  agent_id: agentId, agent_type: agentType, status, running_tools: new Map(), children: new Map(),
});

const toPublic = (node, snapshots) => ({
  agent_id: node.agent_id,
  agent_type: node.agent_type,
  status: node.status,
  running_tools: [...node.running_tools.values()],
  usage: toUsage(snapshots?.get(node.agent_id ?? MAIN_KEY)),
  children: [...node.children.values()].map((child) => toPublic(child, snapshots)),
});

/** サブエージェントのノードを（無ければ初出で稼働中として）作る */
function subNode(main, record) {
  let node = main.children.get(record.agent_id);
  if (!node) {
    node = newNode(record.agent_id, record.agent_type ?? 'unknown', 'running');
    main.children.set(record.agent_id, node);
  }
  return node;
}

function apply(main, record) {
  const target = record.agent_id === undefined ? main : subNode(main, record);
  switch (record.event) {
    case 'SessionStart': main.status = 'waiting'; break;
    case 'UserPromptSubmit': main.status = 'running'; break;
    case 'Stop':
    case 'Notification': main.status = 'waiting'; break;
    case 'SessionEnd': main.status = 'ended'; break;
    case 'SubagentStart': target.status = 'running'; break;
    case 'SubagentStop': target.status = 'done'; break;
    case 'PreToolUse':
      target.running_tools.set(record.tool_use_id, { tool_use_id: record.tool_use_id, tool_name: record.tool_name, seq: record.seq });
      break;
    // 対応する PreToolUse が無い（欠落・順序逆転）場合も delete は何もしない。エラーにしない
    case 'PostToolUse': target.running_tools.delete(record.tool_use_id); break;
    default: break;
  }
}

/** @param {readonly object[]} records @returns {{sessions: object[]}} */
export function deriveState(records) {
  const sorted = [...records].sort((a, b) => a.seq - b.seq);
  const sessions = new Map();
  // (session, agent) ごとに seq が最大の UsageSnapshot だけが有効（置き換え）。ツリーにも last_seq にも触れない
  const snapshots = new Map();
  for (const record of sorted) {
    if (record.event === 'UsageSnapshot') {
      if (!snapshots.has(record.session_id)) snapshots.set(record.session_id, new Map());
      snapshots.get(record.session_id).set(record.agent_id ?? MAIN_KEY, record);
      continue;
    }
    let s = sessions.get(record.session_id);
    if (!s) {
      s = { session_id: record.session_id, last_seq: 0, last_received_at: 0, main: newNode(null, MAIN_TYPE, 'waiting') };
      sessions.set(record.session_id, s);
    }
    apply(s.main, record);
    s.last_seq = record.seq;
    s.last_received_at = record.received_at;
  }
  return {
    sessions: [...sessions.values()]
      .sort((a, b) => b.last_seq - a.last_seq)
      .map((s) => {
        const tree = toPublic(s.main, snapshots.get(s.session_id));
        return {
          session_id: s.session_id,
          status: s.main.status,
          last_seq: s.last_seq,
          last_received_at: s.last_received_at,
          tree,
          usage_total: totalUsage(tree),
        };
      }),
  };
}
