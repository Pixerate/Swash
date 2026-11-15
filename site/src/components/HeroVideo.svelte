<script lang="ts">
  import { SlopVideo } from '@slopmachine/svelte';
  import { onMount } from 'svelte';

  type Theme = 'light' | 'dark';

  /** The Slop Machine bucket behind the hero. Its one variable, `color`, is the page's theme. */
  const BUCKET_ID = 'cPQRfIdPbFUTbeav3rzk';

  // Unset until the page's theme is known, so only that theme's video is ever requested.
  let theme = $state<Theme | null>(null);
  let failed = $state(false);
  let ready = $state(false);
  let still = $state(false);

  function pageTheme(): Theme {
    return document.documentElement.dataset.theme === 'dark' ? 'dark' : 'light';
  }

  onMount(() => {
    still = matchMedia('(prefers-reduced-motion: reduce)').matches;
    theme = pageTheme();
    const watch = new MutationObserver(() => {
      const next = pageTheme();
      if (next === theme) return;
      ready = false;
      failed = false;
      theme = next;
    });
    watch.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
    return () => watch.disconnect();
  });
</script>

<div class="hero-video" aria-hidden="true">
  {#if theme && !failed}
    {#key theme}
      <div class="layer" class:ready>
        <SlopVideo
          bucketId={BUCKET_ID}
          aspectRatio="16:9"
          variables={{ color: theme }}
          autoplay={!still}
          class="hero-video-wrapper"
          onloadeddata={() => (ready = true)}
          onGenerationError={() => (failed = true)}
        >
          {#snippet loader()}{/snippet}
          {#snippet errorFallback()}{/snippet}
        </SlopVideo>
      </div>
    {/key}
  {/if}
  <!-- Fades the video into the page, most behind the headline. Without a video this is the hero's background. -->
  <div class="glow"></div>
  <div class="veil"></div>
</div>

<style>
  .hero-video {
    position: absolute;
    inset: 0;
    z-index: 0;
    overflow: hidden;
    pointer-events: none;
    user-select: none;
  }
  .layer {
    position: absolute;
    inset: 0;
    opacity: 0;
    transition: opacity 1.2s ease;
  }
  .layer.ready {
    opacity: var(--hero-video);
  }
  .glow {
    position: absolute;
    inset: 0;
    background:
      radial-gradient(50% 45% at 22% 18%, color-mix(in srgb, var(--accent) 22%, transparent), transparent),
      radial-gradient(45% 40% at 80% 12%, color-mix(in srgb, var(--partner) 22%, transparent), transparent);
    mix-blend-mode: normal;
    opacity: 0.6;
  }
  .veil {
    position: absolute;
    inset: 0;
    background:
      radial-gradient(64% 46% at 50% 34%, color-mix(in srgb, var(--page) 88%, transparent) 30%, transparent 90%),
      linear-gradient(to bottom, transparent 55%, var(--page) 98%);
  }
  :global(.hero-video-wrapper),
  :global(.hero-video-wrapper .slop-wrapper) {
    width: 100% !important;
    height: 100% !important;
    max-width: none !important;
    aspect-ratio: auto !important;
  }
  :global(.hero-video-wrapper video) {
    width: 100% !important;
    height: 100% !important;
    max-width: none !important;
    object-fit: cover !important;
    object-position: center !important;
  }
</style>
