# tiAi — architecture

A native iOS client for a self-hosted [Open WebUI](https://openwebui.com)
instance. It is a *view* on someone's existing assistant: the server keeps
owning the accounts, the chat history, the memories, the tools, the web search
and the retrieval, and the phone is one more window onto all of it. Sign in on
the phone and the conversations you had in the browser are already there.

There is deliberately **no backend of our own.** Every feature the web UI has
comes from talking to the same API, and there is nothing new to run, secure or
back up.

```
┌──────────────────────────── iPhone ────────────────────────────┐
│  TiAi.app  (SwiftUI, iOS 18+, XcodeGen-generated project)      │
│                                                                │
│  Screens: Chats · Conversation · Composer · Memory · Prompts ·  │
│           Settings                                              │
│         │                                                      │
│  ┌──────▼───────────────────────────────────────────────┐       │
│  │ TiAiKit (SwiftPM, builds for iOS *and* macOS)        │       │
│  │  API/       OWUIClient · APITransport · SSEParser    │       │
│  │  Models/    tolerant Codable DTOs                    │       │
│  │  Streaming/ ChatEventStream · ChatEvent              │       │
│  │  Store/     SessionStore · (ChatStore)               │       │
│  │  Support/   Resource · JSONValue · Keychain          │       │
│  │  Views/     RootView · Compatibility                 │       │
│  └──────┬───────────────────────────────────────────────┘       │
│    URLSession (SSE)      [later] socket.io side channel         │
└─────────┼───────────────────────────────────────────────────────┘
          │ Authorization: Bearer <jwt | api key>
          ▼
   Open WebUI ──► gateway (LiteLLM &c.) ──► whatever model the operator runs
      │
   postgres · search · tools/MCP · memories · files
```

## Why it is shaped like this

**The kit builds for macOS as well as iOS.** `swift build` and `swift test`
verify the models, the client, the streaming parser and every view on a machine
with only the Command Line Tools — no Xcode, no simulator, no Apple ID. That is
also what keeps a Mac build one target away. The cost: no UIKit-only API in
`Sources/TiAiKit`; the handful of iOS-only modifiers are collected in
`Views/Compatibility.swift`.

**The app target is a shell.** `App/TiAiApp.swift` wires `@main` and nothing
else, so everything real is in the kit and therefore testable.

**Nothing about a particular server is compiled in.** No default host, no
tenant, no assumption. Whoever installs the app types their own URL. That is
what makes it shareable, and it is why `Server.parse` has to cope with what
people actually type into a text field.

**Tolerant decoding, everywhere.** Open WebUI is a FastAPI service whose
maintainers move the API — `/api/...` became `/api/v1/...` in 0.11 — and the
phone is in a pocket when that happens. Every enum carries an unknown case,
every display-only field is `decodeIfPresent` plus a default, and only fields
the app cannot function without decode strictly. `ContractTests` pins both
halves of that line.

**One transport seam.** `APITransport` has two methods, `send` and `bytes`,
because a chat completion is not a request/response call. Tests substitute a
fake and assert on the request that went out. `ChatEventStream` is the only
place that knows what a completion frame looks like; the UI renders
`ChatEvent`s and never parses JSON. That is what lets the same screen be driven
by the SSE stream today, by the websocket side channel later, and by a fixture
in tests.

## The API contract, as actually observed

Reference notes; the code links back to this section.

* **Prefix.** Routers are mounted at `/api/v1/…` since 0.11
  (`backend/open_webui/main.py`). A few legacy aliases exist at `/api/…`, and
  `/health`, `/api/version`, `/api/config` are mounted at the root. Build paths
  through `Server.api` / `Server.raw` so a future move is one edit.
* **Auth.** `POST /api/v1/auths/signin` → `{…, token}`; send it as
  `Authorization: Bearer`. A per-user API key (Settings → API Keys) is accepted
  in the same header and does not expire. **The JWT has no refresh endpoint**
  and expires after `JWT_EXPIRES_IN` (default `4w`), so `SessionStore` treats
  "signed in" as a countdown and can optionally re-login silently with a
  keychain-held password.
* **Models.** `GET /api/v1/models` → `{"data":[…]}`, OpenAI-shaped with an
  `info.meta` object holding `capabilities`, `defaultFeatureIds` and
  `base_model_id`. `defaultFeatureIds` is what makes "web search is on by
  default for this model" true, and it lives in the database, not in any config
  file — the composer must seed its toggles from it or the phone and the
  browser disagree about whether a message is about to hit a search engine.
* **Config flags.** `enable_websocket` and `enable_signup` are inside the
  `features` object of `/api/config`, not at the root. Reading them from the
  root reports `false` silently.
* **Chats.** `GET /chats/list`, `/chats/search?text=`, `/chats/pinned`,
  `/chats/archived`, `GET /chats/{id}`, `POST /chats/new`, `POST /chats/{id}/pin`,
  `/archive`, `/title`, `DELETE /chats/{id}`, `DELETE /chats/{id}/messages/{mid}`.
  A chat body is a **tree**: messages carry `parentId`/`childrenIds` and
  `history.currentId` marks the branch being read, which is how regenerate
  creates a sibling instead of destroying the original. `ChatMessage.tree`
  walks it; flattening the map to an array throws the feature away.
* **Message keys are camelCase** inside a chat body (`parentId`, `statusHistory`,
  `model`, `timestamp`) while the rest of the API is snake_case. That mixture is
  deliberate on their side — the router models are Pydantic, the chat blob is
  the Svelte client's document mirrored out of the `chat_message` table.
* **Completion.** `POST /api/v1/chat/completions` with
  `model, messages, stream, chat_id, parent_id, user_message, assistant_message_id,
  features, files, params`. Three things a naive OpenAI client gets wrong:
  * `parent_id` is intent and its *presence* matters: absent = "don't manage my
    chat", `null` = "root message", value = "branch from here". Hence
    `CompletionRequest.ParentID` being an enum rather than an optional string.
  * `user_message` is what gets persisted as the user's turn. Omit it and the
    model still answers while the stored transcript loses the question.
  * `features` is a dict of booleans (`{"web_search": true}`), not the list of
    strings older versions took, and each flag is re-checked against the user's
    permissions server-side.
* **The new-chat handshake.** If no `chat_id` is sent the server mints a uuid
  and reports it over the websocket, which a REST-only client never sees. So the
  app creates the chat first with `POST /chats/new` and streams into it. One
  extra round trip, and the chat appears in the list immediately like it does in
  the browser.
* **Streaming.** The REST response is SSE of OpenAI `chat.completion.chunk`
  frames, terminated by `data: [DONE]`. **The rich events are not on it.**
  `status`, `message`, `replace`, `source`/`citation`, `embeds`, `files`,
  `chat:completion` and `chat:message:error` are emitted by
  `get_event_emitter` (`socket/main.py`) to the socket.io room `user:<id>`,
  namespace `/socket.io/`, `auth: {token}`. Two consequences:
  1. a REST-only client gets every token but no live "searching the web" or
     tool cards;
  2. the same emitter *persists* status/sources/embeds onto the chat message, so
     `GET /chats/{id}` after the stream contains them. That is the v1 fallback
     and it needs no socket.
  Models configured as direct/BYOK connections *do* require a live socket
  session; server-side models do not.
* **Stop.** `POST /api/v1/tasks/chat/{chat_id}/stop`. Cancelling the local task
  is not enough — the server would keep generating into the chat and the message
  would land half-written.
* **Around the chat.** `/memories/`, `/memories/add`, `/memories/{id}/update`,
  `DELETE /memories/{id}`; `/prompts/`; `/files/` (multipart, returns an id that
  goes into the message's `files`); `/evaluations/feedback`; `/knowledge/`;
  `/notes/`; `/audio/speech`, `/audio/transcriptions`.

## Milestones

* **M0 — probe.** Done, see `docs/M0-FINDINGS.md`. `swift run tiaiprobe`.
* **M1 — kit.** Auth + keychain, models, chat list/detail, SSE streaming,
  cancel, error taxonomy, contract tests. **Done.**
* **M2 — conversation.** The transcript screen: incremental markdown, code
  blocks, reasoning disclosure, composer with model and feature pickers,
  attachments, regenerate/edit/branch, stop. First TestFlight build.
* **M3 — around the chat.** Memory, prompts, search, share/export, settings,
  diagnostics, theme.
* **M4 — live events.** socket.io side channel for status, tool cards and
  citations, replacing the post-stream reconcile.
* **M5 — the native-only layer.** Voice (on-device STT/TTS), widgets, Live
  Activity for long generations, share extension, Shortcuts, iPad/Mac.

## Working on it

```bash
make check            # build + app-check + test — the gate, needs no Xcode
make probe            # contract probe against a real server (see README)
make project          # xcodegen -> TiAi.xcodeproj
```

Fixtures in `Tests/TiAiKitTests/Fixtures/` are real captured payloads with the
identifiers scrubbed, not hand-written idealisations — the value is in the parts
nobody would invent, like a `content` that is a block array or a model record
with no `info` at all.
