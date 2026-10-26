# Bridgey OTP proxy

A tiny Cloudflare Worker for Bridgey by Round Robin. The Mac app sends the text of one SMS that probably holds a one-time code. The Worker asks Cloudflare Workers AI which token is the code and returns JSON. The Workers AI binding lives on the server, so no API key ships in the app.

Plain JavaScript ES modules, no build step, no runtime dependencies.

## Contract

`POST /v1/extract`

- Headers: `Content-Type: application/json` and `X-Bridgey-Install: <64 lowercase hex chars>`. The install id is a random per-install value used only as a rate-limit key. Missing or malformed: 401 `{"error":"install_id"}`.
- Body: `{"v":1,"text":"<sms body>","sender":"<optional, max 64 chars>"}`.
- Errors:
  - 415 wrong content type.
  - 413 `{"error":"too_large"}`: raw body over 2048 bytes.
  - 400 `{"error":"bad_request"}`: not JSON, wrong types, `v` not 1, `text` empty after trim or over 600 chars, `sender` over 64 chars.
  - 422 `{"error":"not_otp_like"}`: the text has no candidate token (see below).
  - 429 `{"error":"rate_limited"}` with `Retry-After: 60`.
  - 502 `{"error":"upstream"}`: AI error or unparseable answer.
  - 504 `{"error":"timeout"}`: no answer within `AI_TIMEOUT_MS` (default 1500).
  - 503: a rate-limit binding is missing (fails closed).
- Success 200: `{"is_otp": <bool>, "code": <string or null>}`. `code` is 1 to 24 characters or null, and always null when `is_otp` is false. The Worker does no further check. Clients must verify that the code appears verbatim in the SMS.

`GET /health` returns 200 `{"ok":true}` with no AI call and no rate limit. Unknown paths return 404, wrong methods 405.

All responses are `application/json` with `Cache-Control: no-store` and no CORS headers.

### OTP-like gate

The text must match rule A or rule B (both must not be preceded or followed by a letter/digit):

- A: `(?<![0-9A-Za-z])(?=[0-9A-Za-z]*\d)[0-9A-Za-z]{4,10}(?![0-9A-Za-z])`, a run of 4 to 10 letters/digits with at least one digit.
- B: `(?<![0-9A-Za-z])\d{2,5}[ -]\d{2,5}(?![0-9A-Za-z])`, two digit groups split by one space or hyphen (`591-047`, `441 902`).

It is the exported pure function `looksLikeOtpTraffic(text)`. The Mac and Android apps apply the same rule before calling. It is deliberately loose: most non-OTP SMS with any number still pass, and the model makes the real decision.

## Privacy

- The Worker never logs request data: no `console.*` calls touch the text, sender or code.
- `[observability] enabled = false` in `wrangler.toml`, so no request logs or traces are kept.
- Responses are not cached.
- Cloudflare states that it does not use customer content processed by Workers AI to train models.
- The install id is used only as a rate-limit key.

## Rate limits

Workers Rate Limiting bindings, each 60 second window:

| Binding | Limit | Key | Why |
| --- | --- | --- | --- |
| `PER_INSTALL` | 10 | install id | one app cannot hammer the model |
| `PER_IP` | 30 | `CF-Connecting-IP` | bounds a script that rotates install ids |
| `GLOBAL` | 30 | constant `global` | caps total Workers AI spend |

Install and IP limits are checked before the AI call, then the global one. The limits are per Cloudflare location and approximate, which is fine for abuse control.

## Tests

```
cd services/otp-proxy
node --test
```

Uses a fake env (AI mock, rate-limit mocks). No network, no install step.

## Run locally

```
cd services/otp-proxy
npx wrangler@4 dev --port 8799
```

Workers AI always calls Cloudflare remotely, even in local dev, so wrangler needs credentials (see Deploy). Then:

```
curl -s localhost:8799/v1/extract \
  -H 'Content-Type: application/json' \
  -H "X-Bridgey-Install: $(printf 'a%.0s' $(seq 64))" \
  -d '{"v":1,"text":"482913 is your test code","sender":"TEST"}'
```

Use only synthetic messages.

## Deploy (Round Robin Solutions Cloudflare account)

`account_id` is not in `wrangler.toml`. Set these from the vault in the shell (never write the values into files):

```
export CLOUDFLARE_ACCOUNT_ID=...   # Round Robin Solutions account id
export CLOUDFLARE_EMAIL=...        # account member email
export CLOUDFLARE_API_KEY=...      # that member's global API key
cd services/otp-proxy
npx wrangler@4 deploy
```

The Worker is served at `https://bridgey-otp-proxy.<account-subdomain>.workers.dev` (`workers_dev = true`). Check `/health`, then send one synthetic message to `/v1/extract`.

Live since 2026-10-26: `https://bridgey-otp-proxy.cs-share.workers.dev` (the address in `rr-edition.properties` `OTP_PROXY_URL`). The account is on Workers Free, so Workers AI stops answering after the free daily allocation instead of billing; the apps then show the plain notification. Cloudflare's browser check answers some default HTTP agents (Python's urllib, for one) with `403 error code: 1010`; the apps send `User-Agent: BridgeyRR/1 (macOS)` or `(Android)`, and manual tests should set an agent too.

## Roll back

```
npx wrangler@4 deployments list
npx wrangler@4 rollback            # previous version, or pass a version id
npx wrangler@4 delete              # remove the Worker entirely
```
