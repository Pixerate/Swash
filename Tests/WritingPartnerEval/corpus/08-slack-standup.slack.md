<!here> morning team, here's a quick update on the editor build before standup

*yesterday*
- finished the *Slack mrkdwn* inline parser so `_italic_` and `~strike~` stay in sync with Edit Text
- checked <https://example.com/dont/touch-i|the conformance dashboard> and fixed two edge cases in link removal
- I didn't touch the table attachment layout because <@U12345> is still reviewing the scroll router

*today*
- I'm wiring up the eval runner for the writing partner so we've got a repeatable score on every PR
- it's using a manual clock and a fixed spelling list so the numbers don't change from one Mac to another
- I'll post the baseline report in #dont-break-ci once the script is green

*blockers*
- nothing blocking right now, ok to merge the account gate PR whenever you're ready
- ping me or <@U67890> if you'd like to pair on the afternoon test pass
