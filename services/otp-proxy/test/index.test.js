import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import worker, { looksLikeOtpTraffic, parseModelAnswer, normalise } from "../src/index.js";

const samples = JSON.parse(
  readFileSync(new URL("../../../protocol/test-vectors/otp-samples.json", import.meta.url), "utf8"),
).samples;
const positives = samples.filter((s) => s.code.length > 0);
const negatives = samples.filter((s) => s.code.length === 0);

const INSTALL = "a".repeat(64);
const OK_TEXT = "Your OTP is 482913. Do not share it.";

function makeEnv(over = {}) {
  const limiter = (ok = true) => ({ limit: async () => ({ success: ok }) });
  return {
    MODEL: "@cf/meta/llama-3.2-3b-instruct",
    AI_TIMEOUT_MS: "1500",
    PER_INSTALL: limiter(),
    PER_IP: limiter(),
    GLOBAL: limiter(),
    AI: { run: async () => ({ response: { is_otp: true, code: "482913" } }) },
    ...over,
  };
}

function req(body, { headers = {}, method = "POST", path = "/v1/extract", raw } = {}) {
  const h = {
    "Content-Type": "application/json",
    "X-Bridgey-Install": INSTALL,
    "CF-Connecting-IP": "203.0.113.7",
    ...headers,
  };
  for (const k of Object.keys(h)) if (h[k] === null) delete h[k];
  return new Request("https://proxy.test" + path, {
    method,
    headers: h,
    body: method === "GET" ? undefined : (raw ?? JSON.stringify(body)),
  });
}

async function call(r, env = makeEnv()) {
  const res = await worker.fetch(r, env);
  const text = await res.text();
  return { res, text, body: text ? JSON.parse(text) : null };
}

const good = { v: 1, text: OK_TEXT, sender: "VM-HDFCBK" };

test("health", async () => {
  const { res, body } = await call(req(null, { method: "GET", path: "/health" }));
  assert.equal(res.status, 200);
  assert.deepEqual(body, { ok: true });
  assert.equal(res.headers.get("Content-Type"), "application/json");
  assert.equal(res.headers.get("Cache-Control"), "no-store");
  assert.equal(res.headers.get("Access-Control-Allow-Origin"), null);
});

test("health makes no AI call and no rate limit call", async () => {
  const boom = () => {
    throw new Error("must not be called");
  };
  const env = makeEnv({ AI: { run: boom }, PER_INSTALL: { limit: boom }, PER_IP: { limit: boom }, GLOBAL: { limit: boom } });
  const { res } = await call(req(null, { method: "GET", path: "/health" }), env);
  assert.equal(res.status, 200);
});

test("404 and 405", async () => {
  let r = await call(req(null, { method: "GET", path: "/nope" }));
  assert.equal(r.res.status, 404);
  assert.deepEqual(r.body, { error: "not_found" });
  r = await call(req(null, { method: "GET", path: "/v1/extract" }));
  assert.equal(r.res.status, 405);
  r = await call(req({}, { method: "POST", path: "/health" }));
  assert.equal(r.res.status, 405);
});

test("install id validation", async () => {
  for (const bad of [null, "", "abc", "A".repeat(64), "g".repeat(64), "a".repeat(63), "a".repeat(65)]) {
    const { res, body } = await call(req(good, { headers: { "X-Bridgey-Install": bad } }));
    assert.equal(res.status, 401, String(bad));
    assert.deepEqual(body, { error: "install_id" });
  }
});

test("content type", async () => {
  const { res } = await call(req(good, { headers: { "Content-Type": "text/plain" } }));
  assert.equal(res.status, 415);
  const ok = await call(req(good, { headers: { "Content-Type": "application/json; charset=utf-8" } }));
  assert.equal(ok.res.status, 200);
});

test("size limit", async () => {
  const big = JSON.stringify({ v: 1, text: OK_TEXT, sender: "x", pad: "y".repeat(2100) });
  const { res, body } = await call(req(null, { raw: big }));
  assert.equal(res.status, 413);
  assert.deepEqual(body, { error: "too_large" });
});

test("bad JSON and bad shapes", async () => {
  const cases = [
    "not json",
    "[]",
    "null",
    JSON.stringify({ text: OK_TEXT }),
    JSON.stringify({ v: 2, text: OK_TEXT }),
    JSON.stringify({ v: "1", text: OK_TEXT }),
    JSON.stringify({ v: 1, text: 5 }),
    JSON.stringify({ v: 1 }),
    JSON.stringify({ v: 1, text: "   \n " }),
    JSON.stringify({ v: 1, text: OK_TEXT, sender: 7 }),
  ];
  for (const raw of cases) {
    const { res, body } = await call(req(null, { raw }));
    assert.equal(res.status, 400, raw);
    assert.deepEqual(body, { error: "bad_request" });
  }
});

