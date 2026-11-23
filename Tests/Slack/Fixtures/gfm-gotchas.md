# Sync Library Gotchas & Workarounds

This document records known pitfalls, edge cases, timing issues and hard-won solutions across `@example/sync`.

Whenever you discover a non-obvious bug or workaround, document it here following the entry schema below.

---

## Entry Template

When adding a new gotcha, format it as follows. :

```markdown
### [Short, Descriptive Title of the Gotcha]

- **Components / Packages**: e.g., `@example/sync-ui`, Vitest
- **Symptoms / Error**: What errors, broken behaviors, or crashes occur?
- **Root Cause**: Why does this happen?
- **Solution / Workaround**: Concrete instructions or code patterns to fix or circumvent it.
```

---

## Reactivity

### Nested State Mutation Across Package Boundaries

- **Components / Packages**: `@example/sync-ui`
- **Symptoms / Error**: Nested properties mutated inside class methods don't update consumers, or log "unsafe_mutation" warnings.
- **Root Cause**: Mutating nested state without re-assigning the reactive property breaks the proxy when classes are compiled in another package.
- **Solution / Workaround**: Assign whole state objects, or expose updater methods that reassign the state rather than mutating nested fields.

### Overlay Components Need a Positioned Parent in Stories

- **Components / Packages**: Storybook, `PresenceOverlay`
- **Symptoms / Error**: The overlay story outlines the whole canvas, and the name tag is clipped off the top.
- **Root Cause**: `PresenceOverlay` is `absolute inset-0`, so it fills its nearest positioned ancestor. Rendered bare, that's the page.
- **Solution / Workaround**: Render overlay stories inside a `relative` mock cell, with room above it for the tag.

---

## Concurrency

### Peer-to-Peer Operational Transform Diverges

- **Components / Packages**: `@example/sync-core`
- **Symptoms / Error**: Two clients typing at once end up with different text.
- **Root Cause**: Every incoming op was transformed against every local op ever made (nothing sent `ot_ack`, so the pending buffer never cleared), and each client gave tie-break priority to the *other* author. OT needs a server that orders operations.
- **Solution / Workaround**: Use a CRDT for peer-to-peer channels, or route operations through a server that assigns their order.
