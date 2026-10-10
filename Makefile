.PHONY: build test probe app-check check project icon clean

## Compiles the kit for macOS. This is the whole point of the split: no Xcode,
## no simulator, no Apple ID -- just the Command Line Tools.
build:
	swift build

test:
	swift test

## Type-checks the @main shell against the built kit. Without Xcode this is the
## only coverage App/ gets, and it catches the boring breakage -- a renamed
## view, a changed initialiser -- before it reaches a machine with Xcode.
app-check: build
	xcrun swiftc -typecheck -parse-as-library App/TiAiApp.swift -I .build/debug/Modules

## Compiles the app for a simulator. `swift build` compiles the kit for macOS,
## which silently skips every `#if os(iOS)` block in the kit — and that is where
## the camera, the photo picker and the OAuth browser live. An in-app browser
## that did not compile (a WKWebView is a view, not a view controller) passed
## `make check` and failed the archive. Needs Xcode, so it is not in `check`.
ios:
	xcodebuild -quiet -project TiAi.xcodeproj -scheme TiAi \
	  -destination 'platform=iOS Simulator,name=iPhone 16e' build

## The gate. Everything that runs without Xcode, and therefore everything that
## runs on any machine, including the one you are on.
check: build app-check test

## Runs the contract probe. Needs a server:
##   TIAI_URL=https://chat.example.co TIAI_TOKEN=… make probe
## or TIAI_EMAIL / TIAI_PASSWORD. See docs/ARCHITECTURE.md.
probe:
	swift run tiaiprobe

## Requires Xcode (not the Command Line Tools) plus `brew install xcodegen`.
project:
	xcodegen --spec project.yml

## Regenerates the app icon. TestFlight rejects a build whose asset catalog has
## no AppIcon, so the output is committed rather than remembered.
icon:
	python3 scripts/make-icon.py

clean:
	rm -rf .build TiAi.xcodeproj
