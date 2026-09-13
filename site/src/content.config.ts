import { defineCollection } from 'astro:content';
import { docsLoader } from '@astrojs/starlight/loaders';
import { docsSchema } from '@astrojs/starlight/schema';
import { ExtendDocsSchema } from 'lucode-starlight/schema';

export const collections = {
  docs: defineCollection({
    loader: docsLoader(),
    // lucode-starlight's theme hero fields; without this it warns and drops them.
    schema: docsSchema({ extend: ExtendDocsSchema }),
  }),
};
