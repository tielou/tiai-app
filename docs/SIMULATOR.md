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
