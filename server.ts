// Serves the GRIT interviews page on Railway. The page itself is index.html on main in
// kumar623/grit-interviews, re-read at most once a minute, so a push to main updates the
// live site without redeploying this function.
const SRC = "https://raw.githubusercontent.com/kumar623/grit-interviews/main/index.html";
let html = "";
let loadedAt = 0;

async function load() {
  try {
    const r = await fetch(SRC + "?t=" + Date.now());
    if (!r.ok) { console.log("page fetch failed", r.status); return; }
    const text = await r.text();
    if (text.includes("</html>")) {
      if (text !== html) console.log("page loaded", text.length, new Bun.CryptoHasher("sha256").update(text).digest("hex").slice(0, 12));
      html = text;
    }
  } catch (e) {
    console.log("page fetch error", String(e));
  } finally {
    loadedAt = Date.now();
  }
}
await load();

Bun.serve({
  port: Number(Bun.env.PORT) || 3000,
  async fetch(req) {
    const path = new URL(req.url).pathname;
    if (path === "/healthz") return new Response(html ? "ok" : "starting", { status: html ? 200 : 503 });
    if (Date.now() - loadedAt > 60000) await load();
    if (!html) return new Response("Starting up. Please refresh in a moment.", { status: 503 });
    return new Response(html, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-cache" } });
  },
});
