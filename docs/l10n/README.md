# Dimmerly localization

Use the locale guide when editing the app, widget or Info.plist string catalog. Keep the guides current when you settle a terminology or address choice. Preserve Dimmerly, Apple product names, DDC/CI, I2C, VCP, input identifiers such as HDMI and DisplayPort, paths such as `/usr/bin/pmset`, placeholders and shortcut glyphs. Use the catalog's plural variants and locale-aware formatters. Review translations against the interface and the meaning of the English source. When the source changes, update the corresponding translations or mark them for review.

- [German](de.md), [Spanish](es.md), [French](fr.md), [Italian](it.md)
- [Japanese](ja.md), [Korean](ko.md), [Simplified Chinese](zh-Hans.md)
- [Dutch](nl.md), [Brazilian Portuguese](pt-BR.md), [Serbian Latin](sr-Latn.md), [Russian](ru.md)

## Preset names

Localize the built-in **Full**, **Evening** and **Night** names. The app catalog already supplies these names in every supported language. Dimmerly uses the active language when it first seeds presets or restores the defaults. Existing presets store editable names, so switching languages preserves those names, including ones a user customized.

The English screenshot and demo fixtures specify their own preset names. When preparing a localized capture, stage the names from the target catalog and verify the preset names in both the panel and Schedule settings.

## Catalog audit

Run `just l10n-check` from the repository root. The same check runs in `just check` and CI. To run it directly with Python 3.10 or newer, use the [repository copy](../../scripts/l10n/check_catalog.py).

```sh
python3 scripts/l10n/check_catalog.py \
  --rules docs/l10n/checker-rules.json \
  Dimmerly/Resources/{InfoPlist,Localizable}.xcstrings \
  DimmerlyWidget/Resources/Localizable.xcstrings
```

The [rules](checker-rules.json) flag common off-register forms in each locale. Review imperatives and ambiguous pronouns in context as part of each audit. The checker ignores source matches and possible-English flags for `NSHumanReadableCopyright` because the shared English copyright wording is intentional. It still checks placeholders, markup and register for that key.

The rules record existing app catalog findings under `_catalog_exceptions`, scoped to the catalog path, finding, locale and key. Source matches cover shared formatting, accepted loanwords, input labels and French timer plurals. Possible-English findings include technical terms such as DDC/CI, GitHub and `pmset`. Length exceptions cover individual translations reviewed in context. Xcode's stale entries are retained translations of source keys flagged by extraction. Review those keys separately before removing them. When editing an excepted entry, review the exception and remove it if it no longer applies.

The address audit included stale entries. The former display control and DDC/CI help text and the former IOKit recovery message have no live call sites for a rendered check. If those keys return, verify wrapping in Settings and in the recovery message for the active locale.

Before release, review the changed prompts and labels in the built app, including the location dialog, shortcut editing, input switching and wake controls. Check the widget error and location permission prompt where the locale changed. Use the locale guides to check text width, line breaks and regional glyphs.
