# Dimmerly app icon — Icon Composer layers

Edgeless, full-bleed source art for the current (v5 sun) icon, split into
layers for Icon Composer. Derived from `../app_icon_brightness_v5.svg`.

Everything here is square 1024×1024 with **no rounded-corner clip, no outer rim
stroke and no drop shadow**. Icon Composer owns the squircle mask, the edge
highlight, the shadow and the Clear / Tinted / Dark variants — baking any of
those into the source is what makes an icon look wrong in the new system.

## Files

Each layer exists as both `svg/` (preferred — vector, resolution independent)
and `png/` (1024×1024 fallback).

| Layer | Role | Alpha |
| --- | --- | --- |
| `1-background.svg` | Base gradient + aurora wash. The background-only icon. | opaque |
| `2-glow.svg` | Soft light bloom behind the sun. | transparent |
| `3a-rays-bright.svg` | The four lit rays: top, upper-left, left, upper-right. | transparent |
| `3b-rays-dim.svg` | The four dimmed rays, 30% shorter and thinner. Carries `opacity: 0.42`. | transparent |
| `4-disc.svg` | The sun disc, bright-to-dim gradient + inner rim. | transparent |
| `app-icon-fullbleed.svg` | Everything flattened. Reference/preview only. | opaque |

## Importing

1. Open Icon Composer and create a new icon, or open the existing document.
2. Drag `svg/1-background.svg` onto the **Background** slot.
3. Drag `svg/2-glow.svg`, `svg/3b-rays-dim.svg`, `svg/3a-rays-bright.svg` and
   `svg/4-disc.svg` in as foreground layers, bottom to top in that order.
   Set the dim ray layer's opacity to 0.3.
4. Set per-layer shadow, specular and blur to taste, then check the Clear,
   Tinted and Dark previews before exporting.

Keeping glow / rays / disc separate is what buys you real depth: Icon Composer
can shadow and specular-highlight each one independently, and the disc can sit
proudly above the rays.

The glow can live either at the bottom of the foreground stack or merged into
the background. In the foreground it picks up Icon Composer's layer effects; in
the background it survives as flat ambience and drops out of Tinted mode.

## Regenerating the PNGs

```sh
cd IconComposerLayers/AppIcon-IconComposer
for f in svg/*.svg; do
  rsvg-convert -w 1024 -h 1024 -f png -o "png/$(basename "$f" .svg).png" "$f"
done
```

## Note on layout

Artwork spans x/y 150…874, leaving ~15% margin on every side, so nothing is
clipped by the squircle mask. If you rescale the art, keep the key shapes
inside Icon Composer's safe-area grid.

## Why the rays are split

Icon Composer's specular pass re-lights every layer, which flattens per-stroke
`stroke-opacity`. The rays were authored to fade to 29% on the dimmed side; on
a single layer they compiled out at 96% — a plain sun, not a dimming one.

Splitting alone does not fix it (measured 95%). What works is a per-layer
`opacity` in `icon.json`, which is applied *after* the specular pass, combined
with making the dim rays shorter and thinner so the fade is geometric as well
as tonal. The shipped setting is 30% shorter at `opacity: 0.42`, landing at 51%.

A more aggressive setting (45% shorter, `opacity: 0.3`, ratio 41%) reads better
at 256pt but loses the dim rays entirely at 32pt, where the icon then looks
lopsided rather than dimmed. Check 32pt before pushing the dimming further.

Opacity alone bottoms out around 38% no matter how low you push it — the
specular pass contributes brightness that layer opacity cannot remove. Do not
try to fix this by disabling the group's `translucency`: that blows the rays
out to pure white and the ratio goes to 100%.

## Verifying a change

`.icon` documents compile with `actool`, which catches schema errors that a
flat SVG preview cannot:

```sh
actool AppIcon.icon --compile out --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist out/partial.plist --errors --warnings
```

Note `color-space-for-untagged-svg-colors` only accepts `display-p3`; every
sRGB spelling is rejected outright.

## How the app consumes this

`Dimmerly/Resources/AppIcon.icon` is a copy of `svg/default.icon`, referenced by
the Dimmerly target as `folder.iconcomposer.icon`. `ASSETCATALOG_COMPILER_APPICON_NAME`
and the `CFBundleIconName` / `CFBundleIconFile` keys all stay `AppIcon`.

`actool` emits both the layered rendition into `Assets.car` (macOS 26+, which
applies the mask, shadow and specular at runtime) and a flattened `AppIcon.icns`
fallback for older systems. The deployment target is macOS 15.0 and that is
fine — the fallback `.icns` carries the same rendition set (`ic13, ic11, ic04,
ic07`) the previous `AppIcon.appiconset` shipped.

After editing layers here, re-copy the document:

```sh
rm -rf Dimmerly/Resources/AppIcon.icon
cp -R IconComposerLayers/AppIcon-IconComposer/svg/default.icon Dimmerly/Resources/AppIcon.icon
```

## rendered/

Preview PNGs extracted from a local `actool` build, kept as a visual reference.
The compiled `AppIcon.icns` and `Assets.car` are deliberately not committed:
they are build outputs and the Xcode build regenerates them from
`Dimmerly/Resources/AppIcon.icon`.
