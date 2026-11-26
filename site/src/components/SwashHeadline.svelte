<script lang="ts">
  import { onMount } from 'svelte';
  import type { MountedEffect } from '@pixerate/flair/embed';

  // The headline with Flair's `swash-text` shader: a ribbon swashes through the words, under the
  // letters along the baseline and over them in a loop, then dissolves. The words are also there
  // as plain text, which is what search engines and screen readers get, and what shows until the
  // shader is ready, without WebGL2, or under Reduce Motion.

  let { text }: { text: string } = $props();

  /** How much of the canvas's height the words take. The rest is room for the ribbon's loop and glow. */
  const SIZE = 0.6;

  type Theme = 'light' | 'dark';
  /** The ribbon in each theme, in the app icon's colours, kept quiet: little glow and few sparkles. */
  const RIBBON: Record<Theme, Record<string, number | number[] | boolean>> = {
    light: { uTail: [1, 0.7, 0.54], uMid: [0.93, 0.42, 1], uHead: [0.5, 0.13, 1], uFrostColor: [0.86, 0.89, 1], uGlow: 0.2, uOpacity: 0.8 },
    dark: { uTail: [1, 0.7, 0.54], uMid: [0.93, 0.42, 1], uHead: [0.71, 0.55, 1], uFrostColor: [0.73, 0.65, 1], uGlow: 0.4, uOpacity: 0.9 },
  };

  let host: HTMLElement;
  let plain: HTMLElement;
  let live: HTMLDivElement;
  let shown = $state(false);

  const pageTheme = (): Theme => (document.documentElement.dataset.theme === 'dark' ? 'dark' : 'light');
  /** The headline's colour as channels 0 to 1. */
  const ink = () => getComputedStyle(plain).color.match(/[\d.]+/g)?.slice(0, 3).map((n) => Number(n) / 255) ?? [0, 0, 0];

  /**
   * The words as the shader's text input: an SVG the size of the text's own box, in the
   * headline's font, so the shader's letters sit exactly over the plain ones.
   */
  function textImage() {
    const style = getComputedStyle(plain);
    const size = parseFloat(style.fontSize);
    const measure = document.createElement('canvas').getContext('2d')!;
    measure.font = `${style.fontStyle} ${style.fontWeight} ${size}px ${style.fontFamily}`;
    measure.letterSpacing = style.letterSpacing;
    const metrics = measure.measureText(text);
    const width = Math.ceil(metrics.width);
    const ascent = metrics.fontBoundingBoxAscent;
    const height = Math.ceil(ascent + metrics.fontBoundingBoxDescent);
    const family = style.fontFamily.replace(/"/g, "'");
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${height}" width="${width * 2}" height="${height * 2}"><text x="0" y="${ascent}" font-family="${family}" font-style="${style.fontStyle}" font-weight="${style.fontWeight}" font-size="${size}" letter-spacing="${style.letterSpacing === 'normal' ? 0 : style.letterSpacing}" fill="#fff">${text}</text></svg>`;
    return { url: 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg), width, height };
  }

  onMount(() => {
    if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    let mounted: MountedEffect | null = null;
    let gone = false;

    /** Sizes the canvas so the words in it are the size of the plain ones. */
    const values = () => {
      const image = textImage();
      host.style.setProperty('--live-width', `${image.width / SIZE}px`);
      host.style.setProperty('--live-height', `${image.height / SIZE}px`);
      return { uText: image.url, uInk: ink(), uSize: SIZE, uBackgroundAlpha: 0, uSparkle: 0.35, uCycle: 8, ...RIBBON[pageTheme()] };
    };

    (async () => {
      try {
        await document.fonts.ready;
        const { mountEffect } = await import('@pixerate/flair/embed');
        if (gone) return;
        mounted = mountEffect(live, 'swash-text', { values: values() as never, className: 'swash-headline-canvas' });
        await mounted.ready();
        shown = true;
      } catch (err) {
        console.warn('Swash: swash-text not drawn, keeping the plain headline.', err);
      }
    })();

    const refresh = () => mounted?.setValues(values() as never);
    const themeWatch = new MutationObserver(refresh);
    themeWatch.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
    // The headline's size follows the window's width.
    let resizing: ReturnType<typeof setTimeout>;
    const onResize = () => {
      // The plain headline shows while the size changes: the canvas would still hold the words
      // at their old size until the shader has the new ones
      if (mounted) shown = false;
      clearTimeout(resizing);
      resizing = setTimeout(async () => {
        refresh();
        await mounted?.ready();
        if (!gone && mounted) shown = true;
      }, 150);
    };
    addEventListener('resize', onResize);

    return () => {
      gone = true;
      themeWatch.disconnect();
      removeEventListener('resize', onResize);
      clearTimeout(resizing);
      mounted?.dispose();
    };
  });
</script>

<span bind:this={host} class="swash-headline">
  <span bind:this={plain} class="plain" data-speckles-clear="copy" data-speckles-ribbon class:hidden={shown}>{text}</span>
  <span bind:this={live} class="live" class:shown aria-hidden="true"></span>
</span>

<style>
  .swash-headline {
    position: relative;
    display: block;
  }
  .plain {
    display: inline-block;
    transition: opacity 0.5s ease;
  }
  /* Still there for screen readers and selection, just not painted. */
  .plain.hidden {
    opacity: 0;
  }
  .live {
    position: absolute;
    left: 50%;
    top: 50%;
    width: var(--live-width, 100%);
    height: var(--live-height, 100%);
    transform: translate(-50%, -50%);
    opacity: 0;
    transition: opacity 0.5s ease;
    pointer-events: none;
  }
  .live.shown {
    opacity: 1;
  }
  .live :global(.swash-headline-canvas),
  .live :global(canvas) {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
  }
</style>
