#!/usr/bin/env node
// Records what a real Mac answers (GET only: capabilities, status, every event, every view) into one JSON file,
// so dev/snapshot-server.mjs can replay it and every screen can be checked against real data.
// Run: AX_BASE=http://127.0.0.1:47617 AX_TOKEN=… node dev/capture-snapshot.mjs out.json
// The file holds the owner's real data: keep it out of the repo.
import { writeFileSync } from 'node:fs';

const base = process.env.AX_BASE;
const token = process.env.AX_TOKEN;
const out = process.argv[2];
if (!base || !token || !out) {
  console.error('AX_BASE, AX_TOKEN and an output path are needed.');
  process.exit(1);
}

async function get(path) {
  const res = await fetch(`${base}/m/v1/app/${path}`, { headers: { Authorization: `Bearer ${token}` } });
  if (!res.ok) return { __status: res.status };
  return res.json();
}

const snap = { capturedAt: new Date().toISOString(), capabilities: await get('capabilities'), status: await get('status'), events: [], views: {} };
for (let after = 0; ;) {
  const page = await get(`events?after=${after}&limit=200`);
  const list = page.events ?? [];
  snap.events.push(...list);
  if (list.length < 200) break;
  after = list.at(-1).seq;
}
for (const v of snap.capabilities.views ?? []) snap.views[v.name] = await get(`views/${v.name}`);
// A few answers that take a question: documents, other periods.
const extra = ['usage?period=week', 'usage?period=month'];
const graph = snap.views.docgraph?.data;
for (const n of (graph?.nodes ?? []).slice(0, 4)) extra.push(`docgraph?doc=${encodeURIComponent(n.id)}`);
for (const a of (snap.views.knowledge?.data?.areas ?? []).slice(0, 2)) for (const d of a.docs.slice(0, 2)) extra.push(`knowledge?doc=${encodeURIComponent(d.id)}`);
for (const q of extra) { const [name, query] = q.split('?'); if (snap.views[name]) snap.views[`${name}?${decodeURIComponent(query)}`] = await get(`views/${name}?${query}`); }
// Pictures attached to the newest events (at most 60), so attachments draw too.
snap.files = {};
const refs = snap.events.flatMap((e) => (e.attachments ?? []).map((a) => a.url)).filter((u) => /^files\/[A-Za-z0-9_.-]+$/.test(u ?? ''));
for (const url of [...new Set(refs)].slice(-60)) {
  const res = await fetch(`${base}/m/v1/app/${url}`, { headers: { Authorization: `Bearer ${token}` } });
  if (res.ok) snap.files[url.slice('files/'.length)] = { type: res.headers.get('content-type') ?? 'application/octet-stream', b64: Buffer.from(await res.arrayBuffer()).toString('base64') };
}
writeFileSync(out, JSON.stringify(snap));
console.log(`${snap.events.length} events, ${Object.keys(snap.views).length} views, ${Object.keys(snap.files).length} files → ${out}`);
