// Bridgey OTP proxy: asks Workers AI which token in one SMS is the one-time code.
// Privacy: this file never logs request data. Do not add console.* calls that include it.

const DEFAULT_MODEL = "@cf/meta/llama-3.2-3b-instruct";
const DEFAULT_TIMEOUT_MS = 1500;
const MAX_BODY_BYTES = 2048;
const MAX_TEXT_CHARS = 600;
const MAX_SENDER_CHARS = 64;
const MAX_CODE_CHARS = 24;

const SCHEMA = {
  type: "object",
  properties: {
    is_otp: { type: "boolean" },
    code: { type: ["string", "null"] },
  },
  required: ["is_otp", "code"],
  additionalProperties: false,
};

const SYSTEM_PROMPT =
  "You read one SMS and decide whether it contains a one-time password or verification code (OTP, login code, transaction OTP, delivery or ride PIN). If it does, copy the code exactly as written. Ignore amounts, account numbers, card digits, reference or order numbers, phone numbers, dates and promo codes. If the SMS has no such code, set is_otp to false and code to null. Answer only with JSON.";

const INSTALL_RE = /^[0-9a-f]{64}$/;

const GATE_A = /(?<![0-9A-Za-z])(?=[0-9A-Za-z]*\d)[0-9A-Za-z]{4,10}(?![0-9A-Za-z])/;
const GATE_B = /(?<![0-9A-Za-z])\d{2,5}[ -]\d{2,5}(?![0-9A-Za-z])/;

/**
 * True when the text contains at least one candidate code, by either rule:
 *   A: a run of 4 to 10 letters/digits containing at least one digit;
 *   B: two groups of 2 to 5 digits split by one space or hyphen ("591-047", "441 902").
 * The Mac and Android clients apply exactly the same rule before calling.
 */
export function looksLikeOtpTraffic(text) {
  if (typeof text !== "string") return false;
  return GATE_A.test(text) || GATE_B.test(text);
}

function json(status, body, extraHeaders) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      ...extraHeaders,
    },
  });
}

const err = (status, code, extra) => json(status, { error: code }, extra);

/** Parse the model answer: an object, or a string with a JSON block inside. */
export function parseModelAnswer(result) {
  let r = result;
  if (r && typeof r === "object") {
    if ("response" in r) r = r.response;
    else if (Array.isArray(r.choices)) r = r.choices[0]?.message?.content; // OpenAI-style fallback
  }
  if (typeof r === "string") {
    const start = r.indexOf("{");
    if (start < 0) return null;
    let depth = 0;
    let inStr = false;
    let esc = false;
    for (let i = start; i < r.length; i++) {
      const c = r[i];
      if (inStr) {
        if (esc) esc = false;
        else if (c === "\\") esc = true;
        else if (c === '"') inStr = false;
      } else if (c === '"') inStr = true;
      else if (c === "{") depth++;
      else if (c === "}") {
        depth--;
        if (depth === 0) {
          try {
            r = JSON.parse(r.slice(start, i + 1));
          } catch {
            return null;
          }
          break;
        }
      }
    }
    if (typeof r === "string") return null;
  }
  if (!r || typeof r !== "object" || Array.isArray(r)) return null;
  if (!Object.hasOwn(r, "is_otp")) return null;
  return r;
}

/** Normalise a parsed answer to exactly {is_otp, code}. */
export function normalise(answer) {
  const isOtp = answer.is_otp === true;
  const c = answer.code;
  const code = isOtp && typeof c === "string" && c.length >= 1 && c.length <= MAX_CODE_CHARS ? c : null;
  return { is_otp: isOtp, code };
}

function timeoutMs(env) {
  const n = Number.parseInt(env.AI_TIMEOUT_MS, 10);
  return Number.isFinite(n) && n > 0 ? n : DEFAULT_TIMEOUT_MS;
}

async function limited(binding, key) {
  const out = await binding.limit({ key });
  return !out || out.success !== true;
}

async function handleExtract(request, env) {
  const install = request.headers.get("X-Bridgey-Install");
  if (!install || !INSTALL_RE.test(install)) return err(401, "install_id");

  const ctype = (request.headers.get("Content-Type") || "").split(";")[0].trim().toLowerCase();
  if (ctype !== "application/json") return err(415, "unsupported_media_type");

  const declared = Number.parseInt(request.headers.get("Content-Length") || "", 10);
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) return err(413, "too_large");
  const raw = new Uint8Array(await request.arrayBuffer());
  if (raw.byteLength > MAX_BODY_BYTES) return err(413, "too_large");

  let body;
  try {
    body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw));
  } catch {
    return err(400, "bad_request");
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) return err(400, "bad_request");
  if (body.v !== 1) return err(400, "bad_request");
  const { text, sender } = body;
  if (typeof text !== "string" || text.trim().length === 0 || text.length > MAX_TEXT_CHARS) {
    return err(400, "bad_request");
  }
  if (sender !== undefined && sender !== null) {
    if (typeof sender !== "string" || sender.length > MAX_SENDER_CHARS) return err(400, "bad_request");
  }

  if (!looksLikeOtpTraffic(text)) return err(422, "not_otp_like");

  if (!env.PER_INSTALL || !env.PER_IP || !env.GLOBAL || !env.AI) return err(503, "unavailable");
  const retry = { "Retry-After": "60" };
  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  try {
    if (await limited(env.PER_INSTALL, install)) return err(429, "rate_limited", retry);
    if (await limited(env.PER_IP, ip)) return err(429, "rate_limited", retry);
    if (await limited(env.GLOBAL, "global")) return err(429, "rate_limited", retry);
  } catch {
    return err(503, "unavailable");
  }

  const senderLabel = typeof sender === "string" && sender.trim() ? sender : "unknown";
  const params = {
    messages: [
      { role: "system", content: SYSTEM_PROMPT },
      { role: "user", content: `Sender: ${senderLabel}\nSMS: ${text}` },
    ],
    temperature: 0,
    max_tokens: 40,
    response_format: { type: "json_schema", json_schema: SCHEMA },
  };

  let timer;
  const timeout = new Promise((resolve) => {
    timer = setTimeout(() => resolve({ timedOut: true }), timeoutMs(env));
  });
  let outcome;
  try {
    const call = Promise.resolve()
      .then(() => env.AI.run(env.MODEL || DEFAULT_MODEL, params))
      .then((value) => ({ value }));
    // If the timeout wins, a later rejection of the AI call must not go unhandled.
    call.catch(() => {});
    outcome = await Promise.race([call, timeout]);
  } catch {
    return err(502, "upstream");
  } finally {
    clearTimeout(timer);
  }
  if (outcome.timedOut) return err(504, "timeout");

  const answer = parseModelAnswer(outcome.value);
  if (!answer) return err(502, "upstream");
  return json(200, normalise(answer));
}

async function handle(request, env) {
  const { pathname } = new URL(request.url);
  if (pathname === "/health") {
    if (request.method !== "GET") return err(405, "method_not_allowed", { Allow: "GET" });
    return json(200, { ok: true });
  }
  if (pathname === "/v1/extract") {
    if (request.method !== "POST") return err(405, "method_not_allowed", { Allow: "POST" });
    return handleExtract(request, env);
  }
  return err(404, "not_found");
}

export default {
  async fetch(request, env) {
    try {
      return await handle(request, env);
    } catch {
      return err(500, "internal");
    }
  },
};
