# Swash Brand

> Draft for review. Collected from the app icon ([APP_ICON.md](APP_ICON.md), `brand/swash-avatar-1024.png`) and the Swash sticker set's style guide (`Pixerate/stickers`, `docs/sets/swash.md`). A person needs to approve it before it counts as settled.

This page is the reference for drawing Swash's own UI elements: list bullets, task checkboxes, callout icons, empty states, and anything else Swash draws itself instead of using a system control. System controls (toolbars, sheets, menus, Settings) stay standard iOS and macOS and follow the HIG.

## Identity in one line

A calligraphic serif **S** with a looping **swash** flourish that breaks up into small **rounded-square pixels**. The swash stands for writing and the pixels stand for Pixerate.

## Two moods

| Where | Look |
| --- | --- |
| App icon, avatar, marketing | Neon: glossy pink → fuchsia → violet → indigo glow on a dark obsidian-violet background. |
| Stickers (`art/swash/`) | Ink and parchment: midnight-plum lines and burnished gold on cream by day, gold on slate by night. Calligraphic swash tails and ink speckles. |

Use the neon palette for UI chrome, and keep ink and parchment for sticker art. The sticker guide's section "Relationship to the Swash brand" says what the two share: the swash stroke, the pixel square (stickers may use it as a speckle), and tintable flourishes taking the Swash accent inside the app.

## Palette for UI elements

| Role | Light | Dark | Notes |
| --- | --- | --- | --- |
| Accent (primary fuchsia) | `#C800DE` | `#EE6BFF` | Use the darker value on light backgrounds so it has enough contrast; it is Pixerate's `--primary`. |
| Accent gradient | `#EC4899` → `#E12AFB` → `#8E51FF` | same | For small fills only, such as active states (not list markers, which are native). |
| Deep indigo | `#4338CA` | `#6D63F0` | Gradient end and secondary accent. |
| Muted marker | `secondaryLabel` | `secondaryLabel` | Unticked boxes and bullets at rest, so the text stays the focus. |

`Assets.xcassets/AccentColor` is still the system default (blue). Setting it to the accent above is a separate decision, because it recolours every system control.

## Shapes

- **Pixel square:** a rounded square whose corner radius is about 28% of its side, the same shape as the pixels in the icon. It is Swash's base shape for small decoration (not list markers, which are native SF Symbols).
- **Swash stroke:** a calligraphic stroke that is thin on one side and thick on the other, with tapered ends. Use it for flourishes, not for outlines or list ticks.
- **Speckles:** tiny round dots or pixel squares. Decoration for art and empty states only, never for inline text markers.

## Inline Markdown markers

List markers in the editors look native, not on-brand: they're SF Symbols, like Reminders and the system's lists. Both editors draw them the same way (`StyledLayoutManager` on iOS, `SwashLayoutManager` on the Mac; the shared choices are `ListMarkerStyle` in `EditorSupport.swift`):

- **Task, unticked:** `circle`, a Reminders-style circle, in `secondaryLabel`.
- **Task, ticked:** `checkmark.circle.fill` in the theme accent. Dim the item's text as the editor does today.
- **Bullet, level 1:** `circle.fill`. **Level 2:** `circle`. **Level 3 and deeper:** `square.fill`. All small (the symbol's small scale, at about 0.42× the line's font size, bold so the ring holds up) and in `secondaryLabel`, centred in the checkbox column.
- **Numbered lists:** keep the text numerals, in the system font's monospaced digits, coloured `secondaryLabel`.
- **Size comes from the line's font.** Never use a fixed point size: the symbol configuration takes its point size from the item's font, so markers follow Dynamic Type, the Typography setting and headings. A checkbox is as tall as the text (medium scale, regular weight).
- **Centre markers on the first line:** on the item text's cap height, not on the line fragment, so they don't sit low next to large fonts or wrapped lines. An empty item (`- ` or `- [ ] `, often the last line) has no text to measure, so the body font is centred in its line instead.
- **Accessibility:** markers must meet 3:1 contrast against the editor background in both appearances (they're adjusted when a theme's colours fall short). Under Increase Contrast, use `label` instead of `secondaryLabel`.
- **Respect Focus mode:** markers fade with their paragraph.
- **Tap targets:** on iOS a checkbox's tap target is at least 44×44 pt, centred on the drawn circle; on the Mac a click on the circle or just around it toggles the task.

## Voice

Swash is calm, bookish and precise. Interface text is short and plain. Errors say what happened and what to do next, never just "couldn't complete the request".
