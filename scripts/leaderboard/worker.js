// Productium leaderboard: a Cloudflare Worker over one KV namespace (binding BOARD). Free plan sized.
//
//   GET    /v1/g/:group                 → { members: [{ id, name, usual, days, at }] }
//   PUT    /v1/g/:group/m/:member       body { name, usual, days: [{ d, score, tracked, work, met, missed, scroll }] }
//   DELETE /v1/g/:group/m/:member       leave the group
//
// A group is a random id: whoever has the invite link can read it and join. Writes need `Authorization: Bearer <key>`;
// the first write sets the member's key (stored as a SHA-256), later writes and deletes must match it. Rows expire
// 60 days after their last write. Everything a row holds is also its KV metadata (< 1 KB), so a GET is one list call.

const ID = /^[A-Za-z0-9_-]{8,64}$/;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const MAX_DAYS = 8, MAX_MEMBERS = 50, MAX_BODY = 4096, TTL = 60 * 86400;

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

const int = (v, lo, hi) => (Number.isFinite(v) ? Math.max(lo, Math.min(hi, Math.round(v))) : null);

async function sha256(s) {
  const h = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/// Only known fields, clamped; null when the body isn't a valid post.
export function clean(p) {
  if (!p || typeof p !== "object" || typeof p.name !== "string" || !Array.isArray(p.days)) return null;
  const name = p.name.trim().slice(0, 40);
  if (!name) return null;
  const days = [];
  for (const d of p.days.slice(-MAX_DAYS)) {
    if (!d || typeof d.d !== "string" || !DAY.test(d.d)) return null;
    const row = {
      d: d.d, score: int(d.score, 0, 100), tracked: int(d.tracked, 0, 100), work: int(d.work, 0, 1440),
      met: int(d.met, 0, 50), missed: int(d.missed, 0, 50), scroll: int(d.scroll, 0, 1440),
    };
    if (Object.values(row).some((v) => v === null)) return null;
    days.push(row);
  }
  const usual = p.usual == null ? null : int(p.usual, 0, 100);
  return { name, usual, days };
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);
    if (parts[0] !== "v1" || parts[1] !== "g" || !ID.test(parts[2] ?? "")) return json({ error: "not found" }, 404);
    const group = parts[2];
    const prefix = `g/${group}/m/`;

    if (parts.length === 3 && request.method === "GET") {
      const list = await env.BOARD.list({ prefix, limit: MAX_MEMBERS });
      const members = list.keys.map((k) => ({ id: k.name.slice(prefix.length), ...(k.metadata ?? {}) }))
        .filter((m) => typeof m.name === "string");
      return json({ members });
    }

    if (parts.length !== 5 || parts[3] !== "m" || !ID.test(parts[4])) return json({ error: "not found" }, 404);
    const key = `${prefix}${parts[4]}`;
    const auth = (request.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    if (!ID.test(auth)) return json({ error: "missing key" }, 401);
    const hash = await sha256(auth);
    const existing = await env.BOARD.get(key, "json");
    if (existing && existing.keyHash !== hash) return json({ error: "not your row" }, 403);

    if (request.method === "DELETE") {
      if (existing) await env.BOARD.delete(key);
      return json({ ok: true });
    }
    if (request.method !== "PUT") return json({ error: "method" }, 405);

    const text = await request.text();
    if (text.length > MAX_BODY) return json({ error: "too big" }, 413);
    let body;
    try { body = JSON.parse(text); } catch { return json({ error: "bad json" }, 400); }
    const post = clean(body);
    if (!post) return json({ error: "bad post" }, 400);
    if (!existing) {
      const count = (await env.BOARD.list({ prefix, limit: MAX_MEMBERS })).keys.length;
      if (count >= MAX_MEMBERS) return json({ error: "group full" }, 409);
    }
    const row = { ...post, at: Date.now() };
    await env.BOARD.put(key, JSON.stringify({ ...row, keyHash: hash }), { metadata: row, expirationTtl: TTL });
    return json({ ok: true });
  },
};
