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

The app opens the panel by itself, plays the steps in real time, writes one JSON
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
  - `applyPreset`: `preset` by name.

Brightness values must be between 0.1 (the app's minimum) and 1. The loop has to
end where it starts, with the panel closed and the starting values; a unit test
checks this. An invalid storyboard stops the app with the reason.
