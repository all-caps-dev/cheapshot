# Changelog

Notable changes to the cheapshot binary, the Claude Code plugin and cheapshot-mcp. Versions follow semver. Dates are UTC.

## Unreleased

### Clipboard

- New `cheapshot --clipboard` (NOV-155): reads the one file copied in Finder (image or PDF), else the image on the clipboard (PNG, TIFF, JPEG or HEIC), and prints the redacted text with the same text, counts, JSON and ledger line as a file read. In `--json` the entry has `"file": "clipboard"` and `"source": "image"` or `"file_url"`; a copied PDF puts its hash and page count under `"document"`, never its path. Clipboard text is never read (use `pbpaste | cheapshot --text -`), the clipboard is never written, and `--raw`, files, `--pages` and the other input modes are usage errors with it. Blank text is a failure, stricter than a file read: exit 1, or the new exit 3 when a screenshot-like image is still blank after the retry (likely a cold start). macOS only.
- New `--clipboard-out` with `--clipboard` (CHE-86, CHE-87): puts the result back as the clipboard's only item, the same type as the input. An image (copied bytes or a copied image file) goes back as a masked PNG from the same masker as `cheapshot mask` (redacted and low-confidence lines painted black, metadata chunks dropped); a copied PDF goes back as its redacted text. Nothing is written when the read fails or is blank, when the clipboard changed during the read (exit 1), or when a safe masked copy cannot be proven (exit 3). `--min-conf` can only raise the floor with it. Clipboard history tools and Universal Clipboard may still hold the original.

### Mask

- `cheapshot mask` writes its copy with mode 0600, in the default folder and at `--out` alike (CS-18). An `--out` file used to get the umask default, usually 0644, so a script or another account that read it from there will now get a permission error. Each run without `--out` deletes copies in the default folder older than 1 hour. Mask now refuses to run when `$TMPDIR/cheapshot-masked/` is a symlink, not a folder, owned by another user, or not mode 0700; the error gives the `chmod` that fixes it.

### Claude Code hook

