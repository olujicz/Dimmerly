# Refresh screenshots

The capture helper saves actual Dimmerly windows. The compositor reuses the
checked-in background, preserves native window resolution, and can generate
either the App Store composition or the two GitHub/README images.

The App Store listing doesn't use this composition. Its screenshots are the
demo stills in `images/app-store/`; see
[App Store screenshots](../demo/README.md#app-store-screenshots). The App Store
variant here writes to `.build/` so it never replaces those files.

Requires macOS 15.2 or later, Xcode command-line tools, and an Apple Development
signing identity for the capture helper. Composition needs no signing or Screen
Recording permission.

## Launch screenshots with the real menu bar

```sh
just screenshots-launch
just screenshots-launch --skip-build
just screenshots-launch --appearance dark --output /tmp/dimmerly-launch
```

This builds the direct-download debug edition and captures three scenes in light
and dark appearances: expanded external display controls, the applied warm Evening
preset, and Schedule settings. The six native-resolution PNGs are saved to
`docs/launch/assets/menubar-{1,2,3}-{light,dark}.png`. A full run also selects
light controls, dark Evening, and light Schedule as `menubar-1.png` through
`menubar-3.png`, ready for directory submissions. Raw captures stay in
`.build/screenshots/launch/`. `--output` changes the destination; a single
appearance run only updates its three appearance-specific files.

These are actual screen regions including the real macOS menu bar, without
composition or promotional text. A temporary plain backdrop covers other desktop
windows inside the capture. The system menu bar remains real: inspect it for
personal icons or status information before sharing. Leave the Mac idle while
the six scenes are captured. Do not run the demo or other screenshot commands
at the same time: they share the staging defaults suite and helper.

The command reuses the helper's Screen Recording approval, needs an unlocked
Mac with an awake display, and stops early with instructions when either is
missing. After building, it remembers and gracefully quits existing Dimmerly
instances so there is only one icon during capture. It reopens the exact original
app paths on success, failure or interruption. It never force-quits an existing
app. A recovery manifest under `.build/screenshots/launch/running-apps.json`
survives a terminal crash; the next launch capture restores it before starting.
Locks record the capture's PID; a later invocation recovers a lock only when its
owner has exited. Staged builds left behind by a crash are closed without being
saved for relaunch. Restoration waits for original processes to finish quitting,
keeps recovery data on a shutdown timeout, and reports missing original app paths
instead of blocking every later capture. Ctrl-C during the close step is deferred
until that step finishes, then cleanup restores the original app before exiting.
It never changes the system appearance or wallpaper and uses no-op display
control with isolated settings. Quitting the original app can temporarily clear
its live dimming or warmth until it reopens. Staged processes and temporary
backdrops are closed on completion or interruption. The crop includes the screen's
right edge so the clock is kept whole. An app window
that cannot fit on one display fails instead of silently being cropped.

The launch scenes are debug-only (`DIMMERLY_SCREENSHOT=launch-menu`,
`launch-evening`, `launch-schedule`). Their fixtures live beside the existing
`ScreenshotStage` fixtures. Schedule uses the same staged location and schedules
as the existing capture path. The plain warm backdrop in the Evening image is
a desktop colour, not a measurement of display colour temperature: actual gamma
changes do not appear in screenshots, and staging never changes display gamma.

Check crop geometry without screen access:

```sh
xcrun swiftc scripts/screenshots/CaptureLayout.swift scripts/screenshots/CaptureLayoutTests.swift -o /tmp/dimmerly-layout-tests
/tmp/dimmerly-layout-tests
bash scripts/screenshots/test-launch.sh
xcrun swiftc -swift-version 6 -parse-as-library scripts/screenshots/RunningApplications.swift scripts/screenshots/RunningApplicationsTests.swift -o /tmp/dimmerly-running-app-tests
/tmp/dimmerly-running-app-tests
```

## One command

```sh
just screenshots          # .build/screenshots/app-store/menu-and-displays.png
just screenshots-github   # images/image1.png and images/image2.png
```

Both run `scripts/screenshots.sh refresh`. It builds the debug app for the
variant (`Dimmerly App Store` / `Debug-AppStore`, or `Dimmerly` / `Debug`) into
`.build/screenshots/DerivedData`. It launches the app twice in its staged
screenshot mode, captures the menu panel and then the Displays settings, quits
the app, composes the image, and checks the App Store image's size and opacity.
Raw captures stay in `.build/screenshots/<variant>/`.

Options: `--output PATH` writes somewhere else (use it to try changes without
replacing the committed image), and `--skip-build` reuses the last build.

The Mac must be unlocked with a display awake: macOS can't take screenshots
otherwise, and the command stops with that message. The first run asks for
Screen Recording permission for `DimmerlyScreenshotHelper`. Approve it in System
Settings > Privacy & Security > Screen & System Audio Recording, then run the
command again. The approval survives helper rebuilds while the signing identity
name stays the same.

### Staged screenshot mode

Debug builds launched with `DIMMERLY_SCREENSHOT=menu` or `settings` use
`ScreenshotStage` (end of `Dimmerly/App/DimmerlyApp.swift`) instead of the
user's state:

- Settings, presets, location and display values live in a throwaway
  `rs.in.olujic.dimmerly.screenshots` defaults suite, cleared on each launch.
- The brightness manager is the testing instance, so gamma tables, display
  enumeration and hardware control are never touched.
- Launch setup doesn't run: no shortcuts, schedules, widget synchronization,
  widget requests, Spotlight indexing or Control Center state.
- The staged content is one generic "External Display" at 75% and the Full,
  Evening and Night presets on Control–Option–1 to 3. Edit the values in
  `ScreenshotStage` to change it.
- On the direct-download Displays tab, that display answers DDC/CI from memory
  (`ScreenshotStage.StagedDDCInterface`) like a typical monitor, so Hardware
  Control lists brightness, contrast, volume and input. No DDC traffic reaches
  a real monitor; every other scene finds none.

The direct-download Displays pane is taller than a 1080-point screen. When the
region capture comes back cut off at the screen's edge, `refresh` uses the full
window capture instead and says so; check its title bar for a screen-sharing
badge. The website shows both appearances: `images/image2.png` (dark, also in
the README) and `images/image2-light.png`, taken with `--appearance dark` and
`--appearance light`.

Release builds don't contain the stage. Your own running Dimmerly can stay open.
The capture selects the staged process by its PID.

## Capture windows by hand

Use this only when you need a window state the staged mode doesn't produce.
Build the helper without launching it:

```sh
scripts/screenshots.sh build-helper
```

The valid Apple Development identity is used. If identities for more than one person or
team are installed, the script stops rather than guess, because the Screen Recording
approval belongs to one of them. Set `SIGNING_IDENTITY` to a certificate fingerprint from
`security find-identity -v -p codesigning` to choose.

Open the correct Dimmerly build yourself, then find its process ID:

```sh
ps -axo pid=,command= | rg '/Dimmerly.app/Contents/MacOS/Dimmerly'
```

For **App Store** screenshots, use the `Dimmerly App Store` scheme with
`Debug-AppStore`. For **GitHub** screenshots, use the direct-download `Dimmerly`
scheme with `Debug`. Verify the full process path when choosing the PID. Never
use direct-download hardware controls in App Store screenshots.

A normal launch of Dimmerly can change live gamma/brightness and write the real
preset store. Prefer launching a debug build with `DIMMERLY_SCREENSHOT` set, which
uses the staged mode described above.

Show the menu, capture it, then open Displays settings and capture that window:

```sh
scripts/screenshots.sh capture --pid 12345 --mode menu \
  --output .build/screenshots/app-store/menu.png

scripts/screenshots.sh capture --pid 12345 --mode settings-region \
  --output .build/screenshots/app-store/settings.png

scripts/screenshots.sh capture --pid 12345 --mode settings \
  --output .build/screenshots/app-store/settings-mask.png
```

Replace `12345` with the selected PID. For direct-download captures, use a
separate `.build/screenshots/github/` directory. Screen Recording permission
may be requested for `DimmerlyScreenshotHelper`.

`settings-region` uses a one-shot screen-region capture to keep normal window
buttons instead of the purple sharing badge. Keep Settings unobscured, and
avoid window-sharing/UI-inspection tools until this capture is finished. The
subsequent `settings` capture supplies only the rounded alpha outline; its
visible pixels are not used when `--settings-mask` is supplied.

Keep the Settings size and position unchanged between those two captures.
The compositor requires matching pixel dimensions and a mask with alpha.
Settings panes have a fixed width and size their height to the content, so
don't resize the window; the direct-download Displays tab is taller because of
its hardware controls. Don't crop away empty areas afterwards. Inspect the raw captures before composing;
never paint out or fabricate UI.

Before capturing the menu, check that the entire **+ Save Current** row is
visible above **Dim Displays**. Use explicit two-modifier preset shortcuts
(for example Control–Option–1 through 3) instead of Command-number combinations.
Stage presets and display values in an isolated capture-only settings suite,
with widget synchronization and hardware writes disabled. Do not overwrite the
maintainer's real preset store merely to prepare a marketing image.

## Generate the App Store image

```sh
scripts/screenshots.sh compose --variant app-store \
  --menu .build/screenshots/app-store/menu.png \
  --settings .build/screenshots/app-store/settings.png \
  --settings-mask .build/screenshots/app-store/settings-mask.png \
  --output .build/screenshots/app-store/menu-and-displays.png
```

The default is a 2880×1800 opaque PNG on the muted blue-gray background in
`background.png`. The windows are centered together and remain at native
resolution. `--background FILE` selects another backdrop; `--width N --height N`
selects another accepted Mac App Store size. Oversized captures produce an
error instead of being clipped or scaled.

## Generate the GitHub images

```sh
scripts/screenshots.sh compose --variant github \
  --menu .build/screenshots/github/menu.png \
  --settings .build/screenshots/github/settings.png \
  --settings-mask .build/screenshots/github/settings-mask.png \
  --output images
```

This writes native-resolution `images/image1.png` and `images/image2.png`, with
window transparency preserved. The original website/README paths stay the same.
The command intentionally replaces those images; use a temporary output
directory first when reviewing new captures.

## Verify

```sh
sips -g pixelWidth -g pixelHeight -g hasAlpha .build/screenshots/app-store/menu-and-displays.png
git diff --check
git diff --stat
```

App Store output must be 16:10 at 1280×800, 1440×900, 2560×1600 or 2880×1800,
with `hasAlpha: no`. Inspect the final image for correct features, readable
content, normal window controls, and no occlusions. Raw captures and the helper
bundle belong in ignored local directories, not in commits.