test("text and sender limits", async () => {
  const long = "482913 " + "a".repeat(594);
  assert.equal(long.length, 601);
  let r = await call(req({ v: 1, text: long }));
  assert.equal(r.res.status, 400);
  const edge = "482913 " + "a".repeat(593);
  assert.equal(edge.length, 600);
  r = await call(req({ v: 1, text: edge }));
  assert.equal(r.res.status, 200);
  r = await call(req({ v: 1, text: OK_TEXT, sender: "s".repeat(65) }));
  assert.equal(r.res.status, 400);
  r = await call(req({ v: 1, text: OK_TEXT, sender: "s".repeat(64) }));
  assert.equal(r.res.status, 200);
  r = await call(req({ v: 1, text: OK_TEXT }));
  assert.equal(r.res.status, 200);
});

test("sender absent becomes 'unknown' in the prompt", async () => {
  let seen;
  const env = makeEnv({
    AI: {
      run: async (model, params) => {
        seen = { model, params };
        return { response: { is_otp: true, code: "482913" } };
      },
    },
  });
  await call(req({ v: 1, text: OK_TEXT }), env);
  assert.equal(seen.model, "@cf/meta/llama-3.2-3b-instruct");
  assert.equal(seen.params.messages[1].content, `Sender: unknown\nSMS: ${OK_TEXT}`);
  assert.equal(seen.params.temperature, 0);
  assert.equal(seen.params.max_tokens, 40);
  assert.equal(seen.params.response_format.type, "json_schema");
});

test("gate: every code sample passes", () => {
  for (const s of positives) assert.equal(looksLikeOtpTraffic(s.body), true, s.id);
  assert.equal(positives.length, 30);
});

test("gate: negatives (recorded, some may pass)", () => {
  const passed = negatives.filter((s) => looksLikeOtpTraffic(s.body)).map((s) => s.id);
  const rejected = negatives.filter((s) => !looksLikeOtpTraffic(s.body)).map((s) => s.id);
  console.log(`gate negatives passing: ${passed.join(",")} | rejected: ${rejected.join(",")}`);
  assert.equal(negatives.length, 12);
  assert.ok(rejected.includes("neg05"), "pure advice text has no digits");
});

test("gate: unit cases", () => {
  assert.equal(looksLikeOtpTraffic("code 591-047 now"), true);
  assert.equal(looksLikeOtpTraffic("441 902"), true);
  assert.equal(looksLikeOtpTraffic("G-739108 is your code"), true);
  assert.equal(looksLikeOtpTraffic("7HD2QX"), true);
  assert.equal(looksLikeOtpTraffic("no digits here at all"), false);
  assert.equal(looksLikeOtpTraffic("abcdef ghijkl"), false);
  assert.equal(looksLikeOtpTraffic("123"), false);
  assert.equal(looksLikeOtpTraffic("12345678901"), false);
  assert.equal(looksLikeOtpTraffic(""), false);
  assert.equal(looksLikeOtpTraffic(42), false);
});

test("gate rejects with 422 and no AI call", async () => {
  let called = false;
  const env = makeEnv({ AI: { run: async () => ((called = true), {}) } });
  const { res, body } = await call(req({ v: 1, text: "Never share your OTP with anyone." }), env);
  assert.equal(res.status, 422);
  assert.deepEqual(body, { error: "not_otp_like" });
  assert.equal(called, false);
});

test("rate limits return 429 with Retry-After", async () => {
  for (const name of ["PER_INSTALL", "PER_IP", "GLOBAL"]) {
    let aiCalled = false;
    const env = makeEnv({
      [name]: { limit: async () => ({ success: false }) },
      AI: { run: async () => ((aiCalled = true), {}) },
    });
    const { res, body } = await call(req(good), env);
    assert.equal(res.status, 429, name);
    assert.equal(res.headers.get("Retry-After"), "60");
    assert.deepEqual(body, { error: "rate_limited" });
    assert.equal(aiCalled, false);
  }
});

test("rate limit keys", async () => {
  const keys = {};
  const mk = (n) => ({ limit: async ({ key }) => ((keys[n] = key), { success: true }) });
  const env = makeEnv({ PER_INSTALL: mk("install"), PER_IP: mk("ip"), GLOBAL: mk("global") });
  await call(req(good), env);
  assert.deepEqual(keys, { install: INSTALL, ip: "203.0.113.7", global: "global" });
});

test("missing rate limit binding fails closed with 503", async () => {
  for (const name of ["PER_INSTALL", "PER_IP", "GLOBAL"]) {
    const env = makeEnv();
    delete env[name];
    const { res } = await call(req(good), env);
    assert.equal(res.status, 503, name);
  }
});

