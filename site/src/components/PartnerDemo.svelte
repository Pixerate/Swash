<script lang="ts">
  import { onMount } from 'svelte';
  import type { TextTreatmentOverlay } from '@pixerate/flair/embed';

  // A re-enactment of the writing partner (Swash/WritingPartner.swift): someone types without
  // looking back, and the partner's cursor follows a few words behind, fixing what they left.
  // Only fixes the app makes today are shown.
  //
  // The partner's look is Flair's `ribbon-curl` text treatment, the same kind of treatment the
  // app's partner can draw with: its caret and name tag, the selection, the word typed over the
  // old one, and a ribbon curling away under what changed. Until Flair has loaded (or if it
  // can't), the fixes are shown with plain CSS instead.

  type Status = 'plain' | 'selected' | 'typing' | 'fixed';
  interface Word {
    /** What the person types. */
    raw: string;
    /** What the partner leaves, when that differs. */
    fix?: string;
    shown: string;
    status: Status;
  }

  const TREATMENT = 'ribbon-curl';
  const LABEL = 'Swash';

  const SCRIPT: [raw: string, fix?: string][][] = [
    [['i', 'I'], ['started'], ['writing'], ['and'], ['didnt', 'didn’t'], ['look'], ['back', 'back.']],
    [['its', 'It’s'], ['liek', 'like'], ['having'], ['an'], ['editor'], ['who'], ['never'], ['interupts', 'interrupts.']],
    [['so', 'So'], ['i', 'I'], ['just'], ['keep'], ['going', 'going.']],
  ];

  /** The script before typing starts, or (`final`) as the partner leaves it, with its fixes marked or not. */
  const fresh = (final: boolean, marked = false): Word[][] =>
    SCRIPT.map((line) =>
      line.map(([raw, fix]) => ({
        raw,
        fix,
        shown: final ? (fix ?? raw) : '',
        status: final && marked && fix ? 'fixed' : 'plain',
      })),
    );

  let lines = $state<Word[][]>(fresh(true));
  /** Where the person's caret is: the line and word being typed. */
  let caret = $state<{ line: number; word: number } | null>(null);
  let fixes = $state(0);
  let host: HTMLElement;
  let page: HTMLElement;

  let overlay: TextTreatmentOverlay | null = null;
  let flair: typeof import('@pixerate/flair/embed') | null = null;

  let run = 0;
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
  const jitter = (base: number, spread: number) => base + Math.random() * spread;

  const isDark = () => document.documentElement.dataset.theme === 'dark';
  const cssColor = (name: string) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  /** The treatment's values for the page's theme: the partner's colour, and its frost for light or dark pages. */
  const treatmentValues = () => ({ color: cssColor('--partner'), darkTheme: isDark(), sparkles: 6 });

  /** The partner's fix, drawn by the treatment over the word's own text. */
  async function fixWithTreatment(word: Word, l: number, w: number, alive: () => boolean) {
    const { rangeRects, caretAt } = flair!;
    const el = page.querySelector<HTMLElement>(`[data-word="${l}-${w}"]`);
    const node = el?.firstChild;
    if (!el || !(node instanceof Text) || !overlay) return false;
    const range = document.createRange();
    range.selectNodeContents(el);
    const rects = () => rangeRects(range, page);
    const style = getComputedStyle(el);
    const font = style.font;
    const measure = document.createElement('canvas').getContext('2d')!;
    measure.font = font;

    const endOfWord = () => caretAt(node, node.length, page);
    const tag = overlay.play('caret', () => ({ caret: endOfWord(), label: LABEL }));
    await overlay.play('checking', () => ({ lines: rects() })).finished;
    if (!alive()) return tag.stop(), true;
    await overlay.play('selecting', () => ({ lines: rects(), caret: endOfWord() })).finished;
    await sleep(160);
    tag.stop();
    if (!alive()) return true;

    // The new word is drawn over the old one, letter by letter, and only then written into the text.
    let typed = '';
    const typing = overlay.play('typing', () => {
      const line = rects()[0];
      return {
        lines: rects(),
        text: typed,
        caret: line && { x: line.x + measure.measureText(typed).width, y: line.y, height: line.height },
        label: LABEL,
        color: style.color,
        background: cssColor('--surface'),
        font,
      };
    });
    for (const ch of word.fix!) {
      if (!alive()) break;
      typed += ch;
      await sleep(60);
    }
    await sleep(120);
    word.shown = word.fix!;
    await Promise.resolve();
    typing.stop();
    if (!alive()) return true;
    // The ribbon plays on while the partner moves to its next fix.
    overlay.play('landed', () => ({ lines: rects(), caret: endOfWord() }));
    return true;
  }

  /** The same fix without Flair: the word is selected, retyped and tinted with CSS. */
  async function fixWithCss(word: Word, alive: () => boolean) {
    word.status = 'selected';
    await sleep(380);
    word.status = 'typing';
    word.shown = '';
    for (const ch of word.fix!) {
      if (!alive()) return;
      word.shown += ch;
      await sleep(48);
    }
    word.status = 'fixed';
  }

  async function play() {
    const mine = ++run;
    const alive = () => mine === run;
    while (alive()) {
      overlay?.clear();
      lines = fresh(false);
      fixes = 0;
      // The partner works through its fixes one at a time, behind the typing.
      let partner: Promise<void> = Promise.resolve();
      const queue = (word: Word, l: number, w: number) => {
        partner = partner.then(async () => {
          if (!alive() || !word.fix) return;
          await sleep(420);
          if (!alive()) return;
          const drawn = overlay ? await fixWithTreatment(word, l, w, alive).catch(() => false) : false;
          if (!drawn) await fixWithCss(word, alive);
          if (alive()) fixes += 1;
        });
      };

      await sleep(600);
      for (let l = 0; l < lines.length && alive(); l++) {
        const line = lines[l]!;
        for (let w = 0; w < line.length && alive(); w++) {
          const word = line[w]!;
          caret = { line: l, word: w };
          for (const ch of word.raw) {
            word.shown += ch;
            await sleep(jitter(55, 70));
          }
          // A word boundary (a space, or Return at the end of the line) is the partner's cue.
          await sleep(jitter(70, 60));
          if (word.fix) queue(word, l, w);
        }
        await partner;
        await sleep(500);
      }
      caret = null;
      await sleep(4200);
    }
  }

  onMount(() => {
    if (matchMedia('(prefers-reduced-motion: reduce)').matches) {
      // No typing: the finished text, with what the partner fixed picked out.
      lines = fresh(true, true);
      return;
    }
    let gone = false;
    // Flair is fetched once the demo is on screen; the first fixes may play in CSS before it arrives.
    import('@pixerate/flair/embed')
      .then((module) => {
        if (gone) return;
        flair = module;
        overlay = module.mountTextTreatment(page, TREATMENT, { values: treatmentValues() as never });
      })
      .catch((err) => console.warn('Swash: Flair not loaded, showing fixes without the treatment.', err));

    const themeWatch = new MutationObserver(() => overlay?.setValues(treatmentValues() as never));
    themeWatch.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });

    // Starts when it scrolls into view, and stops when it leaves.
    const watch = new IntersectionObserver(
      ([entry]) => {
        if (entry?.isIntersecting) play();
        else {
          run++;
          overlay?.clear();
          lines = fresh(true);
          caret = null;
        }
      },
      { threshold: 0.35 },
    );
    watch.observe(host);
    return () => {
      gone = true;
      run++;
      watch.disconnect();
      themeWatch.disconnect();
      overlay?.dispose();
    };
  });
