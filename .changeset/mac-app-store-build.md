---
"swash": minor
---

Adds a Mac App Store build: the `Release-AppStore` configuration and `Swash (App Store)` scheme leave out Sparkle and its update settings, sign with App Store entitlements, and sell Swash Pro through the App Store, so the Mac and iOS apps can ship as one Universal Purchase. PR builds now build and verify it.
