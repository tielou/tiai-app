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

## Round 3 — the completion handshake

**Assumption 1 holds.** A completion streams over plain REST SSE with no
websocket session at all: deltas arrived, the text was exact, and
**time to first token was 1.1 s** on a warm prompt.

**Assumption 2 failed — and it was our bug, not the server's.** The read-back
contained only the user's turn:

```
persisted turns: user
FAIL the assistant turn is empty
```

The reason is worth keeping, because nothing in the API docs would tell you:
the server derives its message id from the request's **`id`** field
(`message_ids = [{'model_id': model_id, 'message_id': form_data.pop('id', None)}]`),
and that becomes `metadata['message_id']`. Without it `get_event_emitter`
returns `None`, and *every* persistence path is gated on the emitter existing.
So the model answers, the stream completes, nothing is written, and no error is
reported anywhere. `assistant_message_id` is a different field meaning
"continue this existing message" — the name misled us.

`stop` answered **405 Method Not Allowed** for the same family of reason: the
task routes are mounted at the root (`/api/tasks/chat/{id}/stop`) and have no
`/api/v1` alias, unlike the completion route.

Also observed: **no `usage` on the stream**, because none of the models
advertise a `usage` capability, so the server does not ask the upstream for
`include_usage`. Token counts are therefore a nice-to-have in this deployment,
not a guarantee — the UI must not assume they arrive.

Memories: 6. Prompts: 0. Chats: 140.

## Round 5 — the POST is not a handoff

Reading the server again after the socket work: `streaming_chat_response_handler`
ends with `return await response_handler(response, events)`, and `response_handler`
has no `return` — it consumes the entire upstream stream inside the request and
yields `None`. So the completion POST **does not answer until the model has
finished**, and then answers with an empty body.

Two consequences, both of which bit the probe before they were understood:

* The app cannot POST and then start listening. The request must be started in a
  concurrent task and the socket read in parallel — which is also why Stop has to
  be a separate request fired while the completion POST is still in flight.
* A collection loop whose deadline is only checked when a frame arrives hangs
  forever when nothing arrives. The probe hung exactly that way; the deadline is
  now a watchdog that ends the stream from the side.

## Round 6 — the socket is at `/ws/socket.io`, websocket-only

`GET /socket.io/?EIO=4&transport=polling` returns the **SPA's index.html** with
200. The socket.io ASGI app is mounted elsewhere:

```python
app.mount('/ws', socket_app)                      # main.py
app = socketio.ASGIApp(sio, socketio_path='/ws/socket.io')   # socket_main.py
```

and the server is built with `transports=['websocket']`, so polling is refused
with `400 "Invalid transport"`. Verified by hand:

```
GET /socket.io/?EIO=4&transport=polling      → 200 text/html   (the SPA, not the socket)
GET /ws/socket.io/?EIO=4&transport=polling   → 400 Invalid transport
WS   /ws/socket.io/?EIO=4&transport=websocket → 101 Switching Protocols
```

So: path `/ws/socket.io`, `forceWebsockets(true)`, no polling fallback. The
`/api/config` flag `enable_websocket` says *whether*, never *where* — the path is
a constant on both sides, which is the kind of thing that fails silently, because
a 200 with HTML looks like success to a naive client.

Auth rides in the socket.io CONNECT packet (`connect(withPayload: ["token": …])`),
which is where the server's `connect(sid, environ, auth)` reads `auth['token']`.
The library re-sends that payload once the engine opens, so starting the connect
before the websocket is up does not lose it.

## Round 7–8 — the event vocabulary, from live traffic

The socket connects, the room join works, and a short completion produced 52
frames for the chat. Captured verbatim to `tiai-frames.jsonl` and checked in as
`Tests/TiAiKitTests/Fixtures/socket-frames.jsonl`, with a test that replays all
52 and asserts the answer reconstructs exactly.

