---
"swash": patch
---

Add the writing partner strip-and-restore evaluation (`Tests/WritingPartnerEval`, `scripts/run_writing_partner_eval.sh`) with a Markdown and Slack corpus, deterministic stripper and seeded typo injector, manual-clock typing replay harness, per-rule and overall precision/recall/F1 scorer, Markdown diff report, checked-in baseline (`Tests/WritingPartnerEval/baseline.json`), CI regression check, and unclosed protected-context guards while typing front matter, link/image destinations, reference definitions, and table rows.
