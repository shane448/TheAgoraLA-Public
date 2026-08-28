import assert from "node:assert/strict";
import test from "node:test";

async function render(path = "/") {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}-${path}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request(`http://localhost${path}`, {
      headers: { accept: "text/html" },
    }),
    {
      ASSETS: {
        fetch: async () => new Response("Not found", { status: 404 }),
      },
    },
    {
      waitUntil() {},
      passThroughOnException() {},
    },
  );
}

test("server-renders the production home page", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /The Agora LA/);
  assert.match(html, /Turn every podcast into a practice field/);
  assert.match(html, /Your AI account\. Your usage\. No Agora bill/);
  assert.match(html, /href="\/privacy"/);
  assert.match(html, /href="\/terms"/);
  assert.match(html, /href="\/support"/);
  assert.doesNotMatch(html, /codex-preview|starter project|taking shape/i);
});

for (const [path, heading, requiredText] of [
  ["/privacy", "Privacy Policy", "support@theagorala.com"],
  ["/terms", "Terms of Use", "AI-provider accounts and costs"],
  ["/support", "Listener Support", "Connect AI"],
]) {
  test(`server-renders ${path}`, async () => {
    const response = await render(path);
    assert.equal(response.status, 200);
    const html = await response.text();
    assert.match(html, new RegExp(heading, "i"));
    assert.match(html, new RegExp(requiredText, "i"));
  });
}

test("renders the secure provider return page without storing credentials", async () => {
  const response = await render("/auth/openrouter?code=review-code");
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /Secure AI setup/);
  assert.match(html, /Return to The Agora/);
  assert.match(html, /No credential is stored on this webpage/);
});