Envelope for every frame: `{chat_id, message_id, data: {type, data}}`.

Outer `data.type`:

| type | count | meaning |
|---|---|---|
| `response:completion` | 50 | everything about the model's output |
| `chat:completion` | 1 | the terminal frame (see below) |
| `chat:list` | 1 | chat-list mutation — the app can invalidate its list on these instead of polling |

The inner `data.data` is **two different shapes inside one completion**:

1. **OpenAI chunk** (`object: chat.completion.chunk`, `choices[]`) — only at the
   boundaries. The opening frame announces `role: assistant` with empty content;
   the closing frame carries `finish_reason: stop`.
2. **Responses-API event** (`type`, `delta`, `item_id`, `output_index`) — every
   real token. `response.output_text.delta` is the answer,
   `response.reasoning_text.delta` is thinking, and thinking came first: 41
   reasoning frames before the first answer frame.

So `time to first token` has to ignore reasoning. Measured honestly on this run:
first reasoning 0.2 s, first answer token later. A client that counts the first
frame as a token reports 0 ms and shows nothing.

The opening chunk carries `delta: {content: ""}` — non-nil, empty. A client that
treats "a frame with a delta" as the first token reports the moment the job was
accepted rather than the moment text appeared, and shows a spinner while tokens
arrive. **First token = first non-empty delta.**

**There is no `done` frame.** The only end-of-stream signal in a real run is the
`chat:completion` frame carrying `finish_reason`. `Frame.isTerminal` is
`isDone || isFinish` so the app has one thing to check and still works if a
future version adds `done`.

Ordering is not guaranteed and is not asserted. Reasoning led by 1.7 s on one
model and arrived at the same instant as the opener on another; a client that
requires an order will break on a model that interleaves them.

No `usage`, `error`, `status`, `citations` or tool frames appeared for this model
— the local engine reports none. Those decoders stay tolerant and unproven until
a model that emits them is probed.

Both decoding mistakes were made against this capture: first reading only the
Responses-API shape (found the deltas, missed the terminal frame), then only the
OpenAI shape (found the terminal frame, lost the entire answer while 50 content
frames sat in the same output). The replay test is what makes a third attempt
expensive rather than silent.

## The stop endpoint is not self-reporting

`POST /api/tasks/chat/{id}/stop` returns 200 whether or not the generation
haltingly actually halts. One run fired it at the sixth delta and the stored
answer came back 10829 characters long, which is either a fast model or a stop
that did nothing — indistinguishable from the response alone.

The probe now checks the only thing that matters: the stored answer stops
growing. Sample, wait 4 s, sample again, and it also reports whether the REST
stream closed after the stop or was still open 45 s later. Until that prints a
pass, the Stop button is unverified, not verified.

## Still to verify

* [ ] **assumption 2, re-run after the `id` fix** — after the stream,
      `GET /chats/{id}` contains both turns, with `done`, `statusHistory` and `usage`
* [ ] `POST /api/tasks/chat/{id}/stop` actually stops generation
* [ ] deleting the probe chat works (passed in round 3)

## Decisions this has already changed

* **The app creates chats before streaming into them.** Sending no `chat_id`
  makes the server mint its own and report it over the websocket, which a
  REST-only client never sees.
* **Every completion must carry a client-generated `id`.** Not optional, and it
  fails silently rather than loudly — `completionCarriesTheAssistantMessageID`
  is the only thing standing between a refactor and a chat app that loses every
  reply.
* **The task routes are unversioned.** `Server.api` vs `Server.raw` is not
  cosmetic.
* **`features` is a dict of booleans**, not the list of strings older versions took.
* **Message keys inside a chat body are camelCase** while the rest of the API is
  snake_case, so no global `keyDecodingStrategy` is possible; every DTO maps its
  keys explicitly.
* **Tests assert on requests, not only responses.** `RecordingTransport` exists
  because a response fixture alone could never have caught either of these.
