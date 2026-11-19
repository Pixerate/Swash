# What the writing partner sends

Swash's writing partner works in tiers. This page lists, for each one, what leaves your Mac, when, and what is kept. The request format is public: [Pixerate/schemas](https://github.com/Pixerate/schemas), the `jazz` text-lead types.

On a new install the partner is on (Automatically), but it does nothing until you answer the introduction it shows the first time you edit a document: Automatically, Suggest, or Not now (which turns it off). If you're signed in, the introduction says that the paragraph you pause on is sent to Pixerate. Upgrading keeps the setting you had, and a partner that was off stays off.

## As you type: nothing leaves your Mac

The fixes made while you type all run on your Mac, with or without an account. These are capital I, apostrophes, sentence capitals, full stops and question marks, `OK`, commas before "but", and spelling. The rules come from Pixerate's open editor package (`TextMechanics`). Spelling uses macOS's own spell checker, in place of its autocorrect.

## When you pause, on your Mac (macOS 26 and later)

With Apple Intelligence available, the on-device tier reads the paragraph you just finished with Apple's on-device model. It fixes spelling and wrong words from context, tells a poem or list apart from prose, and suggests simple structure. **Nothing is sent anywhere**: the model runs on your Mac, and it reads only that paragraph. It keeps no memory between paragraphs.

## When you pause, through Pixerate (signed in)

Swash sends a request to Pixerate only when **all** of these are true:

- you're signed in to a Pixerate account (Settings › Account);
- the writing partner is on (Settings › Writing; on by default for new installs, once you've answered its introduction) and not paused for the document;
- you've paused after finishing a sentence or leaving a paragraph;
- your team has Fuel or a plan that covers it.

**What's sent:**

- the paragraph you're writing, as Markdown;
- a little context around it, such as the previous heading and paragraph;
- the document's Markdown flavour (GitHub, CommonMark or Slack);
- which of the partner's rules are on, with how often you kept or undid them;
- your team's id.

**What's never sent:**

- the rest of the document;
- code blocks, inline code, math and tables. They're replaced by placeholders before anything leaves your Mac;
- the document's name, its folder, or other files.

**What Pixerate keeps:**

- **Your text isn't kept.** It's used to answer the request, then discarded.
- **What you did with each suggestion is kept** (accepted, edited, dismissed, undone). That's how the partner learns your style across devices. It's tied to your account and team, not to the text.

## In Quick Notes

Quick Note tidy-up uses the Pixerate tier above, with the same rules. It sends the note you paused or saved, which is short, and nothing else.

## Turning it off

- **Edit › Pause Writing Partner (⌥⌘P)** pauses the partner for the current document, until you resume it or close the window.
- **Settings › Writing › Writing partner › Off** stops everything above.
- **Signing out** stops everything sent to Pixerate. The on-device and as-you-type tiers keep working.

## For developers

The server address is a development setting for testing against a staging server: `PIXERATE_URL` in the Xcode scheme, or the `pixerateBaseURL` default. It isn't shown in Settings. Running your own compatible server isn't a supported path.
