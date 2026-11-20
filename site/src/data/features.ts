// The page's claims, in one place. `status: 'soon'` shows a "Coming soon" tag; change it to
// 'shipped' when the issue lands and the tag goes.

export type Status = 'shipped' | 'soon';

export interface Feature {
  title: string;
  body: string;
  /** What the partner does, as before → after. */
  example?: [before: string, after: string];
  status: Status;
  /** The GitHub issue tracking a feature that hasn't shipped. */
  issue?: number;
}

export const REPO = 'https://github.com/Pixerate/Swash';
export const DOWNLOAD = `${REPO}/releases/latest/download/Swash-macOS.dmg`;
export const MIN_MACOS = '15.7';

/** What the writing partner tidies. */
export const partnerFixes: Feature[] = [
  {
    title: 'Spelling',
    body: 'Typos are put right as you move on to the next word.',
    example: ['liek', 'like'],
    status: 'shipped',
  },
  {
    title: 'Capitals',
    body: 'Sentences start with a capital, and a lone i stands up straight.',
    example: ['i think', 'I think'],
    status: 'shipped',
  },
  {
    title: 'Apostrophes',
    body: 'Contractions get theirs. “Its” only becomes “it’s” where it should.',
    example: ['dont', 'don’t'],
    status: 'shipped',
  },
  {
    title: 'Full stops',
    body: 'Finish a paragraph and the full stop or question mark is already there.',
    example: ['the end', 'the end.'],
    status: 'shipped',
  },
  {
    title: 'Grammar',
    body: 'Agreement, tense and missing words corrected, without rewriting you.',
    example: ['the results shows', 'the results show'],
    status: 'soon',
    issue: 111,
  },
  {
    title: 'Formatting',
    body: 'Lists renumbered, headings, spacing and tables tidied once you move on, without changing what you wrote.',
    example: ['#Heading', '# Heading'],
    status: 'shipped',
  },
  {
    title: 'Typography',
    body: 'Curly quotes, proper dashes and ellipses, in prose only.',
    example: ['"quoted"', '“quoted”'],
    status: 'soon',
    issue: 104,
  },
];

/** How the partner behaves. */
export const partnerPrinciples: { title: string; body: string }[] = [
  {
    title: 'Every fix is its own undo',
    body: 'Press ⌘Z and the fix is gone, and only the fix. Your words stay exactly as you typed them.',
  },
  {
    title: 'It learns from you',
    body: 'Undo a kind of fix and Swash makes it less often. Keep undoing it and that rule stops.',
  },
  {
    title: 'It knows what to leave alone',
    body: 'Code, math, HTML, link addresses, front matter and tables are never touched.',
  },
  {
    title: 'It stays on your Mac',
    body: 'The partner runs entirely on your device. No account, no tracking, nothing sent anywhere.',
  },
];

/** The editor underneath. */
export const editorExtras: string[] = [
  'Formatted, Source and Split views',
  'A “/” menu for blocks',
  'Editable tables and clickable to-dos',
  'Paste from the web, Docs or Word as clean Markdown',
  'Quick Note from anywhere with ⌃⌥⌘N',
  'Export to PDF, HTML and rich text',
  'Import Word, RTF, HTML and ODT',
  'Apple Intelligence Writing Tools and Translate',
  'Quick Look previews, Shortcuts and Services',
  'CommonMark, GitHub and Slack flavours',
];

/** The tools an agent gets over the Model Context Protocol (Swash/MarkdownAgentTools.swift). */
export const agentTools: string[] = [
  'get_text',
  'find_text',
  'insert_text',
  'replace_text',
  'replace_range',
  'replace_selection',
  'set_selection',
  'format_text',
  'set_block_type',
];

export const platforms: { name: string; detail: string; status: Status; issue?: number }[] = [
  { name: 'Mac', detail: `macOS ${MIN_MACOS} or later. Free and open source.`, status: 'shipped' },
  { name: 'iPhone and iPad', detail: 'The same editor and the same files, wherever you write.', status: 'soon', issue: 39 },
];
