---
"swash": minor
---

Agent tools: several MCP agents can edit a document at once. Each agent has its own cursor, drawn in its own colour with its name, which moves with everyone's edits. Positions an agent read before another edit are mapped forward, or refused with a clear conflict error when they overlap it (`revision` in results, optional `baseRevision` argument). Each agent edit is its own undo step, named after the agent.
