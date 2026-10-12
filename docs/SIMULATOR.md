# Driving the Simulator from the CLI

Verified against iPhone 16e / iOS 26.3, Xcode 26.3. This exists because the
obvious way to do it does not work, and the failure looks like a bug in the app.

## Coordinates

The device screen is 390×844 pt; `simctl io screenshot` returns 1170×2532 (3×).
The Simulator window adds chrome, so a screenshot pixel is not a screen pixel.

```bash
osascript -e 'tell application "System Events" to tell process "Simulator" to get position of window 1'
# → 878, 84   (measured once per session; the window moves between runs)
```

With that window origin, the device screen starts at `origin + (31, 76)`:

```
screen_x = win_x + 31 + device_pt_x
screen_y = win_y + 76 + device_pt_y
```

Do not trust remembered coordinates. Measure the element in the screenshot and
convert:

```python
# knob centre of a toggle, in device points
run = [x for x in range(850, 1160, 2) if min(px[x, y]) > 230]
```

## Taps

`cliclick c:x,y` sends a down and an up with no delay. **Buttons respond to it;
`Toggle` switches do not.** A toggle silently ignores the tap, which looks
exactly like a broken binding — several hours went into diagnosing a `Toggle`
that was fine.

For anything that is not a plain button:

```bash
cliclick dd:x,y && sleep 0.25 && cliclick du:x,y
```

Scroll with a drag: `dd:` → a few `dm:` steps → `du:`.

## Text

`osascript keystroke` drops characters. Use the pasteboard:

```bash
xcrun simctl pbcopy $UDID < /tmp/text   # then Cmd+V
```

Clear it afterwards — the pasteboard is shared with the host.

## When taps stop working entirely

Simulator networking and input go stale after a long session (`-1009`, or
touches that do nothing). Fix:

```bash
xcrun simctl shutdown $UDID && xcrun simctl boot $UDID
```

## Emoji render as boxes in the Simulator

The runtime is not the app. A plain `TextField` boxes them, and Safari in the
same simulator boxes every emoji on Wikipedia's emoji page. The runtime ships
only `AppleColorEmoji-160px.ttc`. Copying the host's font in and rebooting does
nothing: the runtime volume is sealed read-only APFS. Check emoji on a device.

## Coordinate mapping (re-derived 2026-10-12; the 10-09 numbers were also wrong)

The window frame AppleScript reports is **not** the device screen. The Simulator
draws a title bar and a device chassis inside the window, so the screen is inset
by roughly 22pt left, 78pt top, 29pt right and 11pt bottom from the reported
window box. Using the window origin as the screen origin puts every click ~70pt
too high, which looks like "the clicks just do nothing".

Derive it instead of remembering it. The mapping is affine in device points:

    mac_x = OX + KX * dev_x        mac_y = OY + KY * dev_y

and two confirmed hits pin it down. As measured on 2026-10-12 (window at
878,84, size 441x928, iPhone 16e at 100% zoom):

    mac_x = 907.2 + 0.9974 * dev_x
    mac_y = 166.9 + 0.9941 * dev_y

`dev_*` are **points** (screenshot pixels / 3), and the result is in Mac points —
`screencapture` returns pixels at 2x, so divide by two before using a landmark
measured from a full-screen capture.

**Always confirm the mapping before driving anything**, because it changes with
window position and zoom. Tap a chat row (a ~90pt tall target, so it forgives a
few points of error) and check the big `Chats` title disappeared:

    cliclick m:1102,352 && sleep 0.3 && cliclick c:1102,352
    xcrun simctl io <udid> screenshot /tmp/v.png
    # bright pixels in the title band drop to 0 once you have navigated

If that click does not navigate, the mapping is wrong — re-derive it, do not
nudge it. Auto-detecting status-bar landmarks is a trap: a bbox over the top
strip swallows clock, wifi and battery together and yields a nonsense x scale.
Two clicks with observable effects beat any amount of landmark algebra.

**The composer sits higher than it looks.** The card's content ends at pt ~803,
not at the bottom of the screen: text field at pt y ~763 (screen ~900), the
`+`/model-chip/send row at pt y ~783 (screen ~922). Tapping where the placeholder
appears to be lands on the model chip instead, which is how a session can end up
opening "Select model" repeatedly while believing it is tapping the text field.
Measure the card from pixels rather than eyeballing it:

    python3 - <<'PY'   # brightness per row; the card is the bright band
    ...scan the bottom 400 px-rows of the screenshot...

## Dismissing sheets

`osascript -e 'tell application "Simulator" to activate'` then
`osascript -e 'tell application "System Events" to key code 53'` (Escape) closes
a sheet. Tapping the X in a sheet is unreliable, and a sheet left open silently
swallows every later tap — which makes subsequent taps look like they are hitting
the wrong control when they are not reaching the screen at all. Always Escape and
screenshot to confirm the screen is clear before the next tap.

## Clicks need a move first

`cliclick c:x,y` on its own frequently does nothing: the pointer is elsewhere, and
the Simulator appears to need the cursor over the control before the click
registers. Do it in two steps:

    cliclick m:x,y && sleep 0.5 && cliclick c:x,y

This cost a long detour — a Notes row appeared not to navigate, and the
NavigationLink was rewritten before it turned out the click was simply never
landing. Chat rows worked because the pointer happened to be near them.

## Measure the row you are aiming at, every time

Large-title screens shift their content down between builds, so a row that was at
pt y 114 in one screenshot is at pt y 178 in the next. Find the row from pixels
before tapping:

    python3 - <<'PY'   # bright text rows, with the screen y already converted
    for pt_y in range(150, 260, 4):
        hits = [x for x in range(60, 900, 4) if min(px[x, pt_y*3]) > 200]
        if len(hits) > 3: print(pt_y, round(166.9 + 0.9941*pt_y), len(hits))

## Reading the app's own authenticated traffic

`TIAI_DEBUG_DUMP=/path` (DEBUG builds only) writes every response body to that
directory. In the simulator:

    C=$(xcrun simctl get_app_container <udid> co.wobker.tiai data)
    SIMCTL_CHILD_TIAI_DEBUG_DUMP=$C/tmp-dump xcrun simctl launch --terminate-running-process <udid> co.wobker.tiai

The container path changes when the app is reinstalled, so recompute it after
`simctl install` rather than reusing a value from earlier in a session. This is
how the notes timestamp unit and the citation shape were settled — by reading what
the server actually sent, through the app's own session, instead of guessing or
asking for a token.

## Driving a press-and-hold

`cliclick c:` is a quick tap and cannot express "held for two seconds". For a
hold, and for anything whose behaviour depends on press duration:

    cliclick dd:1206,942 && sleep 2.0 && cliclick du:1206,942

Verify by pixel, not by hope: count red pixels in the control's band before and
after the release, and treat "still red" as a failed release. This is how the
dictation release was proven broken and then proven fixed.

A gesture must not live on a view that changes while the gesture is in flight.
Swapping a 34pt circle for a wider capsule when recording began made SwiftUI
tear the view down mid-press and cancel the drag with it, so `onEnded` never
fired. The control now keeps one frame and one view tree in every state and
differs only in opacity and fill; the elapsed timer lives outside it.
