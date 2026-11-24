#!/usr/bin/env node
// Replays a recorded Mac (dev/capture-snapshot.mjs) so every screen can be drawn with real data.
// Writes are accepted and dropped. No dependencies.
// Run: node dev/snapshot-server.mjs snapshot.json [--port 47792]
// Pair: xcrun simctl openurl booted 'axkit://pair?u=http%3A%2F%2F127.0.0.1%3A47792&n=dev&c=123456'
import http from 'node:http';
import { readFileSync } from 'node:fs';

const file = process.argv[2];
const PORT = Number(process.argv[process.argv.indexOf('--port') + 1]) || 47792;
const HOST = process.env.MOCK_HOST ?? '127.0.0.1';
const snap = JSON.parse(readFileSync(file, 'utf8'));
const events = [...snap.events].sort((a, b) => a.seq - b.seq);
const lastSeq = events.at(-1)?.seq ?? 0;

const send = (res, status, body) => {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(body));
};

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', 'http://snapshot.local');
  const p = url.pathname;
  for await (const _ of req) { /* drain */ }
  if (req.method === 'POST' && p === '/m/p/dev/app') {
    return send(res, 200, { ok: true, deviceId: 'd_snapshot', deviceName: '아이폰', baseUrl: `http://${HOST}:${PORT}`, token: 'snapshot-token' });
  }
  if (!p.startsWith('/m/v1/app/')) return send(res, 404, { ok: false });
  const path = p.slice('/m/v1/app/'.length);
  if (path === 'capabilities') return send(res, 200, snap.capabilities);
  if (path === 'status') return send(res, 200, { ...snap.status, lastSeq, serverTime: new Date().toISOString() });
  if (path === 'me') return send(res, 200, { ok: true, deviceId: 'd_snapshot', name: '아이폰', rotatedAt: null, createdAt: snap.capturedAt });
  if (path === 'events') {
    const after = Number(url.searchParams.get('after') ?? 0);
    const limit = Math.min(200, Number(url.searchParams.get('limit') ?? 100));
    const channel = url.searchParams.get('channel');
    let list = events.filter((e) => e.seq > after);
    if (channel !== null) list = list.filter((e) => (e.channel ?? '') === channel || e.type === 'card' || e.type === 'card_closed');
    return send(res, 200, { ok: true, events: list.slice(0, limit), lastSeq, oldestSeq: events[0]?.seq ?? 0 });
  }
  if (path === 'stream') {
    res.writeHead(200, { 'Content-Type': 'text/event-stream; charset=utf-8', Connection: 'keep-alive', 'Cache-Control': 'no-store' });
    res.write(': open\n\n');
    const keep = setInterval(() => res.write(': keepalive\n\n'), 25_000);
    req.on('close', () => clearInterval(keep));
    return;
  }
  const file = path.match(/^files\/([A-Za-z0-9_.-]+)$/);
  if (file) {
    const f = snap.files?.[file[1]];
    if (!f) return send(res, 404, { ok: false });
    const bytes = Buffer.from(f.b64, 'base64');
    res.writeHead(200, { 'Content-Type': f.type, 'Content-Length': bytes.length });
    return res.end(bytes);
  }
  const view = path.match(/^views\/([A-Za-z0-9_-]+)$/);
  if (req.method === 'GET' && view) {
    // An answer recorded for this exact question (`docgraph?doc=…`), else the plain view.
    const v = (url.search && snap.views[`${view[1]}?${decodeURIComponent(url.search.slice(1))}`]) || snap.views[view[1]];
    return v ? send(res, 200, v) : send(res, 404, { ok: false, error: 'unknown_view' });
  }
  if (req.method === 'POST') return send(res, 200, { ok: true });
  return send(res, 404, { ok: false });
});

server.listen(PORT, HOST, () => {
  console.log(`snapshot (${events.length} events) on http://${HOST}:${PORT}`);
  console.log(`xcrun simctl openurl booted 'axkit://pair?u=${encodeURIComponent(`http://${HOST}:${PORT}`)}&n=dev&c=123456'`);
});
