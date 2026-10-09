# M0 — findings

The spike's job was to falsify the two assumptions the whole plan rests on
before anything was built on top of them:

1. a completion streams over plain REST SSE with **no websocket session**;
2. the server persists the transcript well enough that a REST-only client can
   reconcile a finished message from `GET /chats/{id}`.

Run it with `swift run tiaiprobe` (see README). Results below are from the live
instance, Open WebUI **0.11.4**.

## Round 1 — unauthenticated

| check | result |
|---|---|
| `GET /health` | 200 `{"status":true}` |
| `GET /api/version` | `0.11.4` |
| `GET /api/config` | `features.enable_websocket = true`, `features.enable_signup = false` |
| `POST /api/v1/auths/signin` bad credentials | 400 `{"detail": "…"}` — FastAPI error envelope confirmed |
| `/openapi.json` | **not served** — returns the SPA shell, so there is no machine-readable spec to generate from. DTOs are hand-written and tolerant. |

**Cost already paid:** `enable_websocket` is inside `features`, not at the root.
The first version read it from the root and reported "no websocket" — a silent
wrong answer that would have shaped the design. Pinned by
`configReadsFlagsWhereTheServerPutsThem`.

## Round 2 — authenticated

Sign-in works and hands back a JWT. The model list decoded, and it corrected
another guess:

```
local-personal   caps=[builtin_tools,citations,file_context,file_upload,memory,
                       status_updates,vision,web_search]              defaultFeatures=[web_search]
local-deep       caps=[… ,code_interpreter,image_generation,terminal] defaultFeatures=[web_search]
local-fast       caps=[]                                              defaultFeatures=[]
local-quick      caps=[]                                              defaultFeatures=[]
claude-haiku-halogen  caps=[]                                         defaultFeatures=[]
```

Three things learned:

* **Capability names are the server's, not the app's** — `citations`,
  `builtin_tools`, `status_updates`, `web_search`. There is **no `thinking`
  capability at all**: thinking is a route (`local-personal` vs `local-fast`),
  not a flag. The first DTO guessed `citation`/`tools` and would have silently
  hidden features the user actually has.
* **An empty capability map means "no metadata", not "no features."** The fast
  and quick routes advertise nothing; gating on the map would have switched web
  search off exactly where it is used most. `ChatModel.supports(_:)` treats an
  empty map as "offer everything".
* **`defaultFeatureIds = ["web_search"]` is real and per-model**, stored in the
  database rather than in any config file. The composer must seed its toggles
  from it, or the phone and the browser disagree about whether a message is
  about to hit a search engine.

Then `POST /chats/new` answered:

```
422 {"detail":[{"loc":["body","chat"],"msg":"Field required","input":{"title":"…"}}]}
```

The router takes the **whole chat document** — `{"chat": {"title": …, "history": …}}`
— not a title. Fixed, and `RequestTests.createChatSendsTheChatDocument` now
asserts on the outgoing body, because a response fixture alone could never have
caught this.

While in there: there is **no `/chats/{id}/title` route** (rename goes through
`POST /chats/{id}`, which copies `chat.title` onto the column), and `pin` /
`archive` are **toggles** with no per-chat un-pin/un-archive, so the client
reports the new state instead of asserting a wanted one.

## Still to verify

* [ ] **assumption 1** — `POST /chat/completions` streams deltas over SSE with no socket session
* [ ] time to first token on a cold prompt (halogen: expect 1–25 s depending on context)
* [ ] **assumption 2** — after the stream, `GET /chats/{id}` contains both turns, with `done`, `statusHistory` and `usage`
* [ ] `POST /tasks/chat/{id}/stop` actually stops generation
* [ ] memories, prompts and the chat list decode
* [ ] deleting the probe chat works

## Decisions this has already changed

* **The app creates chats before streaming into them.** Sending no `chat_id`
  makes the server mint its own and report it over the websocket, which a
  REST-only client never sees.
* **`features` is a dict of booleans**, not the list of strings older versions took.
* **Message keys inside a chat body are camelCase** while the rest of the API is
  snake_case, so no global `keyDecodingStrategy` is possible; every DTO maps its
  keys explicitly.
* **Tests assert on requests, not only responses.** `RecordingTransport` exists
  because of this bug.
