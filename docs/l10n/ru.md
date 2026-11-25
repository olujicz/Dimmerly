# Russian · ru

**Status: held back from 1.5.1.** The Russian translations are not shipped in that release, so `ru` is not in the project's `knownRegions` and the shipped catalogs carry no `ru` units. The translations from the original addition are kept in Git history (`git show 23fb4a3:Dimmerly/Resources/Localizable.xcstrings`, and the same path for `DimmerlyWidget/Resources/Localizable.xcstrings` and `Dimmerly/Resources/InfoPlist.xcstrings`). To ship Russian later, restore the `ru` units from there for strings that still exist, translate anything added since, add `ru` back to `knownRegions` and the changelog, and run `just l10n-check`.

Use neutral-formal **вы** in instructions, omit the pronoun where natural and use infinitives for action labels. This follows the existing location and wake prompts. Use Cyrillic, «…» and consistent **ё** where needed. Cover **one**, **few**, **many** and **other** in cardinal plurals.

Use **дисплей** for display and **монитор** for physical controls. Use **яркость** for brightness, **приглушение** for reversible dimming, **теплота** for the warmth control, **пресет** for a preset and **сочетание клавиш** for a shortcut. The accessibility label **Источник сигнала дисплея «%@»** spells out which input is changing. Check it with long display names using VoiceOver.

## Decisions

- Address: neutral-formal **вы**; the pronoun and possessive are omitted where natural.
- Buttons and menu items: infinitive (`Применить`, `Удалить`, `Повторить попытку`). Cancel is the noun `Отмена` (dismissal); `Отменить` is the Undo wording in macOS.
- Gender: no past-tense forms address the user.
- Typography: «…», **ё** where it distinguishes words, and the sentence-final stop follows the English source.
- Input labels such as HDMI 1, DisplayPort 1 and USB-C stay in Latin script.
