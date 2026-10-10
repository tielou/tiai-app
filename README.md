# tiAi

A native iOS client for a self-hosted Open WebUI instance. Chat with your own
assistant the way you would with any native app — streaming, offline list,
attachments, memories — while the server keeps being the single place your
conversations live.

**Status: in daily use.** Chat, streaming, attachments, notes, memory, tools and
sign-in all work against a live server. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how it is put together.

## What is in it

Conversations stream token by token, with reasoning in a collapsed *Thoughts*
section and a drawn cat while a slow model warms up. Markdown renders headings,
lists, quotes and code, and a web-search answer carries its sources, numbered to
match the `[1]` markers in the text.

Attachments go both ways: camera, photo library and files from the phone, and a
picture attached in the web UI renders here too. Messages can be edited and
resent, regenerated answers become siblings you page through, and answers can be
rated.

Tools come from the server rather than being compiled in — whatever MCP servers
the instance has are listed, and one that needs signing in opens the sign-in in
app. Notes are the server's notes: list, read, edit, create, delete, shared with
the web UI. Memory is read from the server too.

Dark mode, iPad and iPhone, and no telemetry of any kind.

## What it is not

It is not a hosted service and it is not a wrapper around one vendor's model.
There is no backend here: tiAi speaks the HTTP API of whatever Open WebUI you
already run, so accounts, history, memories, tools, web search and retrieval all
stay where they are. If you have the web UI, you have everything tiAi needs.

## Using it

Install, type your server's URL, sign in with the same credentials the web UI
takes. Your existing conversations appear.

Nothing about anyone's server is compiled into the binary — the app is safe to
hand to someone else, and they will be talking to their own machine and nobody
else's. There is no analytics, no crash reporter and no second host: the app
opens exactly one connection, to the address you typed.

## Building

Requires Xcode for the app and the Command Line Tools for everything else.

```bash
make check                # build + typecheck + tests — no Xcode needed
make project              # generates TiAi.xcodeproj (needs `brew install xcodegen`)
open TiAi.xcodeproj       # run in the simulator or on a device
```

`make check` is the gate. It runs on any Mac because the kit compiles for macOS
as well as iOS — see the architecture note on why that matters.

### Talking to a real server from the command line

```bash
TIAI_URL=https://chat.example.co \
TIAI_TOKEN=… \
swift run tiaiprobe
```

`TIAI_TOKEN` can be a per-user API key (Open WebUI → Settings → API Keys) or the
JWT from the browser's devtools. `TIAI_EMAIL` + `TIAI_PASSWORD` work instead.
The probe walks the API end to end — sign-in, models, a streamed completion, the
persisted transcript, stop, memories, prompts — and prints which assumptions
held. It is the first thing to run after any server upgrade.

## Distribution

TestFlight, via `.github/workflows/testflight.yml`: a macOS runner archives the
app, signs with an App Store Connect API key and uploads. Manual trigger, because
macOS runners bill at ten times the rate of the Linux ones and a homelab app does
not need a new build per commit.

## Layout

```
Package.swift                 TiAiKit: iOS 18 + macOS 15
project.yml                   XcodeGen definition for the app target
App/TiAiApp.swift             the @main shell — deliberately almost empty
Sources/TiAiKit/
  API/                        client, transport, SSE framing, keychain
  Models/                     tolerant Codable DTOs
  Streaming/                  SSE frames → normalized ChatEvents
  Store/                      session state
  Support/                    Resource, JSONValue
  Views/                      screens + the iOS-only modifiers
Sources/TiAiProbe/            the contract probe
Tests/TiAiKitTests/           swift-testing + real captured fixtures
docs/ARCHITECTURE.md          why it is shaped like this, and the API contract
```
