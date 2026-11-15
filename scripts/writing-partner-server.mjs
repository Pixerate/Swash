#!/usr/bin/env node
/**
 * scripts/writing-partner-server.mjs
 *
 * Minimal reference writing-partner server compatible with Swash (Pixerate/schemas#73).
 *
 * Implements:
 *   - GET  /health              Health check
 *   - GET  /api/teams           Teams & user info for session restoration
 *   - POST /api/agent/text-lead Bandleader turn on pause
 *
 * Can answer with a deterministic fixed response (default) or proxy to an on-prem
 * Ollama model when OLLAMA_MODEL is configured.
 *
 * Usage:
 *   node scripts/writing-partner-server.mjs [--port 8787] [--token secret]
 */

import http from 'node:http';

const JAZZ_TEXT_LEAD_MAX_PARAGRAPH_CHARS = 4000;
const JAZZ_TEXT_LEAD_MAX_CONTEXT_CHARS = 2000;

// Parse CLI flags
const args = process.argv.slice(2);
function getArg(flag, envVar, fallback) {
  const index = args.indexOf(flag);
  if (index !== -1 && index + 1 < args.length) return args[index + 1];
  return process.env[envVar] ?? fallback;
}

const PORT = parseInt(getArg('--port', 'PORT', '8787'), 10);
const HOST = getArg('--host', 'HOST', '127.0.0.1');
const AUTH_TOKEN = getArg('--token', 'AUTH_TOKEN', null);
const OLLAMA_URL = getArg('--ollama-url', 'OLLAMA_URL', 'http://127.0.0.1:11434');
const OLLAMA_MODEL = getArg('--model', 'OLLAMA_MODEL', null);
const QUIET = args.includes('--quiet') || process.env.QUIET === '1';

function log(...msg) {
  if (!QUIET) console.log('[writing-partner-server]', ...msg);
}

/**
 * Counts UTF-16 code units (as NSString and JavaScript string lengths measure).
 */
function utf16Length(str) {
  return typeof str === 'string' ? str.length : 0;
}

/**
 * Checks authorization header against optional configured token.
 */
function checkAuth(req) {
  if (!AUTH_TOKEN) return true;
  const authHeader = req.headers.authorization;
  if (!authHeader) return false;
  const [scheme, token] = authHeader.split(' ');
  return scheme?.toLowerCase() === 'bearer' && token === AUTH_TOKEN;
}

/**
 * Reads request body as a JSON object.
 */
function readJSONBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', chunk => {
      raw += chunk;
      if (raw.length > 1_000_000) {
        req.destroy();
        reject(new Error('Request body too large'));
      }
    });
    req.on('end', () => {
      if (!raw.trim()) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch (err) {
        reject(err);
      }
    });
    req.on('error', reject);
  });
}

/**
 * Classifies genre of the paragraph text.
 */
function detectGenre(paragraph) {
  const trimmed = paragraph.trim();
  if (trimmed.startsWith('#')) return 'heading';
  const lines = trimmed.split('\n').map(l => l.trim()).filter(Boolean);
  if (lines.length > 1 && lines.every(l => /^[-*]\s|^\d+\.\s/.test(l))) return 'list';
  if (lines.length <= 2 && trimmed.length < 80 && /^(hi|hello|hey|thanks|sure|ok|sounds good)/i.test(trimmed)) return 'chat';
  if (lines.length > 1 && lines.every(l => l.length < 50 && !/[.!?]$/.test(l))) return 'notes';
  return 'prose';
}

/**
 * Generates structural suggestions when lines could form a list or heading.
 */
function generateSuggestions(paragraph, genre) {
  const suggestions = [];
  const lines = paragraph.split('\n');

  // If there are multiple raw lines without list markers, offer a list suggestion
  if (lines.length >= 2 && lines.every(l => l.trim().length > 0 && !/^[-*]\s|^\d+\.\s/.test(l.trim()))) {
    const listReplacement = lines.map(l => `- ${l.trim()}`).join('\n');
    suggestions.push({
      kind: 'list',
      range: { start: 0, end: paragraph.length },
      replacement: listReplacement,
      why: 'Turn consecutive items into a bulleted list.'
    });
  }

  return suggestions.slice(0, 4);
}

/**
 * Formats a fixed response conforming to JazzTextLeadResponseSchema.
 */
function makeFixedResponse(request) {
  const { paragraph, flavor = 'gfm' } = request;
  const genre = detectGenre(paragraph);
  const suggestions = generateSuggestions(paragraph, genre);

  return {
    genre,
    palette: [
      {
        voice: 'punctuate',
        strength: genre === 'poem' ? 0 : 0.8
      },
      {
        voice: 'smart-typography',
        strength: genre === 'chat' ? 0.2 : 0.6
      }
    ],
    suggestions,
    why: `Detected ${genre} format (${flavor}). Reference writing partner active.`,
    fuelBalance: 99999
  };
}

/**
 * Tries on-prem Ollama generation if configured, falling back to fixed response.
 */
