<script lang="ts">
  import { onMount } from 'svelte';
  import type { MountedEffect } from '@pixerate/flair/embed';

  // Words drawn by a Flair vector effect in the page's colours, over the same words as plain
  // text. The plain text is what search engines and screen readers get, and what shows until the
  // effect is ready, without JavaScript, or under Reduce Motion (these effects are a pen drawing,
  // so there is nothing to show without the motion).

  let {
    effect,
    text,
    /** The effect's values. A string starting with `--` is a CSS colour variable, read in the page's theme. */
    values,
    /** The box the effect draws in: its width in ems of the text, and width / height. */
    width = 5,
    ratio = 4,
    class: className = '',
  }: {
    effect: string;
    text: string;
    values: Record<string, unknown>;
    width?: number;
    ratio?: number;
    class?: string;
  } = $props();

  let host: HTMLElement;
  let live: HTMLDivElement;
  let shown = $state(false);

  /** A CSS colour variable on <html> as channels 0 to 1, which is how Flair takes colours. */
  function css(name: string): number[] {
    const probe = document.createElement('span');
    probe.style.color = `var(${name})`;
    document.body.append(probe);
    const rgb = getComputedStyle(probe).color.match(/[\d.]+/g)?.slice(0, 3).map((n) => Number(n) / 255) ?? [0, 0, 0];
    probe.remove();
    return rgb;
  }

  /**
   * Text effects fit their words to a width they estimate, which stretches a font they did not
   * expect. This undoes that: the words keep their natural width, and the box takes their size,
   * so the drawn letters sit exactly where the plain ones do.
   */
  function fit() {
    const svg = live.querySelector('svg');
    const word = svg?.querySelector<SVGTextElement>('text[textLength]');
    if (!svg || !word) return;
    word.removeAttribute('textLength');
    word.removeAttribute('lengthAdjust');
    const box = word.getBBox();
    const size = Number(word.getAttribute('font-size')) || 100;
    svg.setAttribute('viewBox', `${box.x} ${box.y} ${box.width} ${box.height}`);
    host.style.setProperty('--width', `${box.width / size}em`);
    host.style.setProperty('--ratio', String(box.width / box.height));
  }

  const resolved = () =>
    Object.fromEntries(
      Object.entries(values).map(([key, value]) => [key, typeof value === 'string' && value.startsWith('--') ? css(value) : value]),
    );

  onMount(() => {
    if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    let mounted: MountedEffect | null = null;
    let gone = false;

    const near = new IntersectionObserver(
      async ([entry]) => {
        if (!entry?.isIntersecting) return;
        near.disconnect();
        try {
          const { mountEffect } = await import('@pixerate/flair/embed');
          if (gone) return;
          mounted = mountEffect(live, effect, {
            values: resolved() as never,
            className: 'flair-text-canvas',
            loop: false,
          });
          await mounted.ready();
          fit();
          shown = true;
        } catch (err) {
          console.warn(`Swash: ${effect} not drawn, keeping the plain text.`, err);
        }
      },
      { rootMargin: '200px' },
    );
    near.observe(host);

    const themeWatch = new MutationObserver(() => {
      mounted?.setValues(resolved() as never);
      requestAnimationFrame(fit);
    });
    themeWatch.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });

    return () => {
      gone = true;
      near.disconnect();
      themeWatch.disconnect();
      mounted?.dispose();
    };
  });
</script>

<span bind:this={host} class="flair-text {className}" style="--ratio: {ratio}; --width: {width}em">
  <span class="plain" class:hidden={shown}>{text}</span>
  <span bind:this={live} class="live" class:shown aria-hidden="true"></span>
</span>

<style>
  .flair-text {
    position: relative;
    display: block;
  }
  .plain {
    display: block;
    transition: opacity 0.4s ease;
  }
  /* Still there for screen readers and selection, just not painted. */
  .plain.hidden {
    opacity: 0;
  }
  .live {
    position: absolute;
    left: 50%;
    top: 50%;
    width: min(100%, var(--width));
    aspect-ratio: var(--ratio);
    transform: translate(-50%, -50%);
    opacity: 0;
    pointer-events: none;
  }
  .live.shown {
    opacity: 1;
  }
  .live :global(.flair-text-canvas),
  .live :global(svg),
  .live :global(canvas) {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
  }
</style>
