# What the writing partner sends

Swash's writing partner works in tiers. This page lists, for each one, what leaves your Mac, iPhone or iPad, when, and what is kept. The request format is public: [Pixerate/schemas](https://github.com/Pixerate/schemas), the `jazz` text-lead types.

## As you type: nothing leaves your device

The fixes made while you type all run on your device, with or without Swash Pro or an account. These are capital I, apostrophes, sentence capitals, full stops and question marks, `OK`, commas before "but", and spelling. The rules come from Pixerate's open editor package (`TextMechanics`). Spelling uses the system spell checker, in place of its autocorrect.

## When you pause, on your device (macOS 26 or iOS 26 and later)

With Apple Intelligence available, the on-device tier reads the paragraph you just finished with Apple's on-device model. It fixes spelling and wrong words from context, tells a poem or list apart from prose, and suggests simple structure. **Nothing is sent anywhere**: the model runs on your Mac, iPhone or iPad, and it reads only that paragraph. It keeps no memory between paragraphs.

With Swash Pro, this tier also takes over when Pixerate can't be reached: if a pause request gets no answer within a few seconds, the paragraph is read on your device instead, and nothing more is sent until the next pause.

## When you pause, through Pixerate (Swash Pro)

Swash sends a writing-partner request to Pixerate only when **all** of these are true:

- you have **Swash Pro** (bought in the App Store, shared through Family Sharing, or unlocked by signing in to an optional Pixerate account with Pixerate Pro or a complimentary grant);
- the writing partner is on (Settings › Writing on the Mac, Settings › Writing Partner on iPhone and iPad);
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

## When you ask Pixie (Swash Pro, on the Mac)

Pixie's chat (View › Show Pixie, ⌥⌘I) is separate from the writing partner: she reads and edits the document only when you ask her something, with the same tools agents use, and each of her edits is one undo step. Nothing is sent until you send her a message.

**What's sent when you ask her:**

- your message, and the conversation so far in that window;
- the document's name, its Markdown flavour, its length in characters and words, and whether it can be edited;
- where your selection is, and up to 600 characters of the selected text;
- whatever she reads with the document's tools to answer you (a section, a search's matches, or the whole document when that's what you asked about), and the edits she makes;
- the same customer session header or account key as the writing partner.

**What Pixerate keeps:**

- **Not your chat.** Pixie's conversations in Swash aren't stored on Pixerate: a chat lasts as long as the window, and the new-chat button clears it.
- **Short notes she writes about how you like to work**, when she decides one is worth keeping (for example "prefers British spelling"), and a line about finished work. You can read them under Skills & Memory in her panel.

## Turning it off

- **Settings › Writing › Writing partner › Off** stops the writing partner.
- Pixie sends nothing unless you open her panel and send her a message.
- If you signed in to a Pixerate account, **Sign Out** in Settings › Account removes the account key from this device.

## For developers

The server address is a development setting for testing against a staging server: `PIXERATE_URL` in the Xcode scheme, or the `pixerateBaseURL` default. It isn't shown in Settings. Running your own compatible server isn't a supported path.
