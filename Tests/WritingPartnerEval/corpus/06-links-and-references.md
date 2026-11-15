# Links, Addresses, and Cross-References

A good Markdown document links out to specs, issues, and sibling notes without cluttering the prose. When I'm adding links, the words inside the square brackets are ordinary text, but the URL inside the parentheses is an address and mustn't be altered.

You can [read the full architecture guide](https://example.com/dont/touch-i?teh=1&ok=false) to see how the parser maps offsets. If you're looking for the issue tracker, check <https://github.com/Pixerate/Swash/issues/dont-touch-i> or visit https://docs.example.com/teh/id/overview directly in your browser.

![Architecture overview diagram](assets/dont_touch_i_or_teh.png "dont change image titles")

Sometimes I prefer reference-style links when the same address appears several times in a section. You can open the [conformance notes][arch] or email <support@dont.example.com> if a test case fails on your machine.

For local project files, paths like `Swash/WritingPartner.swift`, `docs/file_dont.md`, and tags such as #dont or @teh_user stay untouched in prose. I don't want a path or a handle rewritten while I'm referencing a module.

How do we verify that link destinations never drift during editing? We parse the document tree and check that every edit lands inside a plain text node, never inside link markers, autolinks, or reference definitions. I've run the link checks across both flavours, and it's OK when a sentence ends right after a link.

[arch]: https://example.com/dont/arch/teh-i "dont modify reference definitions"
