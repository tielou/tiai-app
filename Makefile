.PHONY: build test probe app-check check project icon clean install ios ios-release uitest project-gen

# The simulator the app is built for and installed onto.
SIM_UDID = 92C09667-3F60-4C1B-A548-3C863E2B6E63

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

## Drives the built app on a simulator through the accessibility tree.
##
## These are the tests that catch a control which renders and does nothing — the
## class of bug unit tests cannot see, because the request was correct and the
## view never fired it. They skip themselves on a simulator that has never
## signed in, so this is a developer command, not a CI gate.
uitest: app
	xcodebuild -project TiAi.xcodeproj -scheme TiAi \
	  -destination 'platform=iOS Simulator,name=iPhone 16e' \
	  -only-testing:TiAiUITests test

## Release configuration, which is the one TestFlight builds.
##
## This exists because a `#if DEBUG` mistake — a debug-only helper called from
## unguarded code — compiles clean under `make ios` and fails the archive on a
## runner three minutes and one dispatch later. Run this before triggering a
## build and that class of failure dies here instead.
## Build the simulator app and put it on the running simulator, in one step.
##
## Splitting "build" from "install" caused a real bug: a Release archive was
## built, the fix was confirmed, and the *stale Debug* product from an hour
## earlier was installed instead — so the fix was tested and reported as not
## working. There is no reason to ever install something you did not just build.
install: app
	xcodebuild -quiet -project TiAi.xcodeproj -scheme TiAi \
	  -destination 'platform=iOS Simulator,name=iPhone 16e' build
	xcrun simctl terminate $(SIM_UDID) co.wobker.tiai 2>/dev/null || true
	xcrun simctl install $(SIM_UDID) \
	  $$(ls -d $$HOME/Library/Developer/Xcode/DerivedData/TiAi-*/Build/Products/Debug-iphonesimulator/TiAi.app | head -1)
	xcrun simctl launch $(SIM_UDID) co.wobker.tiai

ios-release: app
	xcodebuild -quiet -project TiAi.xcodeproj -scheme TiAi \
	  -destination 'generic/platform=iOS' -configuration Release build \
	  CODE_SIGNING_ALLOWED=NO

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
