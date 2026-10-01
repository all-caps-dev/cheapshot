import { defineCollection } from 'astro:content';
import { docsLoader, i18nLoader } from '@astrojs/starlight/loaders';
import { docsSchema, i18nSchema } from '@astrojs/starlight/schema';
import { ExtendDocsSchema } from 'lucode-starlight/schema';

export const collections = {
  docs: defineCollection({
    loader: docsLoader(),
    // lucode-starlight's theme hero fields; without this it warns and drops them.
    schema: docsSchema({ extend: ExtendDocsSchema }),
  }),
  // UI strings Starlight cannot find on its own. zh-Hans.json is a copy of
  // Starlight's built-in zh-CN strings (MIT): Starlight 0.42 looks its built-in
  // strings up by language tag and turns "zh-Hans" into "zhns" while trying to
  // drop a region code, so without this file Chinese pages get English UI.
  i18n: defineCollection({ loader: i18nLoader(), schema: i18nSchema() }),
};
