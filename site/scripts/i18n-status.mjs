// @ts-check
// npm run i18n:status
// One line per language: is it on, how many pages and UI strings are
// translated, and why it is (or is not) on. The decision itself is made in
// ../i18n.mjs; this script only reports it.
//
// --disabled prints just the folder names of the languages that are off, one
// per line, for scripts/check-site.sh to skip.

import { LOCALES, ENABLED, PREVIEW, localeStatus } from '../i18n.mjs';

if (process.argv.includes('--disabled')) {
  for (const key of Object.keys(LOCALES)) if (!ENABLED.includes(key)) console.log(key);
  process.exit(0);
}

if (PREVIEW) console.log('I18N_PREVIEW=1: every language is on for review; the counts below are what a real build would see.\n');

for (const key of Object.keys(LOCALES)) {
  const s = localeStatus(key);
  // "preview" means on only because of I18N_PREVIEW; a real build leaves it off.
  const on = !ENABLED.includes(key) ? 'disabled' : s.complete ? 'enabled ' : 'preview ';
  // padEnd keeps the columns lined up in a terminal.
  console.log(
    `${key.padEnd(3)} ${LOCALES[key].lang.padEnd(8)} ${on}  docs ${s.docs.done}/${s.docs.total}  ui ${s.ui.done}/${s.ui.total}  ${s.reason}`
  );
}
