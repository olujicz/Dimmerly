# Japanese · ja

Use **です／ます** and **ください** in instructions, with the pronoun omitted and compact action labels. This follows the existing location and error prompts. Use kana and Japanese kanji, 「…」 and full-width Japanese punctuation. Keep Japanese prose unspaced, using local spacing around formatted values or technical tokens where needed.

Use **ディスプレイ** or **画面** for display, **輝度** for brightness, **プリセット** for a preset and **ショートカット** for a shortcut.

**自動色温度**, **色温度** and **謝辞** are concise on purpose. Character-count ratios understate their visual width. Check glyphs with the Japanese app language and look for clipping where labels meet values.

## Decisions

- Register: です／ます in sentences; no あなた; labels are noun phrases or short verbs (`追加`, `切り替える`).
- Buttons and menu items: noun or dictionary-form verb.
- Gender: Japanese forms do not mark the user's gender.
- Typography (as one decision, enforced by `target_patterns` in `checker-rules.json`): full-width brackets （）, colon ：, 、 and 。; digits and Latin letters stay half-width with **no space** between Japanese and Latin letters, digits or placeholders (`Dimmerlyが`, `%d分後`, `-90から90`). Units such as `ms` keep the space after the number. 「…」 for quotation marks. Katakana keeps the trailing long vowel.
- Open: the em dash with spaces in the DDC/CI help text could become a sentence break; left for native review.
