# Dimmerly localization

Use the locale guide when editing the app, widget or Info.plist string catalog. Keep the guides current when you settle a terminology or address choice. Preserve Dimmerly, Apple product names, DDC/CI, I2C, VCP, input identifiers such as HDMI and DisplayPort, paths such as `/usr/bin/pmset`, placeholders and shortcut glyphs. Use the catalog's plural variants and locale-aware formatters. Review translations against the interface and the meaning of the English source. When the source changes, update the corresponding translations or mark them for review.

- [German](de.md), [Spanish](es.md), [French](fr.md), [Italian](it.md)
- [Japanese](ja.md), [Korean](ko.md), [Simplified Chinese](zh-Hans.md)
- [Dutch](nl.md), [Brazilian Portuguese](pt-BR.md), [Serbian Latin](sr-Latn.md), [Russian](ru.md)

## Preset names

Localize the built-in **Full**, **Evening** and **Night** names. The app catalog already supplies these names in every supported language. Dimmerly uses the active language when it first seeds presets or restores the defaults. Existing presets store editable names, so switching languages preserves those names, including ones a user customized.

The English screenshot and demo fixtures specify their own preset names. When preparing a localized capture, stage the names from the target catalog and verify the preset names in both the panel and Schedule settings.

## Catalog audit

The translation-quality checker covers the three Xcode string catalogs. The remaining findings are summarized here and in the locale guides.

| Catalog | Findings |
| --- | --- |
| App | 98 source matches, 33 possible-English flags, 15 length flags and 38 Xcode stale source entries |
| Info.plist | 1 source match and 8 possible-English flags, all for the copyright notice |
| Widget | Clean |

The source matches are shared formatting such as `%@K · %@`, accepted loanwords, input labels, French timer plurals and one Dutch label attached to a stale source. Keep the format and technical literals. The possible-English findings are translations containing technical terms such as DDC/CI, GitHub, hardware and `pmset`, or the shared copyright notice. Xcode's stale entries are retained translations of source keys flagged by extraction. Review those keys separately before removing them.

Before release, review the changed prompts and labels in the built app, including the location dialog, shortcut editing, input switching and wake controls. Check the widget error and location permission prompt where the locale changed. Use the locale guides to check text width, line breaks and regional glyphs.
