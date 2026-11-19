# Repository Rules

## Gotchas & Known Pitfalls
- **Check GOTCHAS.md**: Check `GOTCHAS.md` before starting work and when encountering issues for known pitfalls, issues, and their solutions and workarounds.
- **Maintain GOTCHAS.md**: Maintain and populate `GOTCHAS.md` with any issues and pitfalls encountered, along with their solutions and workarounds.

## Workspace Skills
- **Use Workspace Skills**: Specialized workflows and procedural runbooks are located in `.agents/skills/` (`swash-build-test`, `changeset-management`, `macos-headless-snapshot`, `macos-sandbox-bookmarks`). Follow their procedures for building, changesets, snapshots, and sandbox handling.

On completion of any work, agents must execute the following workflow:

## 1. Validation & Testing
- **Run Tests**: Execute all relevant unit, integration, and build tests locally (e.g. `xcodebuild -scheme Swash -configuration Debug build`) to validate that changes do not break existing functionality or introduce regressions before committing.

## 2. Changeset Creation
- **Requirement**: Every pull request, feature, bug fix, or task MUST include a changeset file generated via `npx changeset` (or by creating a markdown file in `.changeset/<unique-name>.md`).
- **Semantic Bump**: Select the appropriate semantic bump (`patch`, `minor`, `major`) and describe the changes clearly.
- **Verification**: Verify pending changesets before committing using `npx changeset status --since=origin/main`.

## 3. Automatic Commits and Pushes
- **Requirement**: Agents must automatically commit and push their changes to the remote GitHub repository as work is completed.
- **Commit Strategy**: Group changes into logical, atomic commits with clear, descriptive commit messages.
- **Frequency**: Commit and push whenever a coherent sub-task or the main task is successfully completed and verified. Do not wait for multiple unrelated tasks to pile up before committing.

## 4. CI Monitoring & Resolution
- **Monitor CI**: After pushing to GitHub, monitor the GitHub Actions / CI process execution (e.g. using `gh run list` / `gh run watch` or checking status).
- **Fix Errors & Warnings**: If the CI process fails or reports any errors or warnings, inspect the logs immediately, resolve the issues, re-validate locally, and push the fix. Repeat until CI builds cleanly without errors or warnings.

## SwiftUI Dynamic Previews
When adding or modifying SwiftUI `View`s, include Xcode dynamic previews per [Previews in Xcode](https://developer.apple.com/documentation/swiftui/previews-in-xcode):
- Use the `#Preview` macro (not legacy `PreviewProvider`).
- Use `@Previewable` with `@State` / `@Bindable` for interactive bindings instead of `.constant(...)` or custom wrapper structs.
- Use `PreviewModifier` for shared preview environments/dependencies, and `#Preview(traits:)` or `#Preview(arguments:)` to cover key states and layout variants.
- `#Preview(arguments:)` needs macOS 27 / iOS 26, above the macOS app's 15.7 deployment target: mark such previews in macOS-built code `@available(macOS 27, iOS 26, *)`.

## Product Proposal Domains
`.jazz/domains.json` lists Swash's product areas for the weekly automated product proposals, which read it from the default branch. Each domain has a unique kebab-case `id`, a `name`, the repo `paths` that make it up, and optional `docs` and `labels`. The `name` goes into a public web-research brief, so it must describe a generic product category: never the app's name, codenames or anything confidential. When you add, move or rename the files behind a product area, update its `paths` so every entry still exists.
