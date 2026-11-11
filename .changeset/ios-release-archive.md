---
"swash": patch
---

Releases now archive the iPhone and iPad app after the macOS release, and upload it to TestFlight when App Store Connect API secrets are set (see docs/RELEASING.md). Without them, the archive is an unsigned check that the iOS release build works.
