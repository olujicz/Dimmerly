# Refresh screenshots

The capture helper saves actual Dimmerly windows. The compositor reuses the
checked-in background, preserves native window resolution, and can generate
either the App Store composition or the two GitHub/README images.

Requires macOS 15.2 or later, Xcode command-line tools, and an Apple Development
signing identity for the capture helper. Composition needs no signing or Screen
Recording permission.

## Capture new windows

Build the helper without launching it:

```sh
scripts/screenshots.sh build-helper
```

If multiple signing identities exist, set `SIGNING_IDENTITY` to the certificate
fingerprint returned by `security find-identity -v -p codesigning`. Keep the same
identity so macOS can retain the helper's Screen Recording approval.

Open the correct Dimmerly build yourself, then find its process ID:

```sh
ps -axo pid=,command= | rg '/Dimmerly.app/Contents/MacOS/Dimmerly'
```

For **App Store** screenshots, use the `Dimmerly App Store` scheme with
`Debug-AppStore`. For **GitHub** screenshots, use the direct-download `Dimmerly`
scheme with `Debug`. Verify the full process path when choosing the PID. Never
use direct-download hardware controls in App Store screenshots.

Launching Dimmerly can change live gamma/brightness and write the real preset
store. These scripts do not build or launch Dimmerly. Ask the maintainer before
launching either the app or capture helper during automated work.

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
Resize Settings to about 580 points wide if the capture helper cannot identify
it. Inspect the raw captures before composing; never paint out or fabricate UI.

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
