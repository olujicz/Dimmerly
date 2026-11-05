# Demo storyboard

`storyboard.json` scripts the 15-second demo loop. A debug build plays it in the
staged screenshot mode: isolated settings, made-up displays, no gamma or DDC
writes, and no launch setup. Release builds don't contain the demo mode.

Run it by hand from a Debug or Debug-AppStore build:

```sh
DIMMERLY_SCREENSHOT=demo \
DIMMERLY_DEMO_STORYBOARD="$PWD/scripts/demo/storyboard.json" \
DIMMERLY_DEMO_OUTPUT=/tmp/values.jsonl \
  .build/Build/Products/Debug/Dimmerly.app/Contents/MacOS/Dimmerly
```

The app opens the real panel during the lead-in and keeps it open, so the
recorder has its full-size window from the start; `openPanel` and `closePanel`
only set `panelOpen`, which the compositor uses to fade the panel in and out.
The app plays the steps in real time, writes one JSON
line per frame to `DIMMERLY_DEMO_OUTPUT`, and quits. The first line is a header
with `fps`, `frames` and `startedAt` (Unix time of frame 0). Each later line
holds `frame`, `panelOpen`, `caption` and every display's `brightness`, `warmth`
and `contrast`.

## Format

- `fps`: frames per second, 1–120.
- `leadIn`: seconds to wait before frame 0, so a recorder can start.
- `displays`: `name`, `brightness`, and optionally `builtIn`, `warmth`,
  `contrast` and `expanded` (opens the row's warmth and contrast sliders).
- `presets`: `name`, `brightness`, and optionally `warmth`.
- `steps`, played in order. Each has an `action`, an optional `duration` in
  seconds and an optional `caption` (shown from that step on; `""` clears it):
  - `wait`, `openPanel`, `closePanel`
  - `setBrightness` / `setWarmth`: `value`, optional `display` (all displays
    if omitted) and `easing` (`easeInOut`, the default, or `linear`). The value
    animates across the step's duration.
  - `applyPreset`: `preset` by name. The row shows its checkmark, as after a click.
  - `setAutoWarmth`: `enabled`, true or false. Needs `location`.
- Optional staging, used by the App Store stills (see below): `timeZone`, `now`
  (ISO 8601 with an offset) and `location` (`latitude`, `longitude`).

Brightness values must be between 0.1 (the app's minimum) and 1. The loop has to
end where it starts, with the panel closed and the starting values; a unit test
checks this. An invalid storyboard stops the app with the reason.

## Cursor track

The optional top-level `cursor` and `cursorSliders` keys are read only by the
compositor; the app ignores them. Positions are panel points with the origin at
the top-left of the panel capture (capture pixels / 2), and `y` can be negative.
The region captures put the arrow tip at about (163, 2.5), so the menu-bar icon is
at about (163, −12.5).

There are two kinds of key:

- A point key, `{"time": s, "x": pt, "y": pt}`. Add `"click": true` for a click,
  which shows a short press (the arrow scales to 0.92 for about 80 ms) and a
  small 300 ms ring.
- A drag key, `{"time": s, "until": s, "slider": "name"}`. From `time` to
  `until`, the hotspot stays on that slider's thumb.
  - The thumb's x comes from each frame's logged value in `values.jsonl`, so the
    cursor can't drift off it.
  - The slider is defined in `cursorSliders` as `display`, `value` (`brightness`,
    `warmth` or `contrast`) and row `y`. Its thumb centre is at `minX` for value
    `min` and at `maxX` for value `max`.
  - The values were measured from the dark region captures, whose white thumbs
    stand out from the glass. Light and dark share the layout.
    - External brightness is on row 104.75 and warmth on row 123.25.
    - Both tracks run from 59.75 to 265.25 pt: brightness maps 0.1–1 and warmth
      maps 0–1.

The cursor holds before the first key, after the last one, and on each key.
Between keys it moves on smoothstep timing (`t*t*(3-2t)`, the app's `easeInOut`)
along a slight upward arc. Keys must not overlap in time.

## Compositor

`ComposeDemo.swift` turns a recorded run into the master movie. It draws an
illustrated MacBook (the built-in display) and an external monitor. Both show the same
landscape wallpaper. Each frame, it applies that
display's logged brightness, warmth and contrast through
`GammaMath.channelMultipliers(for:)` and
`GammaMath.buildTable(brightness:channelMultiplier:contrast:)`, which is the same
per-channel transfer the app sends to a real display. It adds a full-width 24 pt
menu bar at the top with the real panel capture hanging from the Dimmerly icon at
native 2x scale, then the cursor and the captions. The wallpaper (seeded
midpoint-displacement ridgelines under a soft sun haze) is generated in code, so
nothing needs licensing. The tool builds together with the app's gamma math,
which stays unchanged:

```sh
mkdir -p .build/demo-tools
xcrun swiftc -O -parse-as-library scripts/demo/ComposeDemo.swift \
  Dimmerly/Services/GammaMath.swift -o .build/demo-tools/ComposeDemo \
  -framework AppKit -framework CoreGraphics -framework AVFoundation -framework CoreText

.build/demo-tools/ComposeDemo --appearance dark \
  --values .build/demo/dark/values.jsonl --panel-dir .build/demo/dark/panel \
  --storyboard scripts/demo/storyboard.json \
  --output .build/demo/dark/master.mov   # or: --frame 90 --png /tmp/f.png, or: --check
```

- `--appearance light|dark` is required. It picks the look to match the website's
  colour scheme. Use values and panel captures from an app run in the same
  appearance.
  - `dark`: a deep charcoal-blue backdrop for the `#151613` page, a dark
    translucent menu bar with white items, and white captions.
  - `light`: a warm off-white backdrop for the `#f3f1ec` page, a light
    translucent menu bar with near-black items and a dark icon highlight,
    `#1d1d1f` captions without a shadow, softer device shadows, and a hairline
    so the aluminium edges read on the light backdrop.
  - The devices, screens and wallpaper are identical in both, and `--check`
    applies to each.
- `--background` is no longer used, because the backdrop is drawn for the
  appearance. It's still accepted, with a note.

- `--output` writes ProRes 422 HQ, 2560x1600, at the fps in the values header,
  tagged BT.709.
- `--frame N --png PATH` renders one frame for review.
- `--check` passes only if frame 0 and the last frame differ by less than 1% mean
  pixel difference. It also checks three frames where the displays are furthest
  from neutral: their screen pixels must match GammaMath applied to the
  wallpaper within 1 per channel. It samples a grid inside each screen, away from
  the notch and from where the MacBook covers the monitor. It exits 1 on failure.

Inputs:

- `values.jsonl` comes from the app run (see above). Every frame needs one
  `builtIn` display and one external display.
- The panel directory holds `NNNN.png` captures with alpha, named by
  zero-padded frame index.
  - Missing frames are fine. While the panel is open, a missing frame reuses
    the nearest earlier capture from the same open run, or the run's first
    capture if none comes earlier.
  - Each capture is placed by its own arrow tip: the centre of its first row
    with opaque pixels. That way a capture that changes size stays hung from
    the icon.
  - Cursor points are measured from the first capture in the directory.
- The panel fades in and out over 150 ms, scaling slightly from the arrow tip,
  because captures don't include the popover's own animation. The fade-out uses
  the last open frame's capture.
- Captions fade out over 150 ms. The next caption then fades in over 320 ms,
  rising 10 px. This includes the wrap from the last frame back to frame 0, so
  with the current storyboard frame 0 (the poster) has no caption yet.
- Grain: about ±1.6 levels of static, per-pixel grain is baked into the backdrop,
  stand and menu-bar layer, and about ±1.2 levels into the wallpaper itself.
  Both survive H.264 without banding.
  - The grain is identical in every frame.
  - The screens are drawn over the grained layer, so the GammaMath check
    compares against the dithered wallpaper and still matches exactly.
- The vignette darkens only the backdrop, never device, screen or panel pixels.

## App Store screenshots

`images/app-store/` holds the complete Mac App Store screenshot set. Upload
them in file-name order:

1. `01-dim-and-warm-every-display.png`
2. `02-each-screen-on-its-own.png`
3. `03-warmer-in-the-evening.png`: Auto Warmth on, in a staged evening
4. `04-presets-for-your-whole-desk.png`: Evening just applied, with its checkmark
5. `05-presets-on-a-schedule.png`: the Schedule tab of Settings

They are 2560x1600 and opaque, an accepted Mac App Store size. Don't add other
images to that folder; it should match the listing exactly.

`app-store-stills.json` scripts them: a storyboard of its own, plus a `stills`
list (file, appearance, frame, menu-bar clock) and a `windowStills` list
(file, appearance, Settings tab, caption, clock). Each still's frame shows its
own caption, which a unit test checks.

```sh
DEMO_VARIANT=app-store scripts/demo.sh build
DEMO_VARIANT=app-store scripts/demo.sh stills-capture   # light and dark, then Settings
DEMO_VARIANT=app-store scripts/demo.sh stills           # writes images/app-store
```

- The App Store build makes the panel match what App Review sees ("Dim
  Displays", no hardware controls). It keeps the `APPSTORE` code but signs with
  the non-sandbox entitlements, because the sandbox can't read the storyboard or
  write the frame log in the repo.
- `stills-capture` needs the same unlocked Mac and Screen Recording approval as
  `capture`. It records into `.build/demo-app-store/stills-<appearance>` and
  `stills-settings-<tab>-<appearance>`. Don't run `export` with the App Store
  variant: that writes the website's `images/demo` files.
- `stills` renders with `ComposeDemo --still`: the caption at the top and
  larger, the menu bar and panel zoomed 1.25x, the devices smaller, no cursor.
  Window stills use `--window` with a region capture and its mask. It checks
  every image is 2560x1600 with no alpha channel.

### Staged time and place

Staged runs launch with `TZ` set to the storyboard's `timeZone` (default
`America/Los_Angeles`) and `-AppleLocale en_US`, so times read as in the en-US
listing, such as 5:20 PM. The app can't change its own time zone and refuses to
stage in any other. The stills storyboard also sets:

- `location`: San Francisco, for sunrise and sunset. Unset, the stage uses the
  same place.
- `now`: 2026-11-03 at 5:20 PM Pacific, about ten minutes after that day's
  sunset, so Auto Warmth is late in its transition (about 3600K). Auto Warmth
  reads this instead of the clock; the menu-bar clock in the still says the same.

A `setAutoWarmth` step (`"enabled": true` or `false`) flips the panel's switch,
and needs `location`. Every `applyPreset` step shows the row's checkmark, as a
click does.

## App Store preview

`app-store-preview.json` scripts the listing's app preview: about 16 seconds of
the real panel (dragging brightness and warmth, applying Evening and Full,
turning Auto Warmth on), then the Schedule tab capture from `stills-capture`
holding for `preview.settingsSeconds` under its own caption.

```sh
DEMO_VARIANT=app-store scripts/demo.sh stills-capture    # once, for the Schedule tab capture
DEMO_VARIANT=app-store scripts/demo.sh preview-capture
DEMO_VARIANT=app-store scripts/demo.sh preview
```

- Guideline 2.3.4 allows only screen captures of the app itself, with text or
  video overlays. So the preview has no illustrated displays or menu bar: only
  the recorded panel and Settings window, captions and the cursor. Dimming is a
  gamma change, which screen recordings don't show, so it can't be filmed.
- `preview` renders a 1920x1080 ProRes master with `ComposeDemo --preview`,
  then encodes `.build/demo-app-store/preview/Dimmerly-App-Store-Preview.mp4`:
  H.264 High 4.0 at 30 fps with a silent stereo AAC track. Mac previews must be
  1920x1080 and 15-30 seconds long; the compositor refuses any other length.
- The file is about 6 MB and isn't committed. Upload it to the listing's Mac
  preview set and set its poster frame (14.5 s shows Auto Warmth). Because it
  is 16:9 and the screenshots are 16:10, the App Store shows it in "A Closer
  Look", not before the screenshots.
- The recorder captures 60 points below the panel, so the panel can grow while
  it's open (Auto Warmth adds a status line) without restarting the stream. A
  restart would leave a gap with no frames, which shows as a freeze.

