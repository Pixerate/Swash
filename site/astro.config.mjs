import node from '@apphosting/astro-adapter';
import { defineConfig } from 'astro/config';
import svelte from '@astrojs/svelte';
import tailwindcss from '@tailwindcss/vite';

// SITE_URL overrides the address while the custom domain is still being verified (GOTCHAS.md).
export default defineConfig({
  site: process.env.SITE_URL || 'https://swash.pixerate.com',
  output: 'server',
  adapter: node({ mode: 'standalone' }),
  integrations: [svelte()],
  // Tailwind 4 through its Vite plugin (global.css imports it and loads tailwind.config.mjs)
  vite: { plugins: [tailwindcss()] },
});
