# What the writing partner sends

Swash's writing partner works in tiers. This page lists, for each one, what leaves your Mac, iPhone or iPad, when, and what is kept. The request format is public: [Pixerate/schemas](https://github.com/Pixerate/schemas), the `jazz` text-lead types.

## As you type: nothing leaves your device

The fixes made while you type all run on your device, with or without Swash Pro or an account. These are capital I, apostrophes, sentence capitals, full stops and question marks, `OK`, commas before "but", and spelling. The rules come from Pixerate's open editor package (`TextMechanics`). Spelling uses the system spell checker, in place of its autocorrect.

## When you pause, on your Mac (macOS 26 and later)

With Apple Intelligence available, the on-device tier reads the paragraph you just finished with Apple's on-device model. It fixes spelling and wrong words from context, tells a poem or list apart from prose, and suggests simple structure. **Nothing is sent anywhere**: the model runs on your Mac, and it reads only that paragraph. It keeps no memory between paragraphs.

## When you pause, through Pixerate (Swash Pro)

Swash sends a writing-partner request to Pixerate only when **all** of these are true:

- you have **Swash Pro** (bought in the App Store, shared through Family Sharing, or unlocked by signing in to an optional Pixerate account with Pixerate Pro or a complimentary grant);
- the writing partner is on (Settings › Writing);
- you've paused after finishing a sentence or leaving a paragraph.

**No Pixerate account is required.** In the App Store version of Swash, StoreKit's signed `AppTransaction` and subscription transaction JWS (`signedTransactionInfo`) are verified with Pixerate to mint an App Store customer session (`X-Pixerate-App-Store-Customer`) and assign the short Support ID shown in Settings › Account.

**What's sent on pause:**

- the paragraph you're writing, as Markdown;
- a little context around it, such as the previous heading and paragraph;
- the document's Markdown flavour (GitHub, CommonMark or Slack);
- which of the partner's rules are on, with how often you kept or undid them;
- your App Store customer session header (`X-Pixerate-App-Store-Customer`, when installed from the App Store), and—only if you've optionally signed in to a Pixerate account—your account's bearer key and active `teamId`.

**What's never sent:**

- the rest of the document;
- code blocks, inline code, math and tables. They're replaced by placeholders before anything leaves your device;
- the document's name, its folder, or other files.

**What Pixerate keeps:**

- **Your text isn't kept.** It's used to answer the request, then discarded.
- **Your App Store transaction identifiers and Support ID** are kept so your subscription and Family Sharing status work across your devices and so you can quote your Support ID if you contact support.
- **What you did with each suggestion is kept** (accepted, edited, dismissed, undone). That's how the partner learns your style across devices.

## In Quick Notes

Quick Note tidy-up uses the Pixerate tier above, with the same rules. It sends the note you paused or saved, which is short, and nothing else.

## Turning it off

- **Settings › Writing › Writing partner › Off** stops everything above.
- If you signed in to a Pixerate account, **Sign Out** in Settings › Account removes the account key from this device.

## For developers

The server address is a development setting for testing against a staging server: `PIXERATE_URL` in the Xcode scheme, or the `pixerateBaseURL` default. It isn't shown in Settings. Running your own compatible server isn't a supported path.