- The Claude Code hook honours `ocr_status` and `retried` (NOV-160). An image with no text is passed as pixels only when the binary reports `"empty"` without a retry, with text `""` and `screenshot_like` false or absent (a photo or small image). A screenshot still empty after the retry, a missing or malformed status, and any empty image from a binary that does not report `ocr_status` (builds before v0.6.0's cold-start retry, including dev builds that call themselves 0.6.0) are denied in every mode, with `cheapshot allow` and `cheapshot mask` named to the user only. Text found after a retry is returned with a note that some lines may be missing. PDFs are unchanged.
- The Claude Code hook fails closed on images in default mode too. A failed OCR run on an image (missing binary, non-zero exit, empty, truncated or non-JSON output, results not an array) denies the Read, as strict mode already did; the user message says how to fix the install or use `cheapshot allow` (or `CHEAPSHOT_PASSTHROUGH=1` when the binary is missing), and the model's reason names neither. A missing `jq` also denies an image Read in every mode (without `jq` the file type comes from the extension in the raw request), and a path starting with `-` is no longer passed as pixels: the hook hands it to the binary after `--`, and the commands it prints for the user spell such a path absolute, which a `cheapshot allow` entry then matches. In default mode an image that does not exist (the binary says `no such file` and there is no file) is let through so the Read reports the missing file; one that exists but will not decode stays denied. PDFs and a PDF over 20 pages keep the old default.

## 0.6.0 (2026-11-26)

Security hardening from Fleet #290 and a larger redaction rule set from Fleet #319. Ships with cheapshot-mcp 0.1.3 and plugin 0.1.1. PRs [#15](https://github.com/all-caps-dev/cheapshot/pull/15) and [#16](https://github.com/all-caps-dev/cheapshot/pull/16).

### Security

- Flag injection fixed. A path such as `--raw` passed to `cheapshot_ocr` could switch redaction off and read any text file the user can read. cheapshot-mcp now refuses any path, `newest.dir` or video path that starts with `-`, and the binary treats `--` as the end of options (`cheapshot [options] -- <file> ...`). Help and version are only read before `--`.
- Raw needs a person. cheapshot-mcp refuses `raw: true` unless `CHEAPSHOT_ALLOW_RAW=1` is in the server's environment. The hook's deny reason no longer tells the model to run `cheapshot allow`; the command goes to the user in a systemMessage, shell-quoted.
- `cheapshot allow` needs a terminal. It refuses to run unless stdin and stdout are a terminal and it holds the foreground process group, so `allow < /dev/tty` from an agent's shell is refused. This is a speed bump, not a sandbox.
- Strict hook mode. `CHEAPSHOT_STRICT=1` makes the Claude Code hook deny on every failure, including a missing jq and a path that starts with `-`. Default mode still fails open, and now says so in a systemMessage instead of stderr only.
- The plugin pins an exact cheapshot-mcp version, and `scripts/check-plugin.sh` fails when the pin, the marketplace version and the plugin version disagree.

### Redaction

- 24 new rules. Provider keys: ANTHROPIC_KEY (its own label; `sk-ant-` used to report as OPENAI_KEY), GITLAB_PAT, STRIPE_KEY, SLACK_WEBHOOK, DISCORD_WEBHOOK, NPM_TOKEN, PYPI_TOKEN, HF_TOKEN, TAILSCALE_KEY, ONEPASSWORD_TOKEN, ONEPASSWORD_SECRET_KEY, OP_REF, GOOGLE_API_KEY, GOOGLE_OAUTH_SECRET, TWILIO_KEY, AZURE_CLIENT_SECRET, VAULT_TOKEN. Credentials in context: URL_CREDS, BASIC_AUTH, SECRET (the value after `password=`, `api_key:` and similar, with placeholders and code references left alone). Other: PRODUCT_KEY, IBAN (mod-97 checked), international PHONE (E.164 digit count), PGP private key block. Wider AWS_KEY, OPENAI_KEY and SLACK_TOKEN prefixes.
- Built-in rules run in linear time. A 100,000-character line redacts in well under a second.
- Post-merge review fixes. TOKEN catches 20 to 31 character mixed-case secrets (about 91%, was 0 to 18%) with a length-scaled entropy bar and shape checks that keep identifiers, filenames and versions out. URL_CREDS takes an empty username (`redis://:pw@host`). JWT and URL_CREDS were quadratic on adversarial lines (16 s at 100,000 characters) and now take about 0.1 s. SECRET catches `--password X`, `-p X` after sshpass, docker/podman login and mysql (`-pX`), `curl -u user:pass`, aligned gaps of up to 40 spaces or tabs, a tab separator, and `Authorization: token <value>`. Every value on a `Cookie:` line and the first on a `Set-Cookie:` line is redacted, URL-encoded tails included. Fewer false positives: `response.data.token`, `142/150`, `viewBox="0 0 24 24"` (IPV4) and `sk-` CSS classes (OPENAI_KEY) stay as written.
- Rules lookup. Extra rules come from `--rules`, then `$CHEAPSHOT_RULES`, then `rules.json` next to the ledger. A named rules file that is missing or broken fails the run; a broken default `rules.json` is skipped with a warning and the built-in redaction stays on.

### OCR

- Cold-start retry. On some cold starts (macOS `aned` compiling Vision's models twice under contention) the accurate recognizer returned no lines, or dropped lines, with exit 0, and callers took the empty text for a photo and sent the pixels. A screenshot-like image (at least 200 x 200 px and mostly flat colour) that reads as empty, or a cold pass (over 3 s) that comes back under 85% of a fast-recognizer line count, is now OCR'd once more in the same process, where the models are already compiled. Each image result in `--json` carries `"ocr_status": "ok" | "empty"`, `"retried"` and `"screenshot_like"`; `"empty"` with `"retried": true` means a screenshot that still read blank, not a photo, and stderr says so. The fast recognizer is only counted, never output, since it misreads IPs past redaction.

### Ledger

- Each line gains `raw` (true on `--raw` runs) and `passthrough_reason`.
- The hook records each pass-through with `cheapshot --note-passthrough`. `--ledger` reports `raw_runs` and `passthroughs` and keeps pass-through lines out of the savings.

## 0.5.0 (2026-11-04)

First public release: universal binary signed with Developer ID and notarized, Homebrew tap `all-caps-dev/tap/cheapshot`.
