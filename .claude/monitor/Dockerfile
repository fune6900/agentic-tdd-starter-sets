# ベースイメージは digest 固定（マニフェストリスト = linux/amd64 と arm64 の両方を含む index の digest）。
# 取得日 2026-10-04 / 取得方法: docker buildx imagetools inspect node:24-alpine の Digest 行。更新は手動
FROM node:24-alpine@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1
WORKDIR /app
# DB の置き場所（compose の名前付きボリュームの target）。ここを node 所有にしておかないと、初回マウント時に root 所有になり起動できない
RUN mkdir /data && chown node:node /data
COPY server ./server
# 素の docker run でも起動できるよう、DB は node 所有の /data に置く（BIND は設定しない = イメージ既定はループバック listen）
ENV MONITOR_DB=/data/monitor.db
USER node
# Host 検査がポート込みなので、実ポート（LOOP_MONITOR_PORT）を使う。http.get の既定 Host は 127.0.0.1:<port>
HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3 CMD ["node", "-e", "require('http').get({host:'127.0.0.1',port:process.env.LOOP_MONITOR_PORT||4319,path:'/api/state'},r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"]
CMD ["node", "server/server.mjs"]
