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
      sidebar: [
        { label: 'Install', slug: 'install' },
        { label: 'Use', slug: 'use' },
        { label: 'Redaction', slug: 'redaction' },
        { label: 'Ledger', slug: 'ledger' },
        { label: 'Video', slug: 'video' },
        { label: 'PDF', slug: 'pdf' },
        { label: 'Claude Code', slug: 'claude-code' },
        {
          label: 'Research',
          items: [
            { label: 'Video frames', slug: 'research/video-frames' },
            { label: 'Structured output', slug: 'research/structured-output' },
            { label: 'PDF pipeline', slug: 'research/pdf-pipeline' },
            { label: 'No LLM in the pipeline', slug: 'research/no-llm' },
          ],
        },
        { label: 'Credits', slug: 'credits' },
      ],
      plugins: [
        lucode({
          navLinks: [
            { label: 'Install', link: '/install/' },
            { label: 'Use', link: '/use/' },
            { label: 'Credits', link: '/credits/' },
          ],
          footerText: '© 2026 Ryan Ilano. MIT. [Source](https://github.com/all-caps-dev/cheapshot).',
        }),
      ],
    }),
  ],
});
