// node test.mjs: the Worker against an in-memory KV (no Cloudflare account needed).
import assert from "node:assert/strict";
import worker, { clean } from "./worker.js";

class KV {
  constructor() { this.m = new Map(); }
  async get(k, type) { const v = this.m.get(k); return v ? (type === "json" ? JSON.parse(v.value) : v.value) : null; }
  async put(k, value, opts = {}) { this.m.set(k, { value, metadata: opts.metadata }); }
  async delete(k) { this.m.delete(k); }
  async list({ prefix, limit }) {
    return { keys: [...this.m.entries()].filter(([k]) => k.startsWith(prefix)).slice(0, limit).map(([name, v]) => ({ name, metadata: v.metadata })) };
  }
}

const env = { BOARD: new KV() };
const G = "group_abcdefgh1234", A = "memberAAAA1111", B = "memberBBBB2222", KA = "keyAAAAAAAAAAAA", KB = "keyBBBBBBBBBBBB";
const call = (method, path, { key, body } = {}) => worker.fetch(new Request("https://lb.test" + path, {
  method, headers: key ? { authorization: `Bearer ${key}` } : {}, body: body === undefined ? undefined : JSON.stringify(body),
}), env);
const day = (d, score) => ({ d, score, tracked: 80, work: 60, met: 1, missed: 0, scroll: 30 });

let r = await call("PUT", `/v1/g/${G}/m/${A}`, { key: KA, body: { name: " Ana ", usual: 70, days: [day("2026-11-20", 75)] } });
assert.equal(r.status, 200);
r = await call("PUT", `/v1/g/${G}/m/${A}`, { key: KB, body: { name: "Impostor", days: [] } });
assert.equal(r.status, 403, "someone else's row");
r = await call("PUT", `/v1/g/${G}/m/${B}`, { body: { name: "Ben", days: [] } });
assert.equal(r.status, 401, "no key");
r = await call("PUT", `/v1/g/${G}/m/${B}`, { key: KB, body: { name: "Ben", days: [{ d: "nope", score: 1 }] } });
assert.equal(r.status, 400, "bad day");
r = await call("PUT", `/v1/g/${G}/m/${B}`, { key: KB, body: { name: "Ben", usual: null, days: [day("2026-11-20", 500)] } });
assert.equal(r.status, 200);
r = await call("GET", `/v1/g/${G}`);
const { members } = await r.json();
assert.equal(members.length, 2);
const ana = members.find((m) => m.id === A), ben = members.find((m) => m.id === B);
assert.equal(ana.name, "Ana");
assert.equal(ana.usual, 70);
assert.equal(ben.days[0].score, 100, "clamped");
assert.equal(ana.keyHash, undefined, "the key hash never leaves the Worker");
assert.ok(ana.at > 0);
r = await call("DELETE", `/v1/g/${G}/m/${A}`, { key: KB });
assert.equal(r.status, 403);
r = await call("DELETE", `/v1/g/${G}/m/${A}`, { key: KA });
assert.equal(r.status, 200);
assert.equal((await (await call("GET", `/v1/g/${G}`)).json()).members.length, 1);
assert.equal((await call("GET", "/v1/g/short")).status, 404);
assert.equal((await call("PUT", `/v1/g/${G}/m/${B}`, { key: KB, body: "x".repeat(5000) })).status, 413);
assert.equal(clean({ name: "", days: [] }), null);
assert.equal(clean({ name: "x", days: Array(20).fill(day("2026-11-20", 5)) }).days.length, 8);
console.log("leaderboard worker: all checks passed");
