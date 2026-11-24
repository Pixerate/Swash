import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function collectSwiftFiles(dir) {
  if (!fs.existsSync(dir)) return [];
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...collectSwiftFiles(fullPath));
    } else if (entry.isFile() && entry.name.endsWith('.swift')) {
      files.push(fullPath);
    }
  }
  return files.sort();
}

/**
 * Strip Swift line and nested block comments while respecting string literals
 * and preserving newlines so reported line numbers stay accurate.
 */
function stripSwiftComments(source) {
  let out = '';
  let i = 0;
  const len = source.length;

  while (i < len) {
    const ch = source[i];
    const next = source[i + 1];

    if (ch === '/' && next === '/') {
      out += '  ';
      i += 2;
      while (i < len && source[i] !== '\n') {
        out += ' ';
        i += 1;
      }
      continue;
    }

    if (ch === '/' && next === '*') {
      let depth = 1;
      out += '  ';
      i += 2;
      while (i < len && depth > 0) {
        if (source[i] === '/' && source[i + 1] === '*') {
          depth += 1;
          out += '  ';
          i += 2;
        } else if (source[i] === '*' && source[i + 1] === '/') {
          depth -= 1;
          out += '  ';
          i += 2;
        } else {
          out += source[i] === '\n' ? '\n' : ' ';
          i += 1;
        }
      }
      continue;
    }

    // Raw string literals: #"..."# or #"""..."""#
    if (ch === '#') {
      let hashes = 0;
      let j = i;
      while (j < len && source[j] === '#') {
        hashes += 1;
        j += 1;
      }
      if (source[j] === '"') {
        const isMultiline = source.slice(j, j + 3) === '"""';
        const delim = (isMultiline ? '"""' : '"') + '#'.repeat(hashes);
        const startLen = hashes + (isMultiline ? 3 : 1);
        out += source.slice(i, i + startLen);
        i += startLen;
        while (i < len) {
          if (source.startsWith(delim, i)) {
            out += delim;
            i += delim.length;
            break;
          }
          if (source[i] === '\\' && source.slice(i + 1, i + 1 + hashes) === '#'.repeat(hashes)) {
            out += source.slice(i, i + 2 + hashes);
            i += 2 + hashes;
            continue;
          }
          out += source[i];
          i += 1;
        }
        continue;
      }
    }

    // Standard multi-line or single-line string literals
    if (ch === '"') {
      const isMultiline = source.slice(i, i + 3) === '"""';
      const delim = isMultiline ? '"""' : '"';
      out += delim;
      i += delim.length;
      while (i < len) {
        if (source[i] === '\\' && i + 1 < len) {
          out += source[i] + source[i + 1];
          i += 2;
          continue;
        }
        if (source.startsWith(delim, i)) {
          out += delim;
          i += delim.length;
          break;
        }
        out += source[i];
        if (!isMultiline && source[i] === '\n') {
          i += 1;
          break;
        }
        i += 1;
      }
      continue;
    }

    out += ch;
    i += 1;
  }

  return out;
}

const PREVIEW_DIRS = [
  'Swash',
  'SwashQuickLookExtension',
  'SwashShareExtension',
  'SwashStickers',
  'SwashThumbnailExtension',
  'SwashWidgetExtension',
];

