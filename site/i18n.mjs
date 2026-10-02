// @ts-check
// Which languages the site publishes, decided in one place.
//
// The rule: nothing is published in a language until a human has approved it,
// and approval means the reviewed files are in the repo. So a language is
// switched on only when it is complete:
//   1. every English page in src/content/docs/ has a file at the same path
//      under src/content/docs/<locale>/ (.md or .mdx), and
//   2. src/i18n/ui/<locale>.json has a non-empty value for every key in
//      src/i18n/ui/en.json (sidebar labels, header links, footer).
// Until then the language is left out of the Starlight config entirely, so the
// build is the plain English site: no picker, no /es/ pages, no hreflang.
//
// I18N_PREVIEW=1 switches every configured language on for review, with
// Starlight's "not translated yet" fallback pages. It refuses to run in CI so a
// preview build can never be deployed.
//
// astro.config.mjs, src/content.config.ts and scripts/i18n-status.mjs all read
// from this file; nothing else decides whether a language is on.

import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, relative, sep } from 'node:path';

/**
 * One configured non-English language.
 * @typedef {object} Locale
 * @property {string} label  Name shown in the language picker, in that language.
 * @property {string} lang   BCP-47 tag. Starlight sidebar `translations` and the
 *                           lucode label maps are keyed by this, not by the folder name.
 * @property {'ltr' | 'rtl'} [dir]
 */

// Folder names are the keys: es -> src/content/docs/es/ and /cheapshot/es/.
// Chinese is tagged zh-Hans (Simplified script), matching ilano.fyi. Starlight
// 0.42 cannot map that tag to its built-in Chinese UI strings, so they are
// supplied in src/content/i18n/zh-Hans.json.
/** @type {Record<string, Locale>} */
export const LOCALES = {
  es: { label: 'Español', lang: 'es' },
  ar: { label: 'العربية', lang: 'ar', dir: 'rtl' },
  zh: { label: '简体中文', lang: 'zh-Hans' },
};

/** English stays at the root (/cheapshot/install/). */
export const ROOT_LOCALE = { label: 'English', lang: 'en' };

// Paths are worked out from this file's location, so the module behaves the
// same whether Astro or `node scripts/i18n-status.mjs` loads it, from any cwd.
const SITE_DIR = fileURLToPath(new URL('.', import.meta.url));
const DOCS_DIR = join(SITE_DIR, 'src', 'content', 'docs');
const UI_DIR = join(SITE_DIR, 'src', 'i18n', 'ui');

const DOC_EXTENSIONS = ['.md', '.mdx'];

/**
 * Doc paths under `dir`, relative to it, without extension: "research/no-llm".
 * Files starting with "_" are skipped because Starlight's loader skips them too.
 * @param {string} dir
 * @param {string[]} skipTopFolders  top-level folders to leave out (the locale folders)
 * @returns {string[]}
 */
function listDocs(dir, skipTopFolders = []) {
  if (!existsSync(dir)) return [];
  /** @type {string[]} */
  const found = [];
  /** @param {string} current */
  const walk = (current) => {
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      const full = join(current, entry.name);
      if (entry.isDirectory()) {
        if (current === dir && skipTopFolders.includes(entry.name)) continue;
        walk(full);
      } else if (!entry.name.startsWith('_')) {
        const ext = DOC_EXTENSIONS.find((e) => entry.name.endsWith(e));
        // Normalise to "/" so the paths compare the same on every OS.
        if (ext) found.push(relative(dir, full).slice(0, -ext.length).split(sep).join('/'));
      }
    }
  };
  walk(dir);
  return found.sort();
}

/**
 * Read one UI strings file. A missing file is an empty set of strings.
 * @param {string} name  "en", "es", ...
 * @returns {Record<string, string>}
 */
export function readUi(name) {
  const file = join(UI_DIR, `${name}.json`);
  if (!existsSync(file)) return {};
  return JSON.parse(readFileSync(file, 'utf8'));
}

/** The English UI strings: the full list of keys every language must cover. */
export const EN = readUi('en');

/**
 * How far along one language is. Used by the build and by `npm run i18n:status`.
 * @param {string} key  locale folder name, e.g. "es"
 */
