# Running a Compatible Writing-Partner Server

Swash's writing partner uses an on-pause bandleader turn to inspect the paragraph at the caret and offer structural Markdown suggestions (like turning consecutive lines into a bulleted list or inserting a heading), while modulating the local voices (like punctuation and capitals).

By default, Swash talks to Pixerate's servers (`https://pixerate.com`), but Swash's client conforms to a public JSON contract ([`Pixerate/schemas#73`](https://github.com/Pixerate/schemas)). Anyone can point Swash at a self-hosted or compatible server of their own.

---

## The Contract: `POST /api/agent/text-lead`

When the writer pauses at the end of a paragraph or sentence, Swash's server tier calls `POST /api/agent/text-lead`.

### Request (`JazzTextLeadRequest`)

Header: `Content-Type: application/json`  
Authentication: `Authorization: Bearer <token>` (when signed in)

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `paragraph` | `string` | **Yes** | The raw Markdown of the paragraph being written (1 to 4,000 UTF-16 code units). Code spans, math expressions and tables are stripped or replaced with placeholders before sending. |
| `before` | `string` | No | Surrounding context before `paragraph` (e.g. preceding heading or paragraph), up to 2,000 UTF-16 code units. |
| `after` | `string` | No | Surrounding context after `paragraph`, up to 2,000 UTF-16 code units. |
| `flavor` | `string` | No | Markdown dialect: `"commonmark"`, `"gfm"` (default), or `"slack"`. |
| `voices` | `array` | No | Active writing partner voices with their current weights and kept/undone stats. |
| `teamId` | `string` | No | Team identifier sent when billing against a specific team. |

#### Request Example

```json
{
  "paragraph": "apples\npears\nplums",
  "before": "# Shopping",
  "after": "See `[table]` below.",
  "flavor": "gfm",
  "voices": [
    {
      "voice": "punctuate",
      "strength": 0.75,
      "kept": 6,
      "undone": 1,
      "rules": {
        "end-stop": { "kept": 1, "undone": 1 },
        "sentence-case": { "kept": 5, "undone": 0 }
      }
    }
  ],
  "teamId": "team_swash"
}
```

### Response (`JazzTextLeadResponse`)

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `genre` | `string` | **Yes** | Detected genre: `"prose"`, `"notes"`, `"chat"`, `"poem"`, `"list"`, `"technical"`, or `"heading"`. |
| `palette` | `array` | **Yes** | Voices and their recommended strengths (`0` to `1`), plus any `disabledRules`. |
| `suggestions` | `array` | No | Up to 4 structural suggestions (`kind`, `range`, `replacement`, `why`). |
| `why` | `string` | **Yes** | One-line rationale from the server (up to 280 characters). |
| `fuelBalance` | `integer` | No | Remaining balance if the server meters usage. |

#### Range Offsets
`range` in `JazzTextSuggestion` is a half-open interval `[start, end)` in **UTF-16 code-unit offsets** into `paragraph` (the offset unit used by `NSString`, AppKit and JavaScript strings). `0..0` indicates an insertion at the start of the paragraph.

#### Suggestion Kinds
`kind` can be: `"list"`, `"heading"`, `"math"`, `"title"`, `"alert"`, or `"quote"`.

#### Response Example

```json
{
  "genre": "list",
  "palette": [
    { "voice": "punctuate", "strength": 0.3, "disabledRules": ["end-stop"] },
    { "voice": "smart-typography", "strength": 0.6 }
  ],
  "suggestions": [
    {
      "kind": "list",
      "range": { "start": 0, "end": 18 },
      "replacement": "- apples\n- pears\n- plums",
      "why": "Three short lines read cleaner as a bulleted list."
    }
  ],
  "why": "Short shopping items: easing off full stops and offering a list.",
  "fuelBalance": 99999
}
```

---

## Authentication & Session Restoration

### How Swash Sends Credentials
Every network request passes through `PixerateAccess.post`. When a user signs in, Swash sends an `Authorization: Bearer <token>` header on every request.

Before Swash sends its first request to a server, `PixerateAccountClient.restoreSession()` verifies the session by requesting:

```http
GET /api/teams
Authorization: Bearer <token>
```

A self-hosted server should respond to `GET /api/teams` with a minimal JSON body describing the user and team:

```json
{
  "user": {
    "id": "user_local",
    "email": "writer@localhost",
    "displayName": "Self-Hosted Writer"
  },
  "defaultTeamId": "team_local",
  "teams": [
    {
      "id": "team_local",
      "name": "Local Writing Partner",
      "ownerId": "user_local",
      "fuelBalance": 99999
    }
  ]
}
```

### Self-Hosted Authentication Modes
A custom server can adopt any of the following strategies:
1. **No Authentication (Open Localhost)**: Accept any token or no token, returning the default team for all incoming requests.
2. **Pre-Shared Bearer Secret**: Check that `Authorization: Bearer <secret>` matches a configured API token.
3. **Full OAuth / Pixerate Auth**: Implement Pixerate's app authentication flow (`/api/auth/app/token`).

---

## Error Codes Swash Understands

Swash handles HTTP status codes explicitly:

| Status Code | Swash Action | Expected Server Response |
| --- | --- | --- |
| `200..299` | **Success**: Processes the response payload and clears any prior fuel refusal. | Valid `JazzTextLeadResponse` JSON. |
| `401 Unauthorized` | **Sign Out**: The key is revoked or expired. Swash immediately signs out and ceases server requests until the user signs in again. | `{"error": "Invalid or expired token."}` |
| `402 Payment Required` | **Out of Fuel**: Swash pauses cloud writing partner requests, falls back to the local tier, and displays an out-of-fuel notice in Settings until refreshed. | `{"error": "Insufficient fuel balance."}` |
| `429 Too Many Requests` | **Rate Limited**: Swash pauses requests until the timestamp indicated by the `Retry-After` header (in seconds, defaults to 30 s). | Headers: `Retry-After: 30`<br>Body: `{"error": "Rate limit exceeded."}` |
| `5xx / Other` | **Refusal**: Displays the server's `"error"` message string if present in the response JSON. | `{"error": "<detail message>"}` |

---

## Limits & Validation

1. **Paragraph size**: Maximum **4,000 UTF-16 code units**. Swash will not send paragraphs exceeding this limit, and servers should return `400 Bad Request` if received.
2. **Context size**: Maximum **2,000 UTF-16 code units** each for `before` and `after`.
3. **Suggestions count**: At most **4** structural suggestions per response.
4. **Ranges**: Must be non-negative half-open intervals `0 <= start <= end <= paragraph.length` in UTF-16 code units.

---

## Privacy Expectations

Swash upholds strict privacy guarantees:
- **No full-document transmission**: Swash transmits only the paragraph at the caret and up to 2,000 units of surrounding context (`before` / `after`).
- **Sanitized payload**: Code blocks, inline math expressions, LaTeX blocks and table attachments are replaced with placeholders before any request leaves the Mac.
- **No persistent storage**: A compatible server should never persist or log document text; suggestions are computed ephemeral turns.
- **Zero telemetry by default**: If signed out, or if the server feature is disabled, Swash makes zero outbound network requests.

---

## Minimal Reference Server

A zero-dependency reference implementation is provided at [`scripts/writing-partner-server.mjs`](../scripts/writing-partner-server.mjs). It runs on Node.js 18+ and implements the complete schema.

### Running with Node

```bash
# Start on default port 8787
node scripts/writing-partner-server.mjs

# Start with a custom port and bearer token
node scripts/writing-partner-server.mjs --port 9000 --token my-secret-token

# Proxy to a local Ollama model (e.g. llama3.2)
node scripts/writing-partner-server.mjs --model llama3.2 --ollama-url http://127.0.0.1:11434
```

### Running with Docker

You can package the reference server with a minimal `Dockerfile`:

```dockerfile
FROM node:22-alpine
WORKDIR /app
COPY scripts/writing-partner-server.mjs ./server.mjs
EXPOSE 8787
CMD ["node", "server.mjs", "--host", "0.0.0.0", "--port", "8787"]
```

Build and run:

```bash
docker build -t swash-writing-server -f Dockerfile .
docker run -p 8787:8787 swash-writing-server
```

---

## Pointing Swash to Your Server

There are three ways to configure Swash's server address:

### 1. In Settings (Recommended)
1. Open **Settings** (⌘,) and select the **Account** tab.
2. Expand the **Advanced** disclosure section.
3. Enter your server URL (e.g. `http://localhost:8787`) into the **Server address** field.
4. To revert, click **Restore Default**.

### 2. Environment Variable
When launching Swash from Terminal or Xcode, set `PIXERATE_URL`:

```bash
PIXERATE_URL="http://localhost:8787" open -a Swash
```

### 3. Command Line (`defaults write`)
Set the persistent user default:

```bash
defaults write net.daringfireball.swash pixerateBaseURL "http://localhost:8787"
```

To reset back to default:

```bash
defaults delete net.daringfireball.swash pixerateBaseURL
```
