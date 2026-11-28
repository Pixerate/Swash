<script lang="ts">
  import { onMount } from 'svelte';
  import type { MountedEffect } from '@pixerate/flair/embed';

  // Faint, twinkling pixel speckles over the hero's backdrop: Flair's `pixel-speckles`, the pixel
  // square from docs/BRAND.md in the neon accent gradient, as on the iPhone and iPad document
  // manager (Swash/iOS/IOSLaunchSpeckles.swift). They keep clear of the elements marked
  // `data-speckles-clear`: those sharing a name are one box, and Flair takes up to four (here the
  // nav, the copy from the eyebrow to the small print, and the demo). `data-speckles-ribbon` leaves
  // room around the headline for its ribbon's loop and glow. They hold still under Reduce Motion,
  // and without WebGL2 there are none.

  type Theme = 'light' | 'dark';

  /** As in the app: Flair's Dark page values, and in light mode fainter, ending in the deep indigo. */
  const THEME: Record<Theme, Record<string, number | number[]>> = {
    light: { uMinOpacity: 0.18, uMaxOpacity: 0.5, uColor4: [0x43 / 255, 0x38 / 255, 0xca / 255] },
    dark: { uMinOpacity: 0.22, uMaxOpacity: 0.6, uColor4: [109 / 255, 99 / 255, 240 / 255] },
  };
  /** Sizes in CSS pixels. Flair takes them in frame heights, so they're divided by the canvas's. */
  const SPACING = 72;
  const MIN_SIZE = 3;
  const MAX_SIZE = 9;
  /** Room left around a marked element, in pixels. */
  const PAD = 16;

  let host: HTMLDivElement;
  let shown = $state(false);

  const pageTheme = (): Theme => (document.documentElement.dataset.theme === 'dark' ? 'dark' : 'light');

  /** The marked boxes, padded and merged by name, as x, y, width, height from the canvas's top left, 0 to 1. */
  function keepClear(box: DOMRect) {
    const named = new Map<string, [number, number, number, number]>();
    document.querySelectorAll<HTMLElement>('[data-speckles-clear]').forEach((el) => {
      const r = el.getBoundingClientRect();
      if (!r.width || !r.height) return;
      const em = parseFloat(getComputedStyle(el).fontSize);
      const [side, top, bottom] = el.hasAttribute('data-speckles-ribbon') ? [0.4 * em, 0.3 * em, 0.2 * em] : [PAD, PAD, PAD];
      const edges: [number, number, number, number] = [r.left - side, r.top - top, r.right + side, r.bottom + bottom];
      const name = el.dataset.specklesClear || `box${named.size}`;
      const seen = named.get(name);
      named.set(name, seen ? [Math.min(seen[0], edges[0]), Math.min(seen[1], edges[1]), Math.max(seen[2], edges[2]), Math.max(seen[3], edges[3])] : edges);
    });
    const boxes = [...named.values()].slice(0, 4).map(([left, top, right, bottom]) => {
      const x = Math.max(0, left - box.left);
      const y = Math.max(0, top - box.top);
      const w = Math.min(box.width, right - box.left) - x;
      const h = Math.min(box.height, bottom - box.top) - y;
      return w > 0 && h > 0 ? [x / box.width, y / box.height, w / box.width, h / box.height] : [0, 0, 0, 0];
    });
    while (boxes.length < 4) boxes.push([0, 0, 0, 0]);
    return { uClear1: boxes[0], uClear2: boxes[1], uClear3: boxes[2], uClear4: boxes[3] };
  }

  onMount(() => {
    const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
    let mounted: MountedEffect | null = null;
    let gone = false;

    const values = () => {
      const box = host.getBoundingClientRect();
      const height = Math.max(1, box.height);
      return {
        uSpacing: SPACING / height,
        uDensity: 0.6,
        uMinSize: MIN_SIZE / height,
        uMaxSize: MAX_SIZE / height,
        uBackgroundAlpha: 0,
        ...(still ? { uSpeed: 0 } : {}),
        ...THEME[pageTheme()],
        ...keepClear(box),
      };
    };

    (async () => {
      try {
        await document.fonts.ready;
        const { mountEffect } = await import('@pixerate/flair/embed');
        if (gone) return;
        mounted = mountEffect(host, 'pixel-speckles', { values: values() as never, className: 'hero-speckles-canvas' });
        await mounted.ready();
        if (!gone) shown = true;
      } catch (err) {
        console.warn('Swash: pixel-speckles not drawn.', err);
      }
    })();

    const refresh = () => mounted?.setValues(values() as never);
    const themeWatch = new MutationObserver(refresh);
    themeWatch.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
    // The hero and the marked elements change size with the window, and as the demo loads
    let pending = 0;
    const sizeWatch = new ResizeObserver(() => {
      cancelAnimationFrame(pending);
      pending = requestAnimationFrame(refresh);
    });
    sizeWatch.observe(host);
    document.querySelectorAll('[data-speckles-clear]').forEach((el) => sizeWatch.observe(el));

    return () => {
      gone = true;
      themeWatch.disconnect();
      sizeWatch.disconnect();
      cancelAnimationFrame(pending);
      mounted?.dispose();
    };
  });
</script>

<div bind:this={host} class="hero-speckles" class:shown aria-hidden="true"></div>

<style>
  .hero-speckles {
    position: absolute;
    inset: 0;
    z-index: 1;
    pointer-events: none;
    opacity: 0;
    transition: opacity 1.2s ease;
  }
  .hero-speckles.shown {
    opacity: 1;
  }
  .hero-speckles :global(.hero-speckles-canvas),
  .hero-speckles :global(canvas) {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
  }
</style>