async function generateResponse(request) {
  if (!OLLAMA_MODEL) {
    return makeFixedResponse(request);
  }

  try {
    const prompt = `You are a writing partner analyzing a Markdown paragraph.
Analyze this paragraph and output ONLY a valid JSON object matching this schema:
{
  "genre": "prose" | "notes" | "chat" | "poem" | "list" | "technical" | "heading",
  "palette": [{"voice": "punctuate", "strength": 0.8}],
  "suggestions": [],
  "why": "one line rationale"
}
Paragraph:
"""${request.paragraph}"""
JSON:`;

    const res = await fetch(`${OLLAMA_URL}/api/generate`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: OLLAMA_MODEL,
        prompt,
        stream: false,
        format: 'json'
      })
    });

    if (res.ok) {
      const data = await res.json();
      const parsed = JSON.parse(data.response);
      if (parsed.genre && Array.isArray(parsed.palette) && typeof parsed.why === 'string') {
        return {
          genre: parsed.genre,
          palette: parsed.palette,
          suggestions: parsed.suggestions ?? [],
          why: parsed.why.slice(0, 280),
          fuelBalance: 99999
        };
      }
    }
  } catch (err) {
    log('Ollama generation failed, falling back to fixed response:', err.message);
  }

  return makeFixedResponse(request);
}

// Request handler
const server = http.createServer(async (req, res) => {
  const parsedUrl = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const pathname = parsedUrl.pathname;
  const mockStatus = parsedUrl.searchParams.get('status') || req.headers['x-mock-status'];

  // Optional mock status override for testing error handling
  if (mockStatus) {
    const code = parseInt(mockStatus, 10);
    if (!isNaN(code) && code >= 400) {
      const headers = { 'Content-Type': 'application/json' };
      if (code === 429) {
        headers['Retry-After'] = req.headers['x-mock-retry-after'] || '30';
      }
      res.writeHead(code, headers);
      res.end(JSON.stringify({ error: `Simulated error ${code}` }));
      return;
    }
  }

  // Health check
  if (pathname === '/health' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', service: 'writing-partner-server' }));
    return;
  }

  // Teams endpoint (for PixerateAccount session restoration)
  if (pathname === '/api/teams' && req.method === 'GET') {
    if (!checkAuth(req)) {
      res.writeHead(401, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Unauthorized: invalid or missing bearer token.' }));
      return;
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      user: {
        id: 'user_selfhosted',
        email: 'writer@localhost',
        displayName: 'Self-Hosted Writer'
      },
      defaultTeamId: 'team_selfhosted',
      teams: [
        {
          id: 'team_selfhosted',
          name: 'Local Writing Partner',
          ownerId: 'user_selfhosted',
          fuelBalance: 99999
        }
      ]
    }));
    return;
  }

  // Text-lead endpoint (contract POST /api/agent/text-lead)
  if (pathname === '/api/agent/text-lead' && req.method === 'POST') {
    if (!checkAuth(req)) {
      res.writeHead(401, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Sign in to use the Swash writing partner.' }));
      return;
    }

    let body;
    try {
      body = await readJSONBody(req);
    } catch {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Malformed JSON payload.' }));
      return;
    }

    const { paragraph, before, after } = body;

    // Validate paragraph
    if (!paragraph || typeof paragraph !== 'string' || utf16Length(paragraph) < 1) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Field "paragraph" must be a non-empty string.' }));
      return;
    }

    if (utf16Length(paragraph) > JAZZ_TEXT_LEAD_MAX_PARAGRAPH_CHARS) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        error: `Field "paragraph" exceeds maximum limit of ${JAZZ_TEXT_LEAD_MAX_PARAGRAPH_CHARS} UTF-16 units (${utf16Length(paragraph)} units provided).`
      }));
      return;
    }

    // Validate before / after context
    if (before && utf16Length(before) > JAZZ_TEXT_LEAD_MAX_CONTEXT_CHARS) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        error: `Field "before" exceeds maximum limit of ${JAZZ_TEXT_LEAD_MAX_CONTEXT_CHARS} UTF-16 units.`
      }));
      return;
    }

    if (after && utf16Length(after) > JAZZ_TEXT_LEAD_MAX_CONTEXT_CHARS) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        error: `Field "after" exceeds maximum limit of ${JAZZ_TEXT_LEAD_MAX_CONTEXT_CHARS} UTF-16 units.`
      }));
      return;
    }

    log(`POST /api/agent/text-lead (${utf16Length(paragraph)} chars)`);
    const responsePayload = await generateResponse(body);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(responsePayload));
    return;
  }

  // Not found
  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: `Not found: ${req.method} ${pathname}` }));
});

server.listen(PORT, HOST, () => {
  log(`Listening on http://${HOST}:${PORT}`);
  if (AUTH_TOKEN) log(`Authentication enabled (Bearer token required)`);
  if (OLLAMA_MODEL) log(`Using Ollama model "${OLLAMA_MODEL}" at ${OLLAMA_URL}`);
  else log(`Using deterministic reference responder`);
});

// Clean shutdown on SIGINT/SIGTERM
process.on('SIGINT', () => { server.close(() => process.exit(0)); });
process.on('SIGTERM', () => { server.close(() => process.exit(0)); });
