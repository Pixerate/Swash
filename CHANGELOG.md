# swash

## 1.51.0

### Minor Changes

- d6d66fb: On iPhone and iPad, Edit Text now draws task checkboxes and list bullets as vector shapes that scale with Dynamic Type and line up with the item's text, in colours that keep at least 3:1 contrast with the page. An empty `- ` or `- [ ] ` item at the end of a document keeps its marker centred on its own line instead of drawing it over the line above, and the checkbox's tap target is worked out from the same geometry it's drawn with.

### Patch Changes

- 6991e00: macOS: Edit › Find is back. Find… (⌘F), Find and Replace… (⌥⌘F), Find Next (⌘G), Find Previous (⇧⌘G) and Use Selection for Find now open and drive the editor's find bar, which had no menu items to reach it.

## 1.50.0

### Minor Changes

- d5da86a: Show the active list type (`list.bullet`, `list.number`, `checklist`), heading level, and inline formats in the iOS keyboard bar, edit menu, and format panel as the caret moves.

### Patch Changes

- 9e98846: Fix NewDocumentSeed race condition by binding seeded text to the specific window and document identity instead of a global queue. Seeds hold their document and window weakly, so a seed left unclaimed (its window closed, or its document gone) is dropped instead of landing in an unrelated later window.
- f990b53: Improve Writing Partner terminal punctuation to inspect the final sentence on multi-sentence lines and disambiguate declarative "When"/"Where" subordinate clauses from questions. Commands after the comma, such as "When in doubt, do the simplest thing" or "Where possible, have the build run tests", now end with a full stop; "do", "don't" and "have" after the comma open a question only when a subject follows them ("When you get there, do you call me?").

## 1.49.1

### Patch Changes

- ed3f4dc: Add Xcode previews for every Swash Pro state in the account settings: free (paywall), Swash Pro, shared by family, included with Pixerate Pro, complimentary, direct download and signed in.

## 1.49.0

### Minor Changes

- 1204dd5: Add Pixie's chat to the Mac App Store version (View › Show Pixie, ⌥⌘I), and archive and upload a Mac App Store build in each release: ask her to draft, restructure or edit with you, and she works with the document's own agent tools, with her own caret and one undo step per edit. Part of Swash Pro. Chats aren't stored on Pixerate; the privacy page lists what she sends.

## 1.48.3

### Patch Changes

- 13a1f03: iOS: the Formatted editor keeps the same text at the top when the size class changes at the same width (opening or closing an iPhone Duo, rotating a Pro Max, resizing an iPad window), instead of jumping to other text on iOS 26.

## 1.48.2

### Patch Changes

- bca860d: Fix coordinate hit-testing on WritingPartnerOverlay to allow buttons and subviews to receive clicks, and present the writing partner first-run introduction prompt as a native macOS sheet with HIG-compliant button placement and key equivalents.

## 1.48.1

### Patch Changes

- 242f1dd: iOS: the editor keeps the keyboard more reliably when an iPhone Duo opens or closes (or the window changes size class), retrying for up to a second if the text view isn't in its new window yet.

## 1.48.0

### Minor Changes

