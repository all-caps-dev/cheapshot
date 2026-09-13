// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import lucode from 'lucode-starlight';

// GitHub Pages project site: origin + repo name. `base` stays at the top level.
export default defineConfig({
  site: 'https://all-caps-dev.github.io',
  base: '/cheapshot/',
  integrations: [
    starlight({
      title: 'cheapshot',
      description: 'On-device OCR for coding agents: the words on your screen, not the pixels, with secrets redacted first.',
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/all-caps-dev/cheapshot' }],
      // Task 6 adds redaction, ledger, video, pdf, research/*, credits.
      sidebar: [
        { label: 'Install', slug: 'install' },
        { label: 'Use', slug: 'use' },
      ],
      plugins: [
        lucode({
          navLinks: [
            { label: 'Install', link: '/install/' },
            { label: 'Use', link: '/use/' },
          ],
          footerText: '© 2026 Ryan Ilano. MIT. [Source](https://github.com/all-caps-dev/cheapshot).',
        }),
      ],
    }),
  ],
});
