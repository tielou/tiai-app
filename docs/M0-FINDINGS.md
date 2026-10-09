# M0 — findings

The spike's job was to falsify the two assumptions the whole plan rests on
before anything was built on top of them:

1. a completion streams over plain REST SSE with **no websocket session**;
2. the server persists the transcript well enough that a REST-only client can
   reconcile a finished message from `GET /chats/{id}`.

Run it with `make probe` (see README). Results are appended below by whoever
ran it, with the server version.

## Against the live instance

Blocked on credentials: the probe needs a token or a password, and neither is
in the repo by design. To complete this section:

```bash
TIAI_URL=https://chat.wobker.co \
TIAI_EMAIL=… TIAI_PASSWORD=… \
swift run tiaiprobe
```

### Verified without a token

| check | result |
|---|---|
| `GET /health` | 200, `{"status":true}` |
| `GET /api/version` | `0.11.4` |
| `GET /api/config` | `features.enable_websocket = true`, `features.enable_signup = false` |
| `POST /api/v1/auths/signin` with bad credentials | 400 with `{"detail": "…"}` — FastAPI error envelope confirmed |
| `GET /api/v1/models` without a token | 401 `{"detail":"Not authenticated"}` |
| `/openapi.json` | **not served** — returns the SPA shell, so there is no machine-readable spec to generate from. DTOs are hand-written and tolerant. |

One finding already paid for itself: `enable_websocket` is nested inside
`features`, not at the root of `/api/config`. The first version read it from the
root and reported "no websocket", which is the kind of silent wrong answer that
would have shaped the design. `ContractTests.configReadsFlagsWhereTheServerPutsThem`
now pins it.

### To be verified with a token

* [ ] password sign-in returns a token
* [ ] model list decodes, and `defaultFeatureIds` is populated for the models that have web search on by default
* [ ] `POST /chats/new` returns an id
* [ ] **assumption 1** — `POST /chat/completions` streams deltas over SSE with no socket session
* [ ] time to first token on a cold prompt (halogen: expect 1–25 s depending on context)
* [ ] **assumption 2** — after the stream, `GET /chats/{id}` contains both turns, with `done`, `statusHistory` and `usage`
* [ ] `POST /tasks/chat/{id}/stop` actually stops generation
* [ ] memories, prompts and the chat list decode
* [ ] deleting the probe chat works

## Decisions this already changed

* **The app creates chats before streaming into them.** Sending no `chat_id`
  makes the server mint its own and report it over the websocket, which a
  REST-only client never sees. `POST /chats/new` first is one extra round trip
  and matches what the browser does.
* **`features` is a dict of booleans**, not the list of strings older versions
  took.
* **Message keys inside a chat body are camelCase** while the rest of the API is
  snake_case, so no global `keyDecodingStrategy` is possible. Every DTO maps its
  keys explicitly.
