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
      // English stays at the root (/cheapshot/install/); other languages get a
      // folder (/cheapshot/es/install/). A page with no translation yet is shown
      // in English with Starlight's "not translated yet" notice.
      // Chinese is tagged zh-Hans (Simplified script), matching ilano.fyi. Starlight
      // 0.42 cannot map that tag to its built-in Chinese UI strings, so they are
      // supplied in src/content/i18n/zh-Hans.json.
      defaultLocale: 'root',
      locales: {
        root: { label: 'English', lang: 'en' },
        es: { label: 'Español' },
        ar: { label: 'العربية', dir: 'rtl' },
        zh: { label: '简体中文', lang: 'zh-Hans' },
      },
      sidebar: [
        { label: 'Install', slug: 'install' },
        { label: 'Use', slug: 'use' },
        { label: 'Redaction', slug: 'redaction' },
        { label: 'Ledger', slug: 'ledger' },
        { label: 'Video', slug: 'video' },
        { label: 'PDF', slug: 'pdf' },
        { label: 'Save a PDF with Docling', slug: 'docling' },
        { label: 'Claude Code', slug: 'claude-code' },
        { label: 'MCP', slug: 'mcp' },
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