- edd6b2b: Swash is ready for iPhone Duo (#65). Opening or closing the phone (or rotating a Pro Max, or resizing an iPad window) now keeps the editor's caret, scroll position, keyboard and undo history in every mode, and closing it in Split mode falls back to the last single-pane mode (Source or Formatted) instead of always Source. The view-mode control is the last toolbar item to overflow, and Flavor, Settings, Document Info and Writing the first. The Share popover points at the Share button wherever the bar is, and Settings keeps a horizontal bar. Builds now ship from Xcode 27.1 or later. Opening or closing the phone now keeps the same text at the top of the editor when the lines rewrap, the old page folds into the new layout with a Flair mirror fold (a fade with Reduce Motion), and the "/" menu closes and edits are saved as the hinge starts to move. In Split on the inner display, the divider sits on the fold.

### Patch Changes

- 339ffd0: iOS: the document manager's Flair wordmark and pixel speckles now draw on a render thread of their own, so they keep animating while the main thread is busy, such as while a document opens.
- fb07aed: Internal: the iOS editor tests wait for the editor's styling pass after each simulated keystroke instead of a fixed 0.15s, so they no longer fail on a slow CI simulator.
- bbb24cc: Give the Mac document window's menu commands (Format, View mode, Markdown flavour, Export and Copy As, Distraction-Free Writing) closures made once per window instead of on every redraw, so they no longer make the document scene re-evaluate each time the window updates.
- 4147e10: Website: the hero has the same faint pixel speckles as the iPhone and iPad document manager, using Flair's `pixel-speckles` (Flair 0.145.0). They twinkle in the margins around the headline, copy and demo, keep clear of the nav and text, follow light and dark mode, and hold still under Reduce Motion.
- 508b617: Fix the iOS document screen sometimes staying blank, with the app stuck at high CPU, after creating or opening a document (most often on iPhone Duo). The Format and Distraction-Free menu commands were given a new closure on every redraw, which made `DocumentGroup` rebuild the document view in an endless loop. They now get closures made once per document view.

## 1.47.0

### Minor Changes

- e083a9d: The iPhone and iPad document manager now has faint pixel speckles around the "Swash" wordmark: Swash's rounded pixel squares in the brand's pink-to-indigo gradient, twinkling slowly and kept clear of the wordmark and the Create Document button. They use Flair's new `pixel-speckles` effect (FlairEffects 0.145.0), follow light and dark mode, and hold still under Reduce Motion. The wordmark's ribbon no longer draws squashed if its view is resized.

## 1.46.0

### Minor Changes

- bc87432: The "Swash" title on the iPhone and iPad document manager is now the website's hero wordmark: New York Bold with tight tracking in the site's ink colours, with Flair's swash-text ribbon looping through the letters. It follows light and dark mode and Dynamic Type, and shows still under Reduce Motion.

## 1.45.0

### Minor Changes

- ce2d287: The writing partner on iPhone and iPad now draws its edits in the chosen Partner style (Settings › Writing Partner), like the Mac: its cursor, the word it selects and types over, and a Flair treatment on what it changed, in light and dark mode. With Reduce Motion on, each stage holds still and fades.
- 545faa8: Writing partner levels (#229): Off, Copyedit (the default) and Ghostwrite replace Off, Suggest and Automatically, with Suggestions as its own switch for fixes the partner isn't sure of. Spelling, grammar and formatting rules no longer have switches: they're always on and learn from undo, with Curly quotes kept under Typography. Copyedit turns a standalone title line into a heading, Ghostwrite asks Pixerate to rewrite prose in place when you pause, and Edit › Writing Partner Edits lists the partner's Copyedit and Ghostwrite edits this session so you can revert one edit or a whole layer without undoing your typing. Settings on Mac and iPhone/iPad share one five-section layout, and the Partner style preview, now on iOS too, shows the chosen level.

## 1.44.0

### Minor Changes

- 7029114: Ensure the iOS writing partner overlay positions inline notes above the software keyboard inset, refreshes partner cursor and underlines across layout and font-size changes, resets the on-device bandleader session when switching documents, and syncs the active document's Markdown flavor with Writing Partner settings.

### Patch Changes

- 322f33f: Stop opening ordinary GitHub Markdown files as Slack mrkdwn. Flavour detection now counts syntax Slack never uses (`**bold**`, `__bold__`, `[text](url)` links, `#` headings, tables, fenced code with a language) against Slack's signals, ignores anything inside code, and gives the signals Markdown shares with Slack (`*text*`, `<https://…>`, `:emoji:`) less weight. Slack messages with `<url|text>` links, `<@user>` mentions or single-asterisk bold are still detected as Slack.
- 16e630f: Fix iOS keyboard formatting bar and format panel so choosing a list type (bulleted, numbered, or to-do) or heading on an empty line immediately applies and styles the marker with the caret placed after it, and picking the same type again toggles it off (#190).

## 1.43.2

### Patch Changes

- 0a0c557: Shortcuts and AppleScript no longer default to an "Inbox" note: the Inbox template and the "Add to Swash inbox" phrase are gone, and appending needs a document, path or name.

## 1.43.1

### Patch Changes

- 01255c3: Restore the committed build number in Info.plist, which local builds had rewritten during PR merges.

## 1.43.0

### Minor Changes

- f8894eb: iOS: Hide top navigation and toolbar items when Focus Mode is active, showing a compact floating focus control in the top-trailing corner, and hiding the iPad outline sidebar.
- 524f3cb: Add quick-access Markdown character strip (`#`, `*`, `_`, `` ` ``, `>`, `-`, `[`, `]`, `(`, `)`, `|`, `!`, `~`) to the iOS keyboard accessory bar with long-press variants and VoiceOver labels (#191).
- 5e3bb4d: Show the most recently used format commands on the iOS keyboard bar with active selection state, and include all iOS-available format commands in the Aa format panel.
- 04a7ef2: Suggest document titles from headings or first lines when renaming on iPad/iOS and creating notes.
- 32ddc2a: Fold iOS Export menu actions (Export as PDF, Export as HTML, Copy as Rich Text, Copy HTML, and Print) into the document share sheet and remove the separate Export toolbar menu on iPhone and iPad.
- 2c12031: Expand Apple Shortcuts, Siri, Spotlight, Focus Filter, and AppleScript automation with `SwashDocumentEntity` and actions for finding or creating notes, templates, appending under headings or as to-dos, full-text search, HTML and flavor conversion, PDF export, task roll-ups, outlines, and document statistics.

### Patch Changes

- 0ea03a1: Context-spelling eval: list the on-device model's suggestion and confidence for each injected word and for words that weren't injected, and add `--all-candidates` to include corrections below the offer threshold, so the thresholds can be checked against a run (#167).
- 11df6ce: Fix the iPad Swash Pro paywall showing "cancelled" and errors from background refreshes, and say that Quick Note tidy-up is on the Mac.
- 65c0899: Display release version and build number in iOS Settings and keep project MARKETING_VERSION synchronized on release
- 82dae5d: Resolve external file conflicts in folder windows by detecting disk modifications prior to saving and presenting Keep Mine, Keep Theirs, or Save Mine as a Copy options.
- d0b0489: Prevent dropping unsaved edits when saving fails while switching files or renaming in folder windows
- 75ef911: Preserve unsaved edits in folder windows when the selected file is renamed, moved, or deleted externally, tracking renames across the workspace using file resource identifiers and saving unsaved edits back to disk rather than discarding them.
- 4401fc4: iOS and macOS: copy writes semantic HTML and RTF for lists, to-dos, and tables.
- 535319d: Fix iOS insertion cursor collapsing to a dot or stretching unpredictably next to hidden Markdown syntax and headings
- 56b9dee: Ensure unsaved edits in an open iOS document are saved before opening a note from the share extension or external URL, and flush all open documents to disk when the app becomes inactive or enters the background.
- 6bd6ec7: Reorganize iPad document toolbar and sidebar: move Document Info, Settings, and Markdown flavour picker to the sidebar footer, place View Mode in the centre group, and remove the extra trailing Share button.
- 9486b1b: Persist Quick Note drafts to UserDefaults across panel dismissals and app restarts, clearing only upon successful creation or appending.
- a4d3148: Keep source formatting as Markdown when sharing into Swash from Safari, Notes, or Notion.
- 4a6f234: Flush uncommitted Writing Tools edits on window close, app termination, and view dismantle, and clear Writing Tools state that's stuck after AppKit reports the session over.

## 1.42.1

### Patch Changes

- 9758692: Fixes a crash on the iOS Simulator when the editor closed or restyled. Swift 6.2 ran the deinits of main-actor editor classes through `swift_task_deinitOnExecutorImpl`, which aborted. The styler, both editors' coordinators, the preview, the layout manager and the writing partner's classes now have `nonisolated deinit`.

## 1.42.0

### Minor Changes

- e0cbab2: Adds the writing partner to iPhone and iPad. It fixes punctuation, capitals and spelling as you type, in Edit Text and in Source, and each fix is its own undo step that the partner learns from. Suggest mode, marks, the Formatting voice and the pause tier (Pixerate with Swash Pro, or Apple Intelligence on the device) work as on the Mac. Settings › Writing Partner has the same switches as the Mac, and the Writing menu can pause the partner for one document. Suggestions are accepted from the edit menu, or with Tab and Esc on a keyboard. While the partner is on, it turns off the keyboard's own autocorrect, which would fight its fixes. If Pixerate can't be reached within a few seconds, the on-device partner takes the pause, and Pixerate is tried again at the next pause.

## 1.41.0

### Minor Changes

- 7926caf: Adds a Mac App Store build: the `Release-AppStore` configuration and `Swash (App Store)` scheme leave out Sparkle and its update settings, sign with App Store entitlements, and sell Swash Pro through the App Store, so the Mac and iOS apps can ship as one Universal Purchase. PR builds now build and verify it.

## 1.40.0

### Minor Changes

- b1a7aad: Swash Pro can now be bought in the app without a Pixerate account. Settings shows a Support ID for purchases made this way, and signing in to Pixerate is optional. Adds an App Store scheme, entitlements and StoreKit configuration, and moves the store into the PixerateAccount package (0.3.0).

## 1.39.0

### Minor Changes

- 7f4f352: Writing partner: marks what it isn't sure about, to settle when you've finished typing (#128). In Automatically, a correction below its confidence threshold, or with more than one candidate (such as "form" → "from" or "for"), now changes nothing: it leaves a faint dotted underline in the partner's colour, and the status bar shows how many are left ("2 to check"). Typing past a mark neither dismisses it nor counts against it. Review them with Edit › Review What to Check (⌥⌘') or by clicking the count: each shows its candidate in place, Tab or ⌥⏎ accepts it as one undo step, Esc keeps the text as written (and the same word isn't marked again in the document), ⌥⌘] and ⌥⌘[ step between marks and ⇧⌥⌘' shows the other choice. A single mark can be settled by putting the caret in it, from its context menu, or by editing it yourself. Marks come from the on-device and Pixerate spelling (#98, #120), pause-tier grammar (#111) and structure suggestions it isn't sure of (#101), are at most three per paragraph, are never written into the Markdown, and are listed in a "To Check" VoiceOver rotor. Settings › Writing has "Mark what it isn't sure about" (on) and "Announce marks with VoiceOver" (off).

## 1.38.0

### Minor Changes

- 8dac5a1: Writing partner: context-aware spelling on this Mac (#98). When you finish a sentence, Apple's on-device model (macOS 26 with Apple Intelligence) reads that paragraph for misspellings the system spell checker leaves alone and real words used wrongly (form/from, their/there, loose/lose, then/than). Confident corrections play through the partner's cursor without moving your caret, each its own undo step, and undoing one tells the partner the word is right in this document. Less confident ones are only offered, as in Suggest mode, and the least confident are dropped. A word you use more than once in the document is treated as yours and left alone, and case-only changes are left to the Punctuate voice. `scripts/run_context_spelling_eval.sh` scores it on the strip-and-restore corpus with wrong words injected, on a Mac where the model is available.

### Patch Changes

- d7f9388: Product proposal domains: the writing assistant domain now includes `Swash/FormattingVoice.swift` (#113).

## 1.37.0

### Minor Changes

- 0d50d17: Writing partner: a Formatting voice that tidies Markdown once you move on from a block you edited (#113). It renumbers ordered lists, gives a list one bullet and consistent indentation, fixes heading syntax (`#Heading` → `# Heading`, no closing `#`s or full stop), collapses runs of blank lines and spaces, removes trailing spaces (keeping two-space line breaks), puts a blank line around headings, lists, quotes and code blocks, widens code spans and emphasis that split a word (`` `hell`o `` → `` `hello` ``), removes stray spaces inside `** … **`, keeps one emphasis marker per document, normalises task boxes, realigns table columns and turns a bare URL on its own line into an autolink. It never touches the block the caret is in, or code, math, HTML or front matter, and each fix is its own "Formatting" undo step that learns from ⌘Z. Each rule has a switch in Settings › Writing › Formatting; in Source view it's off unless "Also in Source view" is on. The website now lists Formatting as shipped.

## 1.36.0

### Minor Changes

- Agent tools: several MCP agents can edit a document at once. Each agent has its own cursor, drawn in its own colour with its name, which moves with everyone's edits. Positions an agent read before another edit are mapped forward, or refused with a clear conflict error when they overlap it (`revision` in results, optional `baseRevision` argument). Each agent edit is its own undo step, named after the agent.

## 1.35.0

### Minor Changes

- Agent tools: an MCP agent's caret, selection and name tag now show inline in the macOS editor, and the text it changes is briefly tinted. The agent keeps its own insertion cursor (starting at yours), so its edits and `set_selection` no longer move your caret or selection, and your typing keeps the agent's cursor in place.

## 1.34.1

### Patch Changes

- 63dd67d: Share the on-device LanguageModelSession across pauses within the same document to use its session memory and cached context. The session is never shared between documents, is dropped when the document changes or the partner is paused, starts again after a few exchanges or when its context window fills (retrying that pause once), and is never asked to answer two pauses at once.

## 1.34.0

### Minor Changes

- 518431b: iOS editor: the edit menu offers Code Language inside a fenced code block (keeping the selection), code-language badges and "/" block-menu chips get pointer hover effects and an accessibility hint, and on iPad the "/" block-menu popover can be driven from a hardware keyboard (Up/Down to move, Return to insert, Escape to close).
- 1986339: Bring Focus Mode, Typewriter Scrolling, Distraction-Free Writing, iCloud conflict resolution, and folder note navigation to iPhone and iPad (#57).
- 0ba7b39: Adopt SwiftUI dynamic previews (`#Preview` and `@Previewable`) across macOS and iOS views, adding reusable `PreviewModifier` and sample document helpers.
- 0087448: Writing partner: on by default for new installs, introduced in place the first time you edit a document with a sample fix and a choice of Automatically, Suggest or Not now. The partner does nothing until that introduction is answered, and when you're signed in it says that the paragraph you pause on is sent to Pixerate. Upgrading keeps your setting (a partner that was off stays off and isn't asked again). Pause it for the current document with Edit › Pause Writing Partner (⌥⌘P); the first time you undo one of its fixes, a quiet reminder says how.

## 1.33.2

### Patch Changes

- 344bc28: Use PixerateMarkdown 0.82.0, which now provides the Confluence and Jira image paste conversion (`HTMLToMarkdown.convert(_:sourceURL:)`), `FormatCommandEdits.activeLink` and `MarkdownSyntax.url`, and drop Swash's local copies in `PixerateMarkdownExtensions.swift`. The paste checks now run against the package.

## 1.33.1

### Patch Changes

- c2ff25e: Embedded MCP server fixes: `tools/list` always lists every document tool, so agents that connect before a document is open (or while a read-only one is in front) can still edit; tool calls without a `document` go to the most recently active window instead of the last-opened one; write tools on a read-only document explain why they failed; and Copy MCP Config adds `"type": "http"`, which Claude Code needs.
  
  Also: a listener that fails to start (port in use) is released and shows why, and changing settings retries it; Settings flags an out-of-range port; unknown paths return 404 before authentication and a bad token returns 401 with `WWW-Authenticate` (compared in constant time); and the server negotiates MCP 2025-06-18 and checks `MCP-Protocol-Version`.
- b04f208: The embedded MCP server now comes from PixerateCore (editor 0.81.0), shared with other Pixerate apps, instead of Swash's own copy. Agents see the same tools and documents. The default port is now 4478, so it no longer clashes with `pixerate-mcp-bridge` on 4477. If you already turned the server on without choosing a port, Swash keeps 4477 so your copied MCP config still works. `list_documents` now also gives a read-only document's reason.

## 1.33.0

### Minor Changes

- d9b8e5a: Add hybrid GenUI Markdown block support (`stats`, `callout`, `actions`, `chart`, `tree`, `orgchart`, `proposals`, `form`) and permission-gated sandboxed `WKWebView` widgets (`widget` / `genui-widget`) across Edit Text, Preview, and AgentBridge MCP discovery.

## 1.32.0

### Minor Changes

- 739a6d6: Replace the external `pixerate-mcp-bridge` client with an embedded Streamable HTTP MCP server (`http://127.0.0.1:4477/mcp`) in Swash, and update Settings › Agents with a one-click Copy MCP Config button.

## 1.31.0

### Minor Changes

- fece983: Writing partner: a Grammar voice. Doubled words and "a"/"an" are fixed on device as you type; agreement and tense, and missing words, are corrected on a pause through the bandleader (Apple Intelligence or Pixerate). Each rule has a switch in Settings › Writing and learns from ⌘Z, and the pause-tier rules stay off for languages the provider doesn't support.

### Patch Changes

- 5b0a8d9: Contributor guidelines ask for SwiftUI dynamic previews (`#Preview`, `@Previewable`, `PreviewModifier`) on new or changed views.
- 12f3de2: Expand iOS `PreviewSnapshotTests` to render additional SwiftUI views (`FormatPanel`, `IOSOutlineList`, `IOSDocumentInfoView`) into `docs/previews/`.

## 1.30.0

### Minor Changes

- eba8da2: Writing partner (subscription, through jazz): spelling uses your vocabulary and team terms. Certain spelling, wrong-word and team-term suggestions play through the partner's cursor at once; uncertain ones are offered as suggestions. Accepting, editing, undoing or dismissing a suggestion is reported back so the partner learns.

## 1.29.0

### Minor Changes

- 709056f: Swash is scriptable with AppleScript on macOS: create a note, open Quick Note, count words and format Markdown. Automation with AppleScript and Shortcuts is documented in `docs/AUTOMATION.md`.
- 90c25e2: Formalise the `WritingPartner` protocol for the fast-tier text duet and resolve Swift 6 actor-isolation warnings across the writing partner, bandleader, and Slack Markdown parser.

### Patch Changes

- 2c91d18: Compact the Writing settings tab by collapsing learned rules into a disclosure group, shortening verbose section footers, and capping the tab height with scrolling.

## 1.28.2

### Patch Changes

- bee8662: Internal: Dependabot no longer proposes TypeScript major updates for the site until Astro's Svelte integration supports them.

## 1.28.1

### Patch Changes

- dcd83c6: Writing partner: dashes and ellipses are on, and learn from you like the other fixes (undo one straight away and the partner does it less), rather than being switches in Settings. Curly quotes stays a switch, off unless you turn it on.

## 1.28.0

### Minor Changes

- 8bfc78c: Add the Chat voice (`ChatVoice`) for the Slack mrkdwn flavour in the writing partner: fix apostrophes, capital `I` and spelling while leaving lowercase starts, message ends, `ok`, `lol` and other chat conventions, `:emoji:` shortcodes and Slack syntax (`<@user>`, `<#channel>`, `<!here>`, `<url|label>`, `*bold*` / `_italic_` / `~strike~` markers) untouched. Track learning stats separately for Chat and Punctuate, and show the active voice in Settings › Writing.
- 34d817c: iOS: the formatting bar above the keyboard is Liquid Glass and scrolls sideways, so no button is cut off on smaller iPhones. A new Aa button swaps the keyboard for a format panel with text styles, inline formats and block types, as in Notes. Inline formats appear directly in the edit menu instead of under Format. The "/" block menu uses glass chips. On macOS 26 the bubble menu uses Liquid Glass.
- 46f6859: iPad: the document outline is now a system sidebar (a split view column) with the standard sidebar button, full height beside the document, in place of the custom column under the toolbar. iPhone keeps the Outline button and sheet.
- 735e8ec: Writing partner: its fixes are now drawn with Flair's text treatments, and there's a new look. When a fix lands, a thin ribbon sweeps under the changed word and curls up past its end, then dissolves (a soft lilac in Dark Mode). Settings › Writing has a Partner style picker with a live preview, so you can go back to the soft sweep or choose another style. The partner's cursor has no name tag, and a word it's about to fix is no longer swept first and then selected, which looked like the same highlight twice. Under Reduce Motion every style holds still and fades. Swash now uses Pixerate's editor package 0.73 and Flair 0.135.
- acdaf64: Optional Pixerate account sign-in (Settings › Account on the Mac, Settings on iPhone and iPad), for the coming writing partner's server features. Swash still works fully without an account. Nothing is sent unless you're signed in and a feature that uses the server is on, and the README's privacy notes say what is sent.
- b9ab72a: The writing partner's server features are now part of Pixerate Pro instead of using Fuel. Settings shows your plan (Basic, Pro, or Pro granted by Pixerate) instead of a Fuel balance, and on Basic offers Pixerate Pro through the App Store, with Restore Purchases and Manage Subscription. Swash refuses writing-partner requests on Basic before sending anything. App Store purchases use StoreKit 2 and are verified by the Pixerate server. Updates PixerateAccount to 0.2.
- ee4c98d: Quick Note tidy-up, with Pixerate Pro: when you pause or save a Quick Note, Pixerate proposes a tidier version (a list, a heading, tasks, consistent dates), previewed as a diff. Accept it as one undo step, or dismiss it and the note stays as it was. Turn it off in Settings › Writing.
- e826632: Writing partner: "Correct spelling" is now on by default whenever the partner is on, rather than following macOS's "Correct spelling automatically". The partner also fixes more as you type: `ok` → `OK`, `id like` → `I'd like` and `ill be` → `I'll be` (but not "the id field" or "I feel ill"), and a comma before "but" when it starts a new clause ("It works, but it's slow"). Each of these is a rule you can turn off in Settings › Writing.
- 9e7a700: Writing partner: its cursor now types each fix the way a person would. It selects the word, types the new one over it, then highlights what changed for a moment. Each word it changes is its own undo step, so ⌘Z takes back one correction at a time and teaches the partner only about that one. You can keep typing while it works. The playback comes from Pixerate's editor package (0.70), so Swash and the other Pixerate editors show agents' edits the same way.
- ba8dd8f: Writing partner: a limited on-device tier with Apple Intelligence (macOS 26 and later). When you pause and Pixerate isn't answering (signed out, or on the Basic plan), Apple's on-device model reads the paragraph you just finished, holds back punctuation where it would be wrong (a poem, a list of fragments), and may suggest that some lines are a list or a heading. Nothing leaves your Mac, and it reads only that paragraph.
- 8bbe7bb: Writing partner, first part (Mac): turn on "Fix punctuation as I type" in Settings › Writing and Swash fixes small things as you finish each word: `i` → `I`, missing apostrophes (`dont` → `don't`), a capital to start a sentence, and a full stop or question mark when you leave a blank line after a one-line paragraph. Each fix is its own undo step; undoing a kind of fix twice in a row stops it, and Settings shows what it has learned. Code, math, HTML, links' addresses and tables are never changed, and it all runs on your Mac. Off by default.
- 3afceb7: Writing partner: "Correct spelling" (Settings › Writing). While the partner is on, it does the autocorrecting in place of macOS's own: misspellings are fixed the way the system's spell checker would, through the partner's cursor and as part of the same undo step. Undoing a spelling fix leaves that word alone in the document. The switch starts out matching your Mac's "Correct spelling automatically". macOS text replacements keep working, and the partner still adds its capital or apostrophe when a replacement got there first (`teh` → `The`).
- dad4331: Add Suggest mode to the writing partner, offering punctuation and spelling fixes in place without changing the document until accepted by keyboard (Tab or ⌥⏎), pointer click, VoiceOver rotor, or the Edit menu.
- 7715098: Writing partner: curly quotes, dashes and ellipses (Settings › Writing › Typography). In prose only, never in code, math or links: straight quotes and apostrophes become curly, `--` and `---` between words become en and em dashes, and `...` becomes an ellipsis. Each is off unless you turn it on, because it changes the characters in your Markdown file.
- 569685a: Writing partner:
  - `its` becomes `it's` when the next word shows it should (`its really`, `its a`, `its going`), and stays before a noun or adjective (`its colour`, `its own`).
  - A soft sweep shows each word or line being checked.
  - The partner's own purple cursor selects what it fixes just before the change appears, then fades.
  - With Reduce Motion on, fixes appear at once, with no sweep.

### Patch Changes

- 264f35e: Update the Pixerate editor package (the Markdown engine, PixerateMarkdown and PixerateCore) from 0.9.0 to 0.67.0. Among other fixes, it builds with Xcode 26.3, which rejected 0.9.0.
- 8c6e25f: Fix the Build & Release workflow hanging for 6 hours in package resolution: the private sticker pack is now injected only for the iOS App Store archive, after the open-source macOS release is built and published. Also harden the CI signing keychain and add job and build-step timeouts.
- 9ce1d59: - **Links (iOS):** tapping a link while editing places the caret and offers Open Link in the edit menu, instead of the system link menu.
  - **Sheets (iOS):** Settings, Document Info and Outline no longer show a stray back chevron.
  - **Tables (all platforms):** table text follows Settings › Text Size (and Dynamic Type on iOS) and matches the body text on iOS.
- 7746c95: iOS: the document toolbar uses standard controls. The view-mode switch is a glyph button (tap toggles Source and Formatted, hold for every mode) instead of a squashed segmented control, Markdown Flavor is a submenu, and Share sends the document file, so the share sheet shows its thumbnail and name instead of a generic text icon.
- 95ca79d: Swash has a website: swash.pixerate.com, built from the new `site/` folder and published automatically from `main`. It follows your system's light or dark appearance, and its screenshots come straight from the app. In the app itself, the `-appearance light|dark` launch argument now fixes the appearance for one launch, which the screenshot scripts use (the older arguments stopped forcing Dark Mode in macOS 27).
- e6f7b6c: Remove unused legacy `icon.png` from repository root
- 9a6f1a3: Website: the hero demo no longer switches looks part-way through on a first visit (it now waits for the effects library before it starts), the ribbon only appears once a fix has landed and not while the word is still being typed, and the headline shows as plain text while the window is being resized. The app's writing partner gets the same change: its ribbon no longer starts while a word is still being typed (Flair 0.135.2).
- 231450a: Site: Tailwind CSS 4 (through its Vite plugin), with TypeScript kept at 6 until Astro's Svelte integration supports 7.
- 0285c69: Add 1024×1024 social media avatar icon (`brand/swash-avatar-1024.png`) inset for circular crops and document its generation in `docs/APP_ICON.md`.
- 23864a6: Add the writing partner strip-and-restore evaluation (`Tests/WritingPartnerEval`, `scripts/run_writing_partner_eval.sh`) with a Markdown and Slack corpus, deterministic stripper and seeded typo injector, manual-clock typing replay harness, per-rule and overall precision/recall/F1 scorer, Markdown diff report, checked-in baseline (`Tests/WritingPartnerEval/baseline.json`), CI regression check, and unclosed protected-context guards while typing front matter, link/image destinations, reference definitions, and table rows.
- c140abb: Writing partner fixes:
  - Each line is now a sentence: a line starts with a capital, and Return at the end of a line of four or more words adds its full stop or question mark (no blank line needed).
  - Return finishes a word, so the last word on a line is fixed too.
  - Fast typing no longer skips fixes.
  - macOS inline predictions are off while the writing partner is on, because together they could corrupt a word (`dont't`).
  - "Fix punctuation as I type" is a switch.
  
  Also:
  - Sign-in no longer crashes, because PixerateAccount is updated to 0.1.1.
  - The MCP bridge says how to start it when nothing is listening.
- b0cded5: Docs: a "What the writing partner sends" page, for each of its tiers: what leaves your Mac, when, and what Pixerate keeps.
- d1ec6bf: Writing partner: its punctuation, casing, apostrophe and spelling rules now come from Pixerate's editor package, where every Pixerate editor shares them. Nothing changes in what it fixes.

## 1.27.2

### Patch Changes

- 6c5902c: Fix the preview cutting off the start and end of documents with long paragraphs, most visible in Quick Look. The preview now measures its content at the width it is shown, so the whole document scrolls into view with its top and bottom padding.

## 1.27.1

### Patch Changes

- 3bc8302: Releases now archive the iPhone and iPad app after the macOS release, and upload it to TestFlight when App Store Connect API secrets are set (see docs/RELEASING.md). Without them, the archive is an unsigned check that the iOS release build works.
- 605175a: Agent tools now read and format Slack documents as Slack mrkdwn: `format_text` writes `*bold*`, `_italic_`, `~strike~` and `<url|text>` links instead of GitHub Markdown, and `get_text`'s plain text, HTML and blocks parse Slack syntax. Also removes unreachable string-based formatting code from the Mac editor.

## 1.27.0

### Minor Changes

- 39bdfb2: Add the Swash Stickers iMessage app on iOS, with the Pixerate sticker sets listed in Settings. Official App Store builds include the proprietary PixerateStickers artwork; open-source builds use an MIT-safe stub at `Packages/PixerateStickers` that needs no private credentials, and don't ship the sticker pack or show the Settings section.

## 1.26.1

### Patch Changes

- 5e22fad: iOS: documents now scroll under the navigation bar, so the header is transparent with the Liquid Glass scroll-edge effect instead of opaque. The folder-access banner sits in the bar area as a glass panel.

## 1.26.0

### Minor Changes

- 0440cb6: Slack mrkdwn documents get the full editor on iPhone and iPad: Formatted mode is now Edit Text, and the formatting bar and edit-menu formatting write Slack's own syntax (`*bold*`, `_italic_`, `~strike~`, `` `code` ``, code blocks, quotes and `<url|text>` links). Slack text is parsed onto the shared Markdown model, so the Mac's Edit Text, bubble menu and Format menu use the same path, replacing the Mac's separate Slack styling; Slack documents now restyle incrementally while typing.

## 1.25.0

### Minor Changes

- c114839: On iPhone and iPad, the edit menu offers Open Link when the selection or caret is in a link, and table cells are edited in a text view that shows bold, italic, inline code and links formatted as you type, as on the Mac.

## 1.24.0

### Minor Changes

- 9336802: AI agents can now read and edit open documents on macOS through the Pixerate MCP bridge (`pixerate-mcp-bridge`), with the same tools as the Pixerate editor: `get_text`, `find_text`, `insert_text`, `replace_text`, `replace_range`, `replace_selection`, `set_selection`, `format_text` and `set_block_type`. Positions are offsets into the Markdown source, every change is one undo step, and read-only documents only offer the read tools. Turn it on in Settings › Agents (off by default), with the bridge's token; the tab shows the connection status.

### Patch Changes

- 278bfb7: Add `SwashiOSTests`, simulator tests for the iOS Edit Text editor (restyling, raw ↔ storage offsets, structural editing, block decorations and the clipboard), and run them in the PR build.

## 1.23.0

### Minor Changes

- d5cebfa: iPhone and iPad: heading outline (a sheet on iPhone, a sidebar column on iPad), Document Info with word count and reading time, Export as PDF or HTML through the share sheet, Print, Copy as Rich Text and Copy HTML, and Typography and Colours in Settings (font, text size, line width and theme), applied to Formatted, Source and the preview on top of Dynamic Type.

## 1.22.0

### Minor Changes

- edefa31: The iOS and iPadOS formatting bar, edit menu and Format menu now read their commands, labels, order, groups and shortcuts from the shared format manifest, like the Mac's Format and bubble menus. The edit menu's Format submenu offers the bubble-menu commands that apply to the selection, including headings and block formats, and the iPadOS Format menu no longer shows Mac-only commands that did nothing on iPad.

## 1.21.2

### Patch Changes

- 2d06317: Fix `icon_ios_1024.png` in `AppIcon.appiconset` so the iOS app icon renders instead of appearing black.

## 1.21.1

### Patch Changes

- 23d6a93: Update repository URLs, Sparkle appcast feed URL, and release download prefix to `Pixerate/Swash`.

## 1.21.0

### Minor Changes

- 6171810: Update the Swash app icon to align with the Pixerate brand palette and loose pixel motif, add `docs/APP_ICON.md`, and migrate bundle, pasteboard, attachment, and App Group identifiers from `com.surrealroad` to `com.pixerate`.

## 1.20.0

### Minor Changes

- a119514: Formatted mode on iPhone and iPad is now the full Edit Text editor, as on the Mac. You edit the text in place with its Markdown syntax hidden: headings, emphasis, links, quote and alert boxes, lists with bullets and tap-to-toggle checkboxes, code blocks with language badges, rules, images, editable tables and rendered math and Mermaid diagrams. Return, Backspace and Tab work on lists, the formatting bar and edit menu apply formatting in place, and edits restyle only the blocks they change. Slack mrkdwn documents still show the read-only preview in Formatted mode.
- 191cd50: The iPhone and iPad editor gains the rest of the Mac's editing interactions. You can tap a code block's language badge to choose its language. Typing "/" at the start of an empty line offers block types: a menu at the caret on iPad, or a bar above the keyboard on iPhone. Table cells can be edited in place, moving between cells with Tab or the keyboard toolbar. Copying from the editor puts rich text and the Markdown source on the clipboard, and pasting rich text from other apps converts it to Markdown.
- aa38505: Swash on iPhone and iPad now works with the rest of the system. `swash://new` and `swash://open` links, the Quick Note widget and the Create Markdown Document shortcut open their note directly, even with another document open. Other apps can share text or links to Swash with "Save to Swash", and the note opens the next time you switch to Swash. The share button no longer crashes on iPhone. On the Mac, Finder thumbnails for Markdown files no longer crash.
- c03772b: On the Mac, File › Open Folder… (⇧⌘O) opens a folder of Markdown files in one window. The first file opens straight away, and a sidebar lists the others so you can switch between them. Edits are saved automatically. Files that are added, renamed, deleted or changed in other apps show up right away, and the New File button adds a Markdown file to the folder.
- 020e073: Swash now builds for iPhone and iPad as well as the Mac, as a first step towards a universal app (see `docs/UNIVERSAL_PLAN.md`). On iOS and iPadOS you can open and create Markdown documents from the Files browser and switch between Source, Formatted (read-only for now) and, on iPad, Split views with synced scrolling. The Source editor continues lists and handles Backspace and Tab like the Mac editor, has a formatting bar above the keyboard and formatting actions in the edit menu, and supports the Format menu on iPad. The Mac app is unchanged.

### Patch Changes

- 95a0e45: Pasting from Confluence or Jira now keeps images. They paste as links to the page's attachments; the images used to be dropped.
- 629bb6d: Moved folder access (security-scoped bookmarks), the default Markdown app prompt and the editor/preview scroll helpers into a reusable local Swift package, `Packages/MacAppKitExtras`. Folders granted earlier stay granted; the app behaves as before.
- 3b36421: The heading outline is now a proper sidebar. In document windows the toolbar splits at its edge instead of running the title across it, and you can resize it. In folder windows the outline is a third tab in the sidebar, next to Files and Search. View ▸ Show Outline (⌃⌘S) switches to it.
- The iPhone and iPad editor and preview now share the Mac's latest rendering: syntax highlighting for 26 languages, the updated paragraph spacing, and Mermaid diagrams shown as images in Edit Text.

## 1.19.1

### Patch Changes

- f106ab2: The Markdown engine (parser, preview and export renderer, HTML paste conversion, code highlighting, and the formatting and editing commands) now comes from the shared `PixerateMarkdown` package in the Pixerate editor repo instead of Swash's own copy. Editing, the Preview, Quick Look and export behave as before.

## 1.19.0

### Minor Changes

- 7045fa1: Adopt the shared `@pixerate/markdown-conformance` package. The Format menu, keyboard shortcuts, bubble menu labels and code-block languages now come from its format-command manifest (generated into `FormatManifest.generated.swift`), and its editing corpus runs against Swash in `scripts/run_conformance_tests.sh` and the PR build.
  
  Editing fixes found by the corpus:
  - Leaving a list or quote with Return on an empty item now adds a blank line, so the next paragraph no longer joins the list.
  - Tab on a list item that can't be nested no longer inserts a tab character.
  - Nesting a numbered item starts the nested list at 1, and moving it back out renumbers it after its parent.
  - Adding, editing or removing a link keeps the selection on the link text.
  - Format ▸ Code Block (⌥⌘C) on a caret wraps the whole line and keeps the caret; inside a code block it removes the fences. Formatting commands that don't apply inside code (bold, italic, strikethrough) do nothing there.

## 1.18.0

### Minor Changes

- d6f45aa: Add typography settings (Settings › Appearance): a system, serif (New York) or monospaced font, a text size with View › Bigger (⌘+), Smaller (⌘−) and Actual Size (⌘0), a readable centred column or full width, and accent themes (Graphite, Ocean, Forest, Rose and Paper) that follow Light and Dark Mode. Changes apply live to Edit Text, Edit Markdown and the Preview of open documents; Quick Look keeps the standard look.

## 1.17.0

### Minor Changes

- 0e74962: Syntax highlighting for many more code languages. A new built-in tokenizer colours JavaScript, TypeScript, Python, Swift, Go, Rust, Ruby, Java, Kotlin, C, C++, C#, Objective-C, PHP, Scala, Dart, SQL, Bash/shell, HTML, XML, CSS/SCSS, JSON, YAML, TOML/INI, Markdown and diff (with common aliases such as `js`, `ts`, `py`, `sh`, `zsh`, `yml`, `c++` and `cs`), including block comments, multi-line, template and triple-quoted strings, numbers, keywords, types and built-ins. The same colours, adapted for Light and Dark Mode, are used in Edit Text, the Preview and Quick Look, and exported HTML and PDF colour code too. The code-language menus list the new languages.

## 1.16.0

### Minor Changes

- 31f9a14: Folder windows now work like a notes workspace. The sidebar shows subfolders as a collapsible tree, and a filter field narrows it by file name. Search (⇧⌘F) looks through the text of every note in the folder and lists each match with its line. Choosing a match opens the note with the match selected. Clicking a relative link to another Markdown file, or a `[[wiki link]]` naming a note, opens that note in the same window. You can rename a file or folder, move it to the Trash (after confirming) or show it in Finder from the sidebar's context menu. Hidden folders, `.git`, `node_modules` and build folders are skipped, and very large folders are listed only up to a limit, so they stay fast.
- c03772b: On the Mac, File › Open Folder… (⇧⌘O) opens a folder of Markdown files in one window. The first file opens straight away, and a sidebar lists the others so you can switch between them. Edits are saved automatically. Files that are added, renamed, deleted or changed in other apps show up right away, and the New File button adds a Markdown file to the folder.

## 1.15.1

### Patch Changes

- d704ab3: Size table columns to fit their content and only display add row/column controls when focused while preserving layout space

## 1.15.0

### Minor Changes

- 007c708: Add images by dragging them onto a document or pasting them, including screenshots. Swash copies the image into an `assets` folder beside the document and inserts a relative `![](assets/…)` link; images already in the document's folder are linked where they are. The folder can be changed (or left empty to use the document's own folder) in Settings › General › Images. If Swash doesn't have permission to write to the folder, it asks for access first. An untitled document has to be saved before a screenshot can be pasted into it.
- a4d06c7: Export and print documents. File › Export as PDF… and Export as HTML… save the document as it looks in the Preview, with math, Mermaid diagrams, alerts, footnotes and images included. HTML exports are a single self-contained file. File › Print… (⌘P) prints it, and Edit › Copy as Rich Text and Copy as HTML put the whole document on the clipboard for Mail, Pages or Google Docs.
- 52f24eb: New writing modes in the View menu on the Mac. Focus Mode (⇧⌘D) dims everything except the paragraph or sentence you're writing (choose which under Focus On). Typewriter Scrolling (⌃⌘T) keeps the line you're typing in the middle of the window. Distraction-Free Writing (⌃⇧⌘F) goes full screen, hides the toolbar, outline and status bar, and centres the text in a readable column; press Esc to leave it.

### Patch Changes

- db72882: Showing or hiding the outline sidebar now widens or narrows the window by the sidebar's width, so the document keeps its width and stays in place, as it already does when switching to and from Split view.
- cf772aa: The README's screenshot now shows Swash in Light or Dark Mode to match the reader's system, with the outline, a callout, a table, math and a Mermaid diagram, and the feature list covers exporting, printing, writing modes and adding images.

## 1.14.5

### Patch Changes

- d1ca2b6: Rewrite the README for people using Swash rather than building it: it now leads with what Swash does, lists its current features and keyboard shortcuts, explains how to install it, and previews the iPhone and iPad app. Release and code-signing notes moved to `docs/RELEASING.md`.

## 1.14.4

### Patch Changes

- f3af456: Restore the original thin line thickness for horizontal dividers (thematic breaks) in the formatted editor.

## 1.14.3

### Patch Changes

- c166ff3: Fix vertical alignment of checkboxes, bullet/numbered list markers, and alert callout icons to align accurately with the text baseline and cap height.

## 1.14.2

### Patch Changes

- 4e4c975: Improve vertical rhythm and text spacing in formatted editor mode:
  - Add generous paragraph spacing before and after headings
  - Increase line spacing and paragraph spacing for body text and list items
  - Reduce contrast and add balanced padding for horizontal rules (thematic breaks)
  - Refine block quote, alert callout, and code block vertical margins
  - Update GFM editor snapshot baselines

## 1.14.1

### Patch Changes

- 4c92adb: Increase text line height and reduce divider contrast in preview mode for a more comfortable and elegant reading rhythm.

## 1.14.0

### Minor Changes

- fe835ff: Render Mermaid diagrams as inline image attachments and use system accent color for inline code:
  
  - Formatted view collapses Mermaid fenced code blocks into an interactive image attachment showing the rendered diagram (or placeholder while rendering) rather than displaying source code text and fences beneath it.
  - Selecting, cutting, copying, or deleting the diagram operates like inline images, preserving the raw Markdown when copied or edited.
  - Raw mode (Source view) retains direct plain text editing of Mermaid code blocks.
  - Inline code text in formatted mode and preview view now uses the system accent color (`NSColor.controlAccentColor` / `Color.accentColor`) instead of hardcoded purple.

## 1.13.0

### Minor Changes

- ae37e74: Fix editor issues in the shipping version and add missing controls:
  
  - The cursor is an arrow over the bubble menu and the editor margins.
  - Clicking an image in the Formatted view selects it and shows an image bubble menu: alt text, size presets (written as `<img width>`), Replace…, Show in Finder and Copy Path.
  - The View menu lists Formatted (⌘1), Source (⌘2) and Split (⌘3).
  - Callouts get their own bubble menu context with a type menu (Note, Tip, Important, Warning, Caution, Plain Quote, Remove Callout), plus a Format ▸ Callout submenu. Removing the quote from a callout no longer leaves `[!NOTE]` behind.
  - Callouts and quotes in the Split preview draw their bar the full height of the box, and the preview re-measures when the divider moves.
  - Clicking into a table cell clears the editor's text selection, no longer shifts the table, and is faster (measured table height, cached cell parses, fewer notifications, tables kept while typing after them).
  - To-do items in the Formatted view use native macOS checkboxes.
  - Footnotes: Format ▸ Insert Footnote, a "/" menu item and a bubble menu button add a numbered footnote; clicking a reference jumps to its definition and back; the bubble menu can jump to or delete a footnote.

## 1.12.1

### Patch Changes

- 909c90f: Align app icon squircle to standard macOS Human Interface Guidelines (824×824 px on 1024×1024 grid) with subtle drop shadow

## 1.12.0

### Minor Changes

- 93b031e: Math editing: inside `$…$`, `$$` blocks and math code blocks, typing `{` inserts a matching `}` (wrapping any selection), and typing `}` steps over an existing one. After a backslash, the system completion shortcut (Esc or ⌥Esc) lists KaTeX commands such as `\frac`, `\alpha` and `\rightarrow`.
- 93b031e: Translate: the formatting bubble has a Translate button for selected text. It opens the system translation popover, and Replace puts the translation into the document as a single undoable edit. Markdown syntax in the selection isn't sent for translation, and formatting within the replaced text isn't kept.

### Patch Changes

- 93b031e: Performance: formulas waiting to render are typeset together and captured in one snapshot (up to 16 at a time) instead of one snapshot each, so documents with a lot of math show their formulas sooner.
- 93b031e: Performance: the formatting bubble finds code blocks and code spans once per document change, instead of rescanning the document several times each time it updates.
- 93b031e: Performance: while you type, Swash no longer looks for a link under the caret after every keystroke. That check scanned the whole document and was the main cost of typing in Source and Slack modes. The bubble menu for a link now appears once typing pauses.

## 1.11.0

### Minor Changes

- 6b144c8: Editor: the system find bar (⌘F, with incremental search) is now enabled. Writing Tools leaves code, math, HTML, front matter, tables and images untouched, and Swash holds off restyling and saving until a rewrite finishes. VoiceOver gets Headings, Links and Tables rotors for moving around a document.
- 6b144c8: Outline and statistics: a heading outline sidebar (View ▸ Show Outline, ⌃⌘S) follows the caret and jumps to a heading when you click it. The status bar now counts only the text readers see. Click the count to switch between words, characters, characters without spaces, paragraphs and reading time; with text selected it shows "selected of total". Format ▸ Insert Table of Contents adds a linked list of headings. The Edit menu gains Copy Heading Link (⌃⌘C), Copy as Markdown Link and Copy File Path.
- 6b144c8: Quick Note, importing and safer opening:
  
  - **Quick Note:** a floating panel opened with a global shortcut (⌃⌥⌘N by default, changeable in Settings), an optional menu bar item, or the Quick Note shortcut. It saves a note as a new document or appends it to the last document you used. Settings can also turn on Open at Login.
  - **Import:** File ▸ Import… (⇧⌘I) converts Word, RTF, HTML and OpenDocument files into new Markdown documents.
  - **Reopen:** File ▸ Reopen Closed Document (⇧⌘T) brings back recently closed files.
  - **Opening files:** requests are gathered together, and Swash asks before opening more than ten at once. A file that can't be opened gets a specific reason: missing, a folder, no permission, too large, or not text.
  - **File types:** `.mkd`, `.mdwn`, `.mdtext`, `.mdtxt` and `.rmd` now open as Markdown, and UTF-16 and legacy-encoded files are decoded instead of rejected.
  - **iCloud conflicts:** a banner offers to choose which conflicting version to keep, and keeping another version can be undone.

## 1.10.3

### Patch Changes

- 1f0b69a: Performance: typing does less work per keystroke. The editor parses each revision once and shares that parse with styling, link detection, the bubble menu and Backspace/Enter handling, and it skips rebuilding the document when SwiftUI only echoes back its own edit. Tables cache their Markdown. Images are cached by path and modification date instead of being reread and rescaled on every restyle, so typing next to an image is about 4× faster. Backspace in an ordinary paragraph no longer parses the whole document. Saved folder permissions are resolved when first needed, once each, which fixes access handles accumulating with every render. The scroll position is only restored after full restyles, so it no longer fights autoscroll while typing.
- 1f0b69a: Performance: an unsaved window no longer looks up its document on every update.
- 1f0b69a: Performance: the window no longer checks the folder permissions of every linked image on every keystroke (it rechecks once typing pauses, and straight away when the file moves or access is granted), the share icon is drawn once, and finding the document's title stops at its first heading.
- 1f0b69a: Performance: the Split view preview no longer rebuilds and re-measures the whole document on every keystroke. It updates once typing pauses, and only the blocks that changed are re-rendered, which uses about 4.5× less CPU while typing on a 900-line document.
- 1f0b69a: Performance: Quick Look previews read at most the first 256 KB of a file, noting when a preview is cut short, and decode and parse it in the background. They show math and Mermaid source instead of starting WebKit, so the Quick Look extension no longer bundles KaTeX, Mermaid and their fonts (about 6 MB). Finder thumbnails read only the first 4 KB of a file.
- 1f0b69a: Performance: typing inside a formula or Mermaid diagram no longer queues a render of every intermediate state, since each block's newest request replaces its older queued one. Renders for views that have gone away are dropped, and finished renders are announced in batches rather than one at a time, so opening a document with many formulas restyles it a few times instead of once per formula.
- 1f0b69a: Performance: scrolling no longer looks up links or recomputes the selection on every frame; it just moves the bubble menu. In Source and Split modes, typing no longer restyles the whole document on every keystroke.
- 1f0b69a: Performance: Slack-formatted documents are restyled once typing pauses (after about 0.1 s) instead of after every keystroke, since Slack styling always covers the whole document.
- 1f0b69a: Performance: editing a table cell no longer makes the next keystroke restyle the whole document, rebuild every table and reload every image.
- 1f0b69a: Add a performance audit (`docs/PERFORMANCE_AUDIT.md`) covering per-keystroke editor work, the preview, image loading, the Markdown parser, math and Mermaid rendering, and the extensions, with a phased improvement plan.

## 1.10.2

### Patch Changes

- 24168d9: Performance: finding code blocks and code spans, which the editor does on styling passes, is about 20% faster.
- 24168d9: Performance: the Markdown parser is about 20% faster on ordinary documents, and inputs that used to take time proportional to the square of their length (long runs of unmatched `*`, `_`, `&` or `<`, many `[` before links, long lists of reference definitions, deeply nested quotes) now parse in linear time. Checking block formats on a long selection is about 40× faster.
- 24168d9: Performance: tables, HTML blocks, link definitions and image titles are parsed without compiling a regular expression each time, and detecting a document's Markdown flavor when it opens examines only its first 32 KB, with patterns compiled once.

## 1.10.1

### Patch Changes

- 85ea2e0: Remove the "Metadata extraction skipped" build warnings from the QuickLook, Share and Thumbnail extensions by skipping App Intents metadata extraction for targets that don't use App Intents.

## 1.10.0

### Minor Changes

- 0fadaf6: Move Markdown flavor switching from the toolbar dropdown to Format ▸ Markdown Flavor. When switching changes the text, Swash asks whether to keep the formatting (rewriting the Markdown for the new flavor) or keep the raw text unchanged. Switching flavor, including the rewrite, can be undone with Edit ▸ Undo.

## 1.9.0

### Minor Changes

- 9afcba8: Redesign the Settings window in the modern macOS style. It now has General and Updates tabs in the toolbar, and each tab uses grouped form sections with explanatory footers. The Updates tab also shows the current version.

## 1.8.6

### Patch Changes

- 4f04726: Publish releases with an up-to-date GitHub release action, removing the last warning from release builds. The app itself is unchanged.

## 1.8.5

### Patch Changes

- 28ccd83: Clear the warnings from release builds. The Quick Look, Thumbnail, Share and Widget extensions now report the same version number as the app, deprecated APIs have been replaced, and CI now builds with a toolchain that supports Swash's macOS 15.7 minimum.

## 1.8.4

### Patch Changes

- 10ec240: Make the window toolbar match Finder and other system apps. The Source, Formatted and Split buttons are now a single segmented control that marks the current view with a gray highlight instead of a solid blue fill, and the title now sits in the same row as the toolbar, which uses the standard larger controls.

## 1.8.3

### Patch Changes

- b4b1493: Keep scrolling the preview when a scroll starts over a table or code block. Vertical scrolls now move the page instead of getting stuck on the block, while sideways scrolls still pan wide tables and code.

## 1.8.2

### Patch Changes

- 5ac4735: Make scrolling in split view smooth. The editor and preview now stay in step without re-parsing and re-laying out the whole preview on every scroll frame, and the preview reuses its parse when the text has not changed.

## 1.8.1

### Patch Changes

- d2421b9: Inline math in Preview headings now renders at the heading's size instead of body size.

## 1.8.0

### Minor Changes

- 55708a3: Render math and Mermaid diagrams offline with bundled KaTeX and Mermaid. In the Preview and Quick Look, `$$` blocks, inline `$…$` math and ```` ```mermaid ```` code blocks are typeset or drawn as images. Edit Text shows the rendering under the editable source, keeps the last good result while you type, and shows KaTeX or Mermaid errors inline.

## 1.7.0

### Minor Changes

- 67bc3d2: Rendering parity and extensions:
  
  - **Inline HTML** renders in both Edit Text and the Preview:
    - keycaps (`<kbd>`), sub- and superscript (`<sub>` / `<sup>`), highlight (`<mark>`), underline (`<u>`, `<ins>`) and strikethrough (`<s>`, `<del>`);
    - bold, italic, small and code tags.
  
    Paired tags are hidden in Edit Text like Markdown markers. Inline `<img>` tags show as images and respect their `width`, and `<br>` breaks the line in the Preview.
  - **HTML blocks in the Preview**:
    - `<details>` / `<summary>` render as a collapsible disclosure with the Markdown inside it.
    - Image-only HTML (README badges, centred screenshots) renders the images at their `width`, wrapping in rows.
    - Other HTML blocks are converted to Markdown and rendered.
    - Bare wrapper tags and HTML comments are no longer shown as raw text.
  - **Math**: `$…$` inline math and `$$` display-math blocks are recognised, so formulas are no longer mangled by Markdown formatting. A `$` before a digit ("$5 and $10") stays plain text. Edit Text shows the TeX source in a math style with a MATH badge on display blocks, and the Preview shows a readable Unicode rendering (Greek letters, sub- and superscripts, fractions, roots, operators and arrows).
  - **Alerts in Edit Text** show their icon beside the title, as in the Preview.
  - **Code block badges** no longer overlap long first lines of code.
  - **Faster typing in long documents**: Edit Text now restyles only the blocks an edit changes, instead of the whole document. Keystrokes in a 2,250-line document with tables and images take about 20 ms, down from about 70 ms.

## 1.6.0

### Minor Changes

- dd0df18: Notion-style structural editing in the editor:
  
  - **Enter** continues bullet, numbered (following items are renumbered), to-do and quote lines, and splits an item at the caret. Enter on an empty item outdents a nested item, or leaves the list or quote.
  - **Tab / ⇧Tab** nest and un-nest list items under their previous sibling.
  - **Backspace** at the start of a heading, list item or to-do removes its marker, and at the start of a quoted line removes one quote level.
  
  - **Caret movement** skips hidden Markdown markers. ← / → move one visible character per press, and clicking at the start of a heading or list item places the caret on its text rather than inside the hidden marker.
  
  - **Keyboard shortcuts and a new Format menu**:
  
    | Shortcut | Action |
    | --- | --- |
    | ⌘B / ⌘I / ⌘E | Bold / italic / inline code |
    | ⌘⇧X | Strikethrough |
    | ⌘K | Add, edit or remove a link |
    | ⌥⌘1–3 / ⌥⌘0 | Heading 1–3 / paragraph |
    | ⇧⌘8 / ⇧⌘7 / ⇧⌘9 | Bullet / numbered / to-do list |
    | ⇧⌘. | Quote |
    | ⌥⌘C | Code block |
  
    Shortcuts also work with only a caret.
  
  - **Clickable to-do checkboxes**: clicking a checkbox in Edit Text checks or unchecks the item.
  
  - **Rich paste**: in Edit Text, text pasted from web pages, Google Docs, Pages, Word or TextEdit is converted to Markdown, keeping bold, italic, strikethrough, code, links, images, headings, lists, to-dos, quotes, code blocks and tables. Text copied from code editors keeps its indentation, and Paste and Match Style still pastes plain text.
  - **Copy and paste between Swash documents** is exact, tables and images included.
  
  - **"/" block menu**: typing `/` at the start of an empty line or list item in Edit Text opens a menu that inserts a block:
    - text or Heading 1–3;
    - bulleted, numbered or to-do list;
    - quote or callout;
    - code block, divider or table.
  
  - **Code block language badge**: fenced code blocks in Edit Text show their language in the top-right corner. Click the badge to choose another language.
  
  Code blocks are never affected, and every change can be undone.

## 1.5.0

### Minor Changes

- e688b5f: Edit Text, the Preview pane, Quick Look and table cells now all render Markdown from one new CommonMark 0.31.2 + GitHub Flavored Markdown parser (`Swash/Markdown/`), so the editor and the preview agree. The parser records the exact source range of every node and syntax marker.
  
  - Supports nested emphasis, backslash escapes, emphasis spanning lines, reference links, `<…>` autolinks, linked images (README badges), nested and multi-paragraph lists, code blocks inside list items, nested blockquotes, ordered task items, GitHub alert titles, footnote references and YAML front matter.
  - Bold and inline code inside headings keep the heading size, in both panes.
  - The Preview renders soft line breaks as spaces (CommonMark), hides raw inline HTML tags (`<br>` becomes a line break), and shows front matter as a metadata box.
  - Styling large documents is faster.
  - The bubble menu works from the same parse:
    - Removing bold, italic, strikethrough or code deletes exactly that span's markers, even when the caret is inside it or the span is nested.
    - Formatting across an existing span merges into it instead of producing broken markers.
    - Lists and headings inside quotes stay quoted (`> - item`), and quoting a heading keeps it a heading.
    - Reference links, autolinks and nested formatting inside links are detected, edited and removed correctly.
    - Context detection understands lists inside quotes, headings inside quotes and alerts.
  - Slack mrkdwn documents keep their existing styling and bubble-menu behaviour.
  - The parser passes all 652 CommonMark spec examples and all 50 GFM extension examples (`./scripts/run_commonmark_spec.sh`).

### Patch Changes

- a92b58b: Fix the release build on the CI toolchain (macOS 15.2 SDK). The editor no longer overrides `NSTextBlock.drawBackground`, whose signature differs between SDKs; indented code, quote and alert backgrounds are now painted by the layout manager. Pull requests now run an app build on the release toolchain.

## 1.4.2

### Patch Changes

- 8149498: Add a WYSIWYG "Edit Text" mode audit and gap analysis (`docs/WYSIWYG_AUDIT.md`) with a reproducible editor/bubble-menu/performance probe harness (`Tests/EditorAudit/`), and document new testing gotchas.
- 7c357b0: Fix WYSIWYG "Edit Text" data-corruption and performance bugs (audit Phase 0):
  
  - Bubble-menu actions no longer edit the wrong text when an image, table or link appears earlier in the document. Editor selections are now mapped between text-storage and raw-markdown offsets.
  - Bubble-menu actions are applied as minimal edits on the text view, so they can be undone with ⌘Z.
  - An image inside a table cell no longer deletes text after the table.
  - Untouched tables keep their original markdown instead of being re-formatted on every keystroke.
  - Styling is ~500× faster on large documents: code regions are located once per pass instead of once per match.
  - Code spans of any backtick length and indented code blocks render correctly, and their contents are no longer interpreted as markdown.
  - Bubble menu:
    - recognises `~~~` code blocks, `1)` ordered lists and task items;
    - no longer treats prose containing `|` as a table;
    - fixes toggling `_italic_` off;
    - trims whitespace from selections before wrapping;
    - formats multi-line selections per line;
    - places code fences on their own lines;
    - removes duplicate dropdown chevrons.

## 1.4.1

### Patch Changes

- fd4b48d: Add specialized Antigravity workspace skills for build/test workflows, changeset management, headless snapshots, and App Sandbox handling. Deduplicate repository agent guidelines.

## 1.4.0

### Minor Changes

- 3dacd09: Re-enable macOS App Sandbox with runtime folder permission prompts and persistent security-scoped bookmarks for document assets.

## 1.3.3

### Patch Changes

- 67e1f8b: Fix relative inline image preview in formatted editor by disabling App Sandbox on the main Swash target to permit reading sibling directory assets

## 1.3.2

### Patch Changes

- c194542: Fix inline image preview resolution in formatted editor by tracking baseURL updates and window lifecycle representedURL fallbacks

## 1.3.1

### Patch Changes

- d2a5ccd: Improve headless test snapshot renderer to capture full height of AppKit NSTextView attachments and content

## 1.3.0

### Minor Changes

- eaae2a8: Support GitHub Flavored Markdown (GFM) footnotes and images across the block parser, Formatted mode editor, preview pane, and Quick Look plugin.
  
  - **Footnotes**:
    - Parsed multi-line continuation footnote definitions and inline references `[^label]`.
    - Hoisted footnote definition blocks to the bottom of the document in Preview and Quick Look with visual separator, anchor targets, and return links `↩`.
    - Styled footnote definitions and references with hanging indents and subtle muted typography in Formatted mode.
  - **Images**:
    - Implemented `ImageTextAttachment` with reverse markdown serialization in Formatted editor mode (`NSTextView`).
    - Added strict document-relative and local path resolution without recursive directory scanning.
    - Implemented aspect ratio scaling, tooltip alt/title display, and placeholder badges for missing or remote resources.
    - Added full GFM spec test suites and automated snapshot rendering for footnotes and images.

## 1.2.1

### Patch Changes

- cfdbf0a: docs: update sample preview to showcase task lists and thematic breaks

## 1.2.0

### Minor Changes

- 9dadde2: Achieve full feature parity with GitHub Flavored Markdown (GFM) Specification:
  - Parser: Add support for link reference definitions, arbitrary fence lengths (backticks and tildes), ATX closing hashes, Setext headings, thematic breaks with mixed characters/spaces, list marker variations (`-`, `*`, `+`, numbered), and pipe handling inside code spans in tables.
  - Formatted Editor: Render continuous alert callout blocks, Setext headings with hidden delimiter lines, thematic break divider rules, interactive checkbox markers with custom tint, and expanded underscore-based inline emphasis.
  - Preview & Quick Look: Add base URL resolution for document-relative assets and hide link reference definition blocks.
  - Test Suite: Add comprehensive GFM compliance fixture suite and headless snapshot renderer covering 40 spec cases across 7 categories.

## 1.1.3

### Patch Changes

- a7be6b4: Add automated GFM spec compliance testing and headless visual snapshot test harness for Tables and Task Lists.

## 1.1.2

### Patch Changes

- b5be2cf: Update AGENTS.md to mandate maintaining and checking GOTCHAS.md for issues, pitfalls, solutions, and workarounds.

## 1.1.1

### Patch Changes

- e346b21: Refine release workflow sequence to commit and push version bumps and assets prior to creating GitHub releases.

## 1.1.0

### Minor Changes

- d1de8bb: Mandate and configure Changesets for versioning and change tracking across the repository.