const PREVIEW_RULES = [
  {
    id: 'no_preview_provider',
    regex: /:\s*PreviewProvider\b/,
    message: 'Use the #Preview macro instead of legacy PreviewProvider.',
  },
  {
    id: 'no_binding_constant',
    regex: /(\bBinding)?\.constant\s*\(/,
    message: 'Use @Previewable with @State / @Bindable instead of .constant(...).',
  },
];

const PREVIEW_ARGUMENTS_RE = /#Preview\s*\((?:[^)]*\b)?arguments\s*:/;
const AVAILABLE_MACOS27_IOS26_RE = /@available\s*\(\s*macOS\s+27\s*,\s*iOS\s+26\s*,\s*\*\s*\)/;

function hasPrecedingAvailability(lines, previewLineIndex) {
  if (AVAILABLE_MACOS27_IOS26_RE.test(lines[previewLineIndex])) {
    return true;
  }
  for (let i = previewLineIndex - 1; i >= 0; i -= 1) {
    const trimmed = lines[i].trim();
    if (!trimmed) continue;
    if (AVAILABLE_MACOS27_IOS26_RE.test(trimmed)) return true;
    if (trimmed.startsWith('@')) continue;
    break;
  }
  return false;
}

const violations = [];
let lintedFileCount = 0;

for (const relDir of PREVIEW_DIRS) {
  const files = collectSwiftFiles(path.join(ROOT_DIR, relDir));
  for (const filePath of files) {
    const relPath = path.relative(ROOT_DIR, filePath).split(path.sep).join('/');
    if (relPath.startsWith('Tests/') || relPath.includes('/Tests/')) continue;

    lintedFileCount += 1;
    const raw = fs.readFileSync(filePath, 'utf8');
    const lines = stripSwiftComments(raw).split('\n');
    const isMacosSwash = relPath.startsWith('Swash/') && !relPath.startsWith('Swash/iOS/');

    for (let idx = 0; idx < lines.length; idx += 1) {
      const line = lines[idx];
      for (const rule of PREVIEW_RULES) {
        if (rule.regex.test(line)) {
          violations.push(`${relPath}:${idx + 1}: [${rule.id}] ${rule.message}`);
        }
      }
      if (isMacosSwash && PREVIEW_ARGUMENTS_RE.test(line) && !hasPrecedingAvailability(lines, idx)) {
        violations.push(
          `${relPath}:${idx + 1}: [preview_arguments_available] #Preview(arguments:) in macOS-built Swash code must be preceded by @available(macOS 27, iOS 26, *).`,
        );
      }
    }
  }
}

function validateDomainsJson() {
  const domainsPath = path.join(ROOT_DIR, '.jazz', 'domains.json');
  if (!fs.existsSync(domainsPath)) {
    violations.push('.jazz/domains.json: [domains_json] Missing .jazz/domains.json.');
    return;
  }

  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(domainsPath, 'utf8'));
  } catch (err) {
    violations.push(`.jazz/domains.json: [domains_json] Invalid JSON: ${err.message}`);
    return;
  }

  if (!parsed || !Array.isArray(parsed.domains)) {
    violations.push('.jazz/domains.json: [domains_json] Expected top-level "domains" array.');
    return;
  }

  const seenIds = new Set();
  const kebabRe = /^[a-z0-9]+(-[a-z0-9]+)*$/;
  const forbiddenNameRe = /(swash|pixerate)/i;

  for (const domain of parsed.domains) {
    const label = typeof domain?.id === 'string' && domain.id ? domain.id : '<unknown>';
    if (typeof domain?.id !== 'string' || !kebabRe.test(domain.id)) {
      violations.push(`.jazz/domains.json: [domains_json] Domain id "${label}" must be non-empty kebab-case.`);
    } else if (seenIds.has(domain.id)) {
      violations.push(`.jazz/domains.json: [domains_json] Duplicate domain id "${domain.id}".`);
    } else {
      seenIds.add(domain.id);
    }

    if (typeof domain?.name !== 'string' || !domain.name.trim()) {
      violations.push(`.jazz/domains.json: [domains_json] Domain "${label}" must have a non-empty name.`);
    } else if (forbiddenNameRe.test(domain.name)) {
      violations.push(`.jazz/domains.json: [domains_json] Domain "${label}" name must be generic (no "Swash" or "Pixerate").`);
    }

    for (const field of ['paths', 'docs']) {
      const entries = domain?.[field];
      if (entries === undefined) continue;
      if (!Array.isArray(entries)) {
        violations.push(`.jazz/domains.json: [domains_json] Domain "${label}" field "${field}" must be an array.`);
        continue;
      }
      for (const entry of entries) {
        if (typeof entry !== 'string' || !entry.trim()) {
          violations.push(`.jazz/domains.json: [domains_json] Domain "${label}" has invalid ${field} entry.`);
          continue;
        }
        const resolved = path.resolve(ROOT_DIR, entry);
        if (!fs.existsSync(resolved)) {
          violations.push(`.jazz/domains.json: [domains_json] Missing ${field} entry for domain "${label}": ${entry}`);
        }
      }
    }
  }
}

validateDomainsJson();

if (violations.length > 0) {
  console.error(violations.join('\n'));
  process.exit(1);
}

console.log(`Linted ${lintedFileCount} Swift file(s) and validated .jazz/domains.json with 0 violations.`);