test("AI object answer", async () => {
  const { res, body } = await call(req(good));
  assert.equal(res.status, 200);
  assert.deepEqual(body, { is_otp: true, code: "482913" });
});

test("AI string answer with surrounding text", async () => {
  const env = makeEnv({
    AI: { run: async () => ({ response: 'Sure! Here it is: {"is_otp": true, "code": "591-047"} hope that helps {x}' }) },
  });
  const { res, body } = await call(req(good), env);
  assert.equal(res.status, 200);
  assert.deepEqual(body, { is_otp: true, code: "591-047" });
});

test("is_otp false forces code null", async () => {
  const env = makeEnv({ AI: { run: async () => ({ response: { is_otp: false, code: "123456" } }) } });
  const { body } = await call(req(good), env);
  assert.deepEqual(body, { is_otp: false, code: null });
});

test("non-string and out-of-range code becomes null; non-boolean is_otp is false", async () => {
  for (const [answer, expected] of [
    [{ is_otp: true, code: 482913 }, { is_otp: true, code: null }],
    [{ is_otp: true, code: "" }, { is_otp: true, code: null }],
    [{ is_otp: true, code: "9".repeat(25) }, { is_otp: true, code: null }],
    [{ is_otp: true, code: "9".repeat(24) }, { is_otp: true, code: "9".repeat(24) }],
    [{ is_otp: "true", code: "1234" }, { is_otp: false, code: null }],
  ]) {
    const env = makeEnv({ AI: { run: async () => ({ response: answer }) } });
    const { res, body } = await call(req(good), env);
    assert.equal(res.status, 200);
    assert.deepEqual(body, expected);
  }
});

test("AI throws gives 502; unparseable gives 502", async () => {
  let env = makeEnv({
    AI: {
      run: async () => {
        throw new Error("boom");
      },
    },
  });
  let r = await call(req(good), env);
  assert.equal(r.res.status, 502);
  assert.deepEqual(r.body, { error: "upstream" });
  for (const bad of [{ response: "no json here" }, { response: "{broken" }, {}, null, { response: 5 }]) {
    env = makeEnv({ AI: { run: async () => bad } });
    r = await call(req(good), env);
    assert.equal(r.res.status, 502);
  }
});

test("AI hangs gives 504", async () => {
  const env = makeEnv({ AI_TIMEOUT_MS: "40", AI: { run: () => new Promise(() => {}) } });
  const started = Date.now();
  const { res, body } = await call(req(good), env);
  assert.equal(res.status, 504);
  assert.deepEqual(body, { error: "timeout" });
  assert.ok(Date.now() - started < 1000);
});

test("response has only the two fields and standard headers", async () => {
  const env = makeEnv({
    AI: { run: async () => ({ response: { is_otp: true, code: "482913", extra: "x", confidence: 1 } }) },
  });
  const { res, body } = await call(req(good), env);
  assert.deepEqual(Object.keys(body).sort(), ["code", "is_otp"]);
  assert.equal(res.headers.get("Content-Type"), "application/json");
  assert.equal(res.headers.get("Cache-Control"), "no-store");
  assert.equal(res.headers.get("Access-Control-Allow-Origin"), null);
});

test("request text never appears in console output", async () => {
  const secret = "ZQ9-482913-SECRETWORD";
  const calls = [];
  const names = ["log", "info", "warn", "error", "debug"];
  const orig = {};
  for (const n of names) {
    orig[n] = console[n];
    console[n] = (...args) => calls.push([n, args]);
  }
  try {
    const envs = [
      makeEnv(),
      makeEnv({ AI: { run: async () => { throw new Error("boom " + secret); } } }),
      makeEnv({ AI_TIMEOUT_MS: "20", AI: { run: () => new Promise(() => {}) } }),
      makeEnv({ PER_IP: { limit: async () => ({ success: false }) } }),
    ];
    for (const env of envs) {
      await call(req({ v: 1, text: `code ${secret} is your OTP`, sender: "SENDERX" }), env);
    }
    await call(req(null, { raw: `{bad ${secret}` }));
  } finally {
    for (const n of names) console[n] = orig[n];
  }
  assert.equal(calls.length, 0);
});

test("parseModelAnswer and normalise helpers", () => {
  assert.deepEqual(parseModelAnswer({ response: { is_otp: false } }), { is_otp: false });
  assert.deepEqual(parseModelAnswer({ response: 'x {"is_otp":true,"code":"}"} y' }), { is_otp: true, code: "}" });
  assert.equal(parseModelAnswer({ response: { a: 1 } }), null);
  assert.equal(parseModelAnswer({ response: "[1]" }), null);
  assert.deepEqual(normalise({ is_otp: true, code: "12" }), { is_otp: true, code: "12" });
});
