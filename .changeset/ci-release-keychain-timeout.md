---
"swash": patch
---

Fix the Build & Release workflow hanging for 6 hours in package resolution: the private sticker pack is now injected only for the iOS App Store archive, after the open-source macOS release is built and published. Also harden the CI signing keychain and add job and build-step timeouts.
