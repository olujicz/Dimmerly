# Refresh screenshots

The capture helper saves actual Dimmerly windows. The compositor reuses the
checked-in background, preserves native window resolution, and can generate
either the App Store composition or the two GitHub/README images.

Requires macOS 15.2 or later, Xcode command-line tools, and an Apple Development
signing identity for the capture helper. Composition needs no signing or Screen
Recording permission.

## One command

```sh
just screenshots          # images/app-store/01-menu-and-displays.png
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

Release builds don't contain the stage. Your own running Dimmerly can stay open.
The capture selects the staged process by its PID.

## Capture windows by hand

Use this only when you need a window state the staged mode doesn't produce.
Build the helper without launching it:

```sh
scripts/screenshots.sh build-helper
```

The first valid Apple Development identity is used. To choose another, set `SIGNING_IDENTITY` to a certificate fingerprint from
`security find-identity -v -p codesigning`.

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
  --output images/app-store/01-menu-and-displays.png
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
sips -g pixelWidth -g pixelHeight -g hasAlpha images/app-store/01-menu-and-displays.png
git diff --check
git diff --stat
```

App Store output must be 16:10 at 1280×800, 1440×900, 2560×1600 or 2880×1800,
with `hasAlpha: no`. Inspect the final image for correct features, readable
content, normal window controls, and no occlusions. Raw captures and the helper
bundle belong in ignored local directories, not in commits.
