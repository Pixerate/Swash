import node from '@apphosting/astro-adapter';
import { defineConfig } from 'astro/config';
import svelte from '@astrojs/svelte';

// SITE_URL overrides the address while the custom domain is still being verified (GOTCHAS.md).
export default defineConfig({
  site: process.env.SITE_URL || 'https://swash.pixerate.com',
  output: 'server',
  adapter: node({ mode: 'standalone' }),
  integrations: [svelte()],
});
