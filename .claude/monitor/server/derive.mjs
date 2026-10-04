// 保存済みレコードから現在の状態を導出する（純関数）。時計にも DB にも触れない。
// 順序は seq の昇順だけで決める（配列の並び・received_at・送信側の値は使わない）。

const MAIN_TYPE = 'main';

const newNode = (agentId, agentType, status) => ({
  agent_id: agentId, agent_type: agentType, status, running_tools: new Map(), children: new Map(),
});

const toPublic = (node) => ({
  agent_id: node.agent_id,
  agent_type: node.agent_type,
  status: node.status,
  running_tools: [...node.running_tools.values()],
  children: [...node.children.values()].map(toPublic),
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
  for (const record of sorted) {
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
      .map((s) => ({
        session_id: s.session_id,
        status: s.main.status,
        last_seq: s.last_seq,
        last_received_at: s.last_received_at,
        tree: toPublic(s.main),
      })),
  };
}