export function localeStatus(key) {
  const english = listDocs(DOCS_DIR, Object.keys(LOCALES));
  const translated = new Set(listDocs(join(DOCS_DIR, key)));
  const missingDocs = english.filter((p) => !translated.has(p));

  const ui = readUi(key);
  // An empty string counts as untranslated, so a translator can hand in a
  // file with blanks and it will not switch the language on.
  const missingUi = Object.keys(EN).filter((k) => typeof ui[k] !== 'string' || ui[k].trim() === '');

  const complete = english.length > 0 && missingDocs.length === 0 && missingUi.length === 0;

  let reason = 'complete: every page and every UI string is translated';
  if (!complete) {
    /** @type {string[]} */
    const gaps = [];
    if (missingDocs.length) {
      gaps.push(`${missingDocs.length} page(s) missing, first: src/content/docs/${key}/${missingDocs[0]}.md`);
    }
    if (missingUi.length) {
      gaps.push(
        existsSync(join(UI_DIR, `${key}.json`))
          ? `${missingUi.length} UI string(s) missing, first: "${missingUi[0]}"`
          : `no src/i18n/ui/${key}.json`
      );
    }
    reason = gaps.join('; ');
  }

  return {
    key,
    complete,
    docs: { done: english.length - missingDocs.length, total: english.length, missing: missingDocs },
    ui: { done: Object.keys(EN).length - missingUi.length, total: Object.keys(EN).length, missing: missingUi },
    reason,
  };
}

/**
 * Is this a review build? Throws in CI so a preview can never reach Pages
 * (the Pages workflow runs on GitHub Actions, which always sets CI and GITHUB_ACTIONS).
 * @param {NodeJS.ProcessEnv} env
 */
function isPreview(env) {
  if (env.I18N_PREVIEW !== '1') return false;
  if (env.CI || env.GITHUB_ACTIONS) {
    throw new Error(
      'I18N_PREVIEW=1 is set in CI. Preview builds publish untranslated pages and must never be deployed. Unset I18N_PREVIEW.'
    );
  }
  // Astro loads this module more than once per build (config, then content),
  // so remember on globalThis that the warning was already printed.
  const g = /** @type {{ __i18nPreviewWarned?: boolean }} */ (globalThis);
  if (!g.__i18nPreviewWarned) {
    g.__i18nPreviewWarned = true;
    const line = '!'.repeat(72);
    console.warn(
      `\n${line}\n!! I18N_PREVIEW=1: every language is on, untranslated pages included.\n!! This build is NOT DEPLOYABLE. Review only.\n${line}\n`
    );
  }
  return true;
}

export const PREVIEW = isPreview(process.env);

/** Folder names of the languages this build publishes. Empty means English only. */
export const ENABLED = Object.keys(LOCALES).filter((key) => PREVIEW || localeStatus(key).complete);

// ---------------------------------------------------------------------------
// Helpers for astro.config.mjs and src/content.config.ts. They only ever look
// at ENABLED, so a language that is off leaves no trace in the config.

/**
 * Starlight `defaultLocale` + `locales`, or nothing at all when only English is
 * on. Passing nothing (rather than a lone root locale) keeps the build
 * identical to the site before languages existed.
 */
export function starlightLocaleConfig() {
  if (ENABLED.length === 0) return {};
  return {
    defaultLocale: 'root',
    locales: {
      root: ROOT_LOCALE,
      ...Object.fromEntries(ENABLED.map((key) => [key, LOCALES[key]])),
    },
  };
}

/**
 * Translations of one UI key for the enabled languages, keyed by BCP-47 tag.
 * In preview a missing string is left out, so that label falls back to English.
 * @param {string} key
 * @returns {Record<string, string>}
 */
function translationsOf(key) {
  /** @type {Record<string, string>} */
  const out = {};
  for (const locale of ENABLED) {
    const value = readUi(locale)[key];
    if (typeof value === 'string' && value.trim() !== '') out[LOCALES[locale].lang] = value;
  }
  return out;
}

/**
 * English text for a UI key. A typo in a key fails the build instead of
 * rendering a blank label.
 * @param {string} key
 */
export function en(key) {
  const value = EN[key];
  if (typeof value !== 'string') throw new Error(`src/i18n/ui/en.json has no key "${key}"`);
  return value;
}

/**
 * `{ label, translations }` for a Starlight sidebar item or a lucode nav link.
 * @param {string} key
 */
export function label(key) {
  return { label: en(key), translations: translationsOf(key) };
}

/**
 * A plain string when only English is on, otherwise a map keyed by BCP-47 tag
 * (the shape lucode's `footerText` takes).
 * @param {string} key
 * @returns {string | Record<string, string>}
 */
export function localized(key) {
  const others = translationsOf(key);
  if (Object.keys(others).length === 0) return en(key);
  return { [ROOT_LOCALE.lang]: en(key), ...others };
}

/**
 * Glob for the docs collection. A language that is off has its folder
 * excluded, so a half-translated src/content/docs/es/ cannot leak out as
 * English-site pages at /es/... .
 * @returns {string[]}
 */
export function docsPattern() {
  const off = Object.keys(LOCALES).filter((key) => !ENABLED.includes(key));
  // Same pattern as Starlight's own docsLoader (0.42), plus one "!" exclusion per language that is off.
  return ['**/[^_]*.{markdown,mdown,mkdn,mkd,mdwn,md,mdx}', ...off.map((key) => `!${key}/**`)];
}
