<script lang="ts">
  import { onMount, type Snippet } from 'svelte';
  import type { MountedEffect } from '@pixerate/flair/embed';

  // The closing section's backdrop and wordmark, drawn live by Flair: a soft grain backdrop in the
  // page's theme, and "Swash" in iridescent lettering. Both mount when the section nears the
  // viewport. Without WebGL2 the CSS gradient and the plain word stay.

  type Theme = 'light' | 'dark';
  const BACKDROP = 'noise-grain-bg';
  /** The backdrop in each theme, in the app icon's colours. Both list every control, so a theme change replaces them all. */
  const BACKDROP_VALUES: Record<Theme, Record<string, number | number[]>> = {
    light: {
      uBackground: [0.984, 0.976, 0.988],
      uColorA: [0.8, 0.72, 1],
      uColorB: [0.99, 0.68, 0.86],
      uColorC: [0.93, 0.62, 1],
      uStrength: 0.85,
      uGrain: 0.07,
    },
    dark: {
      uBackground: [0.051, 0.024, 0.102],
      uColorA: [0.557, 0.318, 1],
      uColorB: [0.933, 0.114, 0.494],
      uColorC: [0.263, 0.22, 0.792],
      uStrength: 0.75,
      uGrain: 0.12,
    },
  };

  /** The wordmark as the effect's text input: white letters on transparent, in an italic serif. */
  const WORDMARK =
    'data:image/svg+xml;charset=utf-8,' +
    encodeURIComponent(
      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 256" width="640" height="256"><text x="320" y="128" dy="0.33em" text-anchor="middle" font-family="'New York', 'Iowan Old Style', Georgia, 'Times New Roman', serif" font-style="italic" font-weight="800" font-size="190" fill="#fff">Swash</text></svg>`,
    );

  let { children }: { children?: Snippet } = $props();

  let host: HTMLElement;
  let backdropHost: HTMLDivElement;
  let titleHost: HTMLDivElement;
  let backdropShown = $state(false);
  let titleShown = $state(false);

  function pageTheme(): Theme {
    return document.documentElement.dataset.theme === 'dark' ? 'dark' : 'light';
  }

  onMount(() => {
    let backdrop: MountedEffect | null = null;
    let title: MountedEffect | null = null;
    let gone = false;
    const still = matchMedia('(prefers-reduced-motion: reduce)').matches;

    const backdropValues = () => ({ ...BACKDROP_VALUES[pageTheme()], ...(still ? { uSpeed: 0 } : {}) });

    async function mount() {
      // Flair is large, so it is fetched only now, when the section is about to be seen.
      const [{ mountEffect }, { loadEffect }] = await Promise.all([
        import('@pixerate/flair/embed'),
        import('@pixerate/flair/catalog/lazy'),
      ]);
      try {
        const effect = await loadEffect(BACKDROP);
        if (gone) return;
        const mounted = mountEffect(backdropHost, effect, {
          values: backdropValues(),
          className: 'absolute inset-0 h-full w-full',
        });
        // A backdrop at device resolution costs a lot for little.
        mounted.renderer?.setPixelRatio(1);
        backdrop = mounted;
        await mounted.ready();
        backdropShown = true;
      } catch (err) {
        console.warn('Swash: no WebGL2, keeping the still backdrop.', err);
        return;
      }
      try {
        const effect = await loadEffect('iridescent-text');
        if (gone) return;
        title = mountEffect(titleHost, effect, {
          values: { uText: WORDMARK, uSize: 0.96, uHalo: 0.4, ...(still ? { uSpeed: 0 } : {}) },
          className: 'absolute inset-0 h-full w-full',
        });
        await title.ready();
        titleShown = true;
      } catch {
        titleShown = false;
      }
    }

    const near = new IntersectionObserver(
      ([entry]) => {
        if (!entry?.isIntersecting) return;
        near.disconnect();
        mount();
      },
      { rootMargin: '400px' },
    );
    near.observe(host);

    const themeWatch = new MutationObserver(() => {
      backdrop?.setValues(backdropValues());
    });
    themeWatch.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });

    return () => {
      gone = true;
      near.disconnect();
      themeWatch.disconnect();
      backdrop?.dispose();
      title?.dispose();
    };
  });
</script>

<div bind:this={host} class="stage">
  <div class="still" aria-hidden="true"></div>
  <div bind:this={backdropHost} class="backdrop" class:shown={backdropShown} aria-hidden="true"></div>
  <div class="content">
    <div class="wordmark">
      <span class="plain" class:hidden={titleShown}>Swash</span>
      <div bind:this={titleHost} class="live" class:shown={titleShown} aria-hidden="true"></div>
    </div>
    {@render children?.()}
  </div>
</div>

<style>
  .stage {
    position: relative;
    overflow: hidden;
    border-radius: 28px;
    box-shadow: 0 0 0 1px var(--line);
    isolation: isolate;
  }
  .still,
  .backdrop {
    position: absolute;
    inset: 0;
    z-index: -1;
  }
  .still {
    background:
      radial-gradient(60% 70% at 20% 30%, color-mix(in srgb, var(--accent) 30%, transparent), transparent),
      radial-gradient(55% 60% at 80% 70%, color-mix(in srgb, var(--partner) 34%, transparent), transparent), var(--surface);
  }
  .backdrop {
    opacity: 0;
    transition: opacity 1.4s ease;
  }
  .backdrop.shown {
    opacity: 1;
  }
  .content {
    position: relative;
    display: flex;
    flex-direction: column;
    align-items: center;
    padding: clamp(2.5rem, 6vw, 5rem) 1.5rem;
    text-align: center;
  }
  .wordmark {
    position: relative;
    width: min(100%, 34rem);
    aspect-ratio: 5 / 2;
  }
  .plain,
  .live {
    position: absolute;
    inset: 0;
    transition: opacity 0.7s ease;
  }
  .plain {
    display: grid;
    place-items: center;
    font-family: 'New York', ui-serif, 'Iowan Old Style', Georgia, serif;
    font-style: italic;
    font-weight: 800;
    font-size: clamp(4rem, 16vw, 8.5rem);
    line-height: 1;
    background: linear-gradient(100deg, #ee1d7e, #e12afb 45%, #8e51ff 75%, #4338ca);
    -webkit-background-clip: text;
    background-clip: text;
    color: transparent;
  }
  .plain.hidden,
  .live {
    opacity: 0;
  }
  .live.shown {
    opacity: 1;
  }
</style>
