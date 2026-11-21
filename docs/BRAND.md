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
| Accent gradient | `#EC4899` → `#E12AFB` → `#8E51FF` | same | For small fills only: a ticked checkbox, active states. |
| Deep indigo | `#4338CA` | `#6D63F0` | Gradient end and secondary accent. |
| Muted marker | `secondaryLabel` | `secondaryLabel` | Unticked boxes and bullets at rest, so the text stays the focus. |

`Assets.xcassets/AccentColor` is still the system default (blue). Setting it to the accent above is a separate decision, because it recolours every system control.

## Shapes

- **Pixel square:** a rounded square whose corner radius is about 28% of its side, the same shape as the pixels in the icon. It is Swash's base shape for small markers.
- **Swash stroke:** a calligraphic stroke that is thin on one side and thick on the other, with tapered ends. Use it for ticks and flourishes, not for outlines.
- **Speckles:** tiny round dots or pixel squares. Decoration for art and empty states only, never for inline text markers.

## Inline Markdown markers

These rules cover what the editors draw for list syntax (`StyledLayoutManager` on iOS; the Mac editor should match):

- **Size scales with the body font.** Never use a fixed point size. Take the size from the line's font: about 0.9× the cap height for checkboxes and 0.35× the x-height for bullets.
- **Centre markers on the first line's x-height** (or on the cap height for checkboxes), not on the line fragment. Otherwise they sit low next to large fonts or wrapped lines.
- **Task checkbox, unticked:** a pixel-square outline, 1.5 pt stroke, in `secondaryLabel`.
- **Task checkbox, ticked:** a pixel square filled with the accent gradient and a white swash-stroke tick. Strike through or dim the item's text as the editor does today.
- **Bullet, level 1:** a filled pixel square in the accent colour, at 0.8 opacity.
- **Bullet, level 2:** a pixel-square outline.
- **Bullet, level 3 and deeper:** a small filled circle in `secondaryLabel`.
- **Numbered lists:** keep the text numerals, in the body font's monospaced digits, coloured `secondaryLabel`.
- **Tap targets:** at least 44×44 pt for checkboxes on iOS, even though the drawn box is smaller.
- **Respect Focus mode:** markers fade with their paragraph's `focusAlpha`.
- **Accessibility:** markers must meet 3:1 contrast against the editor background in both appearances and with Increase Contrast. Under Increase Contrast, use `label` instead of `secondaryLabel`.

## Voice

Swash is calm, bookish and precise. Interface text is short and plain. Errors say what happened and what to do next, never just "couldn't complete the request".
