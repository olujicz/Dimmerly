# German · de

Use informal singular **du** in instructions, with infinitives for compact actions. This follows the existing shortcut and location prompts. Write Latin script with German spelling and „…“ quotation marks. Allow long compounds to wrap naturally.

Use **Bildschirm** for a display in general UI, **Monitor** for physical hardware in DDC/CI guidance, **Helligkeit** for brightness, **Voreinstellung** for a preset and **Kurzbefehl** for a shortcut.

Keep German uses of **Name**, **Warm**, **Version** and the established loanwords **Auto**, **Hardware**, **Software** and **Updates**. **Composite** and **Tuner** are input labels. The checker also matches technical terms in translated DDC/CI and GitHub text.

## Decisions

- Address: informal **du**; messages that avoid the pronoun use the infinitive (`Bitte erneut versuchen`).
- Buttons and menu items: infinitive or noun (`Anwenden`, `Löschen`, `Umschalten`).
- Gender: no gendered forms address the user. Prefer neutral wording; do not use `*`, `_` or `:` inside words.
- Display terms: **Bildschirm** in action labels and descriptions (`Bildschirm dimmen`, `Bildschirm wiederherstellen`). **Display** stays in compounds, status text and error titles (`Displays werden angepasst`, `Displayeinstellung`), following macOS. Revisit both with a native speaker.
- Typography: „…“, no space before the ellipsis, long compounds may wrap.
