// monitor-emit.test.sh 用のスタブ受信器（node 組み込みのみ。導入先へは持ち込まない）
//
//   node monitor-stub.mjs <mode> <dir>
//
//   capture : HTTP を受けて記録し 202 を返す
//             <dir>/req.N   リクエスト行とヘッダ
//             <dir>/body.N  ボディ（req.N の後に原子的に置く。存在すれば完全）
//   hang    : 接続を受けるだけで一切応答しない
//   proxy   : 接続を受けるだけ（HTTP プロキシとして指定された時の接続数を数える）
//
// 全モード共通:
//   <dir>/port   待受ポート（0 で取得。書き出しは原子的。存在すれば待受済み）
//   <dir>/conns  接続ごとに 1 行追記（接続数 = 行数）
// 127.0.0.1 のみで待ち受ける。孤児化しても 300 秒で自壊する。

import http from "node:http";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";

const [mode, dir] = process.argv.slice(2);
if (!mode || !dir) {
  console.error("usage: monitor-stub.mjs <capture|hang|proxy> <dir>");
  process.exit(2);
}

const countConn = () => fs.appendFileSync(path.join(dir, "conns"), "1\n");
const atomicWrite = (name, data) => {
  const tmp = path.join(dir, `tmp.${name}`);
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, path.join(dir, name));
};

let server;
if (mode === "capture") {
  let n = 0;
  server = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      n += 1;
      const head =
        `${req.method} ${req.url}\n` +
        Object.entries(req.headers).map(([k, v]) => `${k}: ${v}`).join("\n") + "\n";
      atomicWrite(`req.${n}`, head);
      atomicWrite(`body.${n}`, Buffer.concat(chunks));
      res.writeHead(202);
      res.end();
    });
    req.on("error", () => {});
  });
  server.on("connection", (s) => { countConn(); s.on("error", () => {}); });
} else if (mode === "hang" || mode === "proxy") {
  server = net.createServer((s) => { countConn(); s.on("error", () => {}); });
} else {
  console.error(`unknown mode: ${mode}`);
  process.exit(2);
}

server.listen(0, "127.0.0.1", () => {
  atomicWrite("port", String(server.address().port));
});
setTimeout(() => process.exit(0), 300000);