</script>

<figure bind:this={host} class="demo">
  <div class="bar" aria-hidden="true">
    <span class="dots"><i></i><i></i><i></i></span>
    <span class="name">Untitled.md</span>
    <span class="count">{fixes} {fixes === 1 ? 'fix' : 'fixes'} by Swash</span>
  </div>
  <!-- The animation is decoration: the caption below says what it shows. -->
  <div bind:this={page} class="page" aria-hidden="true">
    {#each lines as line, l}
      <p>
        {#each line as word, w}
          {#if word.shown || word.status === 'typing'}
            <span class="word {word.status}" data-word="{l}-{w}">{word.shown}</span>{#if word.status === 'selected' || word.status === 'typing'}<span class="partner"><b>{LABEL}</b></span>{/if}{#if caret && caret.line === l && caret.word === w}<span class="caret"></span>{/if}{' '}
          {/if}
        {/each}
        {#if caret && caret.line === l && !line[caret.word]?.shown}<span class="caret"></span>{/if}
        &#8203;
      </p>
    {/each}
  </div>
  <figcaption>
    You type “i started writing and didnt look back”. Swash follows a few words behind and leaves “I started
    writing and didn’t look back.”
  </figcaption>
</figure>

<style>
  .demo {
    position: relative;
    margin: 0 auto;
    max-width: 44rem;
    text-align: left;
    border-radius: 18px;
    background: var(--surface);
    box-shadow:
      0 0 0 1px var(--line),
      0 30px 60px -20px var(--shot-shadow);
    overflow: hidden;
  }
  .bar {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 0.7rem 1rem;
    border-bottom: 1px solid var(--line);
    font-size: 0.8125rem;
    color: var(--muted);
  }
  .dots {
    display: inline-flex;
    gap: 6px;
  }
  .dots i {
    width: 11px;
    height: 11px;
    border-radius: 50%;
    background: var(--line);
  }
  .name {
    font-weight: 600;
  }
  .count {
    margin-left: auto;
    color: var(--partner);
    font-variant-numeric: tabular-nums;
  }
  .page {
    position: relative;
    padding: 2rem 1.5rem 1.25rem;
    min-height: 12.5rem;
    font-size: clamp(1.05rem, 0.9rem + 0.8vw, 1.35rem);
    line-height: 1.75;
  }
  .page p {
    position: relative;
    margin: 0 0 0.45em;
  }
  .word {
    border-radius: 4px;
    transition: background 0.5s ease, color 0.5s ease;
  }
  .word.selected {
    background: var(--partner-wash);
    box-shadow: 0 0 0 2px var(--partner-wash);
  }
  .word.typing {
    color: var(--partner);
  }
  .word.fixed {
    animation: settle 2.2s ease forwards;
  }
  @keyframes settle {
    from {
      color: var(--partner);
      background: var(--partner-wash);
    }
    to {
      color: inherit;
      background: transparent;
    }
  }
  .caret,
  .partner {
    display: inline-block;
    width: 2px;
    height: 1.15em;
    vertical-align: text-bottom;
    margin-left: 1px;
  }
  .caret {
    background: var(--ink);
    animation: blink 1.1s steps(1) infinite;
  }
  .partner {
    position: relative;
    background: var(--partner);
  }
  .partner b {
    position: absolute;
    left: 0;
    bottom: 100%;
    padding: 1px 6px;
    border-radius: 5px 5px 5px 0;
    background: var(--partner);
    color: var(--page);
    font-size: 0.625rem;
    font-weight: 700;
    line-height: 1.5;
    letter-spacing: 0.02em;
    white-space: nowrap;
  }
  @keyframes blink {
    50% {
      opacity: 0;
    }
  }
  figcaption {
    position: absolute;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip-path: inset(50%);
    white-space: nowrap;
  }
  @media (prefers-reduced-motion: reduce) {
    .word.fixed {
      animation: none;
      color: var(--partner);
    }
  }
</style>
