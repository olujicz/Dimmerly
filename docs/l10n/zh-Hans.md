# Simplified Chinese · zh-Hans

Use concise instructions with omitted personal pronouns. **请** fits requests where helpful. This matches the common pattern in display and shortcut guidance and keeps the tone consistent in permissions, Settings and Shortcuts prompts.

Use Simplified Chinese characters, full-width punctuation, “…” and （…）. Use a space to separate standalone Latin names or keyboard tokens from adjacent Chinese text where needed for readability. Standalone short labels can omit the final full stop.

Use **显示器** for display, **亮度** for brightness, **调暗** for dimming, **色温** for color temperature, **预设** for a preset and **快捷键** for a shortcut. Color-temperature labels, duration units and **致谢** are naturally compact. Check the actual width and regional Han glyph forms under the Simplified Chinese app language.

## Decisions

- Address: pronoun omitted (`请…` for requests); neither `你` nor `您`.
- Buttons and menu items: verbs (`添加`, `删除`, `切换`).
- Gender: Chinese forms do not mark the user's gender.
- Typography (as one decision, enforced by `target_patterns` in `checker-rules.json`): full-width punctuation （）“”，。：; **one space** between Chinese and Latin letters or digits (`Dimmerly 无法`, `锁定 Mac`, `%d 分钟`); no space beside full-width marks; standalone labels omit the final full stop. Keyboard-token groups such as `（⌘,）` keep the half-width comma.
