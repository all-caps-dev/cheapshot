import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { i18nLoader } from '@astrojs/starlight/loaders';
import { docsSchema, i18nSchema } from '@astrojs/starlight/schema';
import { ExtendDocsSchema } from 'lucode-starlight/schema';
// Which languages are on is decided in ../i18n.mjs and nowhere else.
import { docsPattern } from '../i18n.mjs';

export const collections = {
  docs: defineCollection({
    // Starlight's docsLoader() is this same glob over src/content/docs/, but it
    // takes no pattern. We need one so the folder of a language that is not
    // switched on (say a half-done src/content/docs/es/) is left out; otherwise
    // Starlight would publish those files as English pages under /es/.
    loader: glob({ base: './src/content/docs', pattern: docsPattern() }),
    // lucode-starlight's theme hero fields; without this it warns and drops them.
    schema: docsSchema({ extend: ExtendDocsSchema }),
  }),
  // UI strings Starlight cannot find on its own. zh-Hans.json is a copy of
  // Starlight's built-in zh-CN strings (MIT): Starlight 0.42 looks its built-in
  // strings up by language tag and turns "zh-Hans" into "zhns" while trying to
  // drop a region code, so without this file Chinese pages get English UI.
  // It is only used when Chinese is on (or in an I18N_PREVIEW build).
  i18n: defineCollection({ loader: i18nLoader(), schema: i18nSchema() }),
};
