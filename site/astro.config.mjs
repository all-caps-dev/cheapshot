// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import lucode from 'lucode-starlight';
// Languages: which are on, and their UI strings. See i18n.mjs for the rule.
import { starlightLocaleConfig, label, localized } from './i18n.mjs';

// GitHub Pages project site: origin + repo name. `base` stays at the top level.
export default defineConfig({
  site: 'https://all-caps-dev.github.io',
  base: '/cheapshot/',
  integrations: [
    starlight({
      // The title is the product name and the description is a plain string in
      // Starlight 0.42 (it cannot be localized), so both stay English here.
      title: 'cheapshot',
      customCss: ['./src/styles/custom.css'],
      // Ours must be listed here, not left to the theme: a user override wins over the plugin's.
      components: {
        MarkdownContent: './src/components/MarkdownContent.astro',
      },
      description: 'On-device OCR for coding agents: the words on your screen, not the pixels, with secrets redacted first.',
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/all-caps-dev/cheapshot' }],
      // English stays at the root (/cheapshot/install/). A language only gets
      // a folder (/cheapshot/es/install/) once i18n.mjs finds it complete; with
      // none complete this adds nothing and the site is monolingual English.
      ...starlightLocaleConfig(),
      // Labels live in src/i18n/ui/en.json; label() adds the translations from
      // src/i18n/ui/<locale>.json for each language that is on.
      sidebar: [
        { ...label('sidebar.install'), slug: 'install' },
        { ...label('sidebar.use'), slug: 'use' },
        { ...label('sidebar.redaction'), slug: 'redaction' },
        { ...label('sidebar.ledger'), slug: 'ledger' },
        { ...label('sidebar.video'), slug: 'video' },
        { ...label('sidebar.pdf'), slug: 'pdf' },
        { ...label('sidebar.docling'), slug: 'docling' },
        { ...label('sidebar.claude-code'), slug: 'claude-code' },
        { ...label('sidebar.mcp'), slug: 'mcp' },
        {
          ...label('sidebar.research'),
          items: [
            { ...label('sidebar.research.video-frames'), slug: 'research/video-frames' },
            { ...label('sidebar.research.structured-output'), slug: 'research/structured-output' },
            { ...label('sidebar.research.pdf-pipeline'), slug: 'research/pdf-pipeline' },
            { ...label('sidebar.research.no-llm'), slug: 'research/no-llm' },
          ],
        },
        { ...label('sidebar.credits'), slug: 'credits' },
      ],
      plugins: [
        lucode({
          navLinks: [
            { ...label('nav.install'), link: '/install/' },
            { ...label('nav.use'), link: '/use/' },
            { ...label('nav.credits'), link: '/credits/' },
          ],
          footerText: localized('footer'),
        }),
      ],
    }),
  ],
});
