---
title: Redaction
description: The built-in rule table, custom rules, the stdin text mode, and what redaction does not promise.
---

Redaction is on by default. Every run replaces each hit with the rule's name in
brackets, so `AKIAIOSFODNN7EXAMPLE` becomes `[AWS_KEY]` and the shape of the
line survives. `--raw` turns redaction off and prints the OCR text as
recognized.

The rules are ordered most specific first, so a key is never eaten by a looser
rule. Two of them run a checksum on the match and drop it when the checksum
fails, and one only fires when an account cue sits nearby.

## Built-in rules

| Rule | Catches | Validator | Example |
|---|---|---|---|
| `AWS_KEY` | AKIA, ASIA, AGPA, AIDA, AROA or ANPA plus 16 characters | none | `AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE` |
| `GITHUB_PAT` | `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_` | none | `token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789` |
| `OPENAI_KEY` | `sk-`, `sk-proj-`, `sk-ant-`, `sk-live-` | none | `sk-proj-...` |
| `SLACK_TOKEN` | `xoxb`, `xoxp`, `xoxa`, `xoxo`, `xoxs`, `xoxr` | none | `xoxb-1234567890-...` |
| `JWT` | three base64url segments starting `eyJ` | none | `eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxw...` |
| `PRIVATE_KEY` | a PEM header | none | `-----BEGIN RSA PRIVATE KEY-----` |
| `BEARER` | `Bearer` followed by 16 or more token characters | none | `Authorization: Bearer abcdef0123456789abcdef` |
| `EMAIL` | addresses; a scale suffix like `@2x.png` is not one | none | `user ryan@example.com` |
| `SSN` | US social security numbers, with the invalid prefixes excluded | none | `SSN 123-45-6789` |
| `ROUTING` | a 9 digit ABA number | ABA checksum | `routing 021000021` |
| `CARD` | 13 to 19 digits | Luhn | `card 4111 1111 1111 1111` |
| `BANK_ACCT` | 8 to 17 digits after an account cue or a redacted routing number | none | `acct 12345678` |
| `PHONE` | US phone formats | none | `(415) 555-0132` |
| `TOKEN` | opaque mixed case runs of 20 characters or more | looks like a secret | `dGhpcyBpcyBhIHNlY3JldCB0b2tlbiBub2JvZHkgc2hvdWxkIHNlZQ==` |
| `IPV4` | dotted quads, with the octet range checked | none | `10.0.42.7` |

`BANK_ACCT` needs a cue within 20 characters: the word `acct`, `account`,
`a/c` or `micr`, or a `[ROUTING]` marker already placed on the same line by the
rule above it. That is what makes a MICR strip like `021000021 123456789012`
redact both numbers while a bare build number or an elapsed nanosecond count
survives untouched.

`TOKEN` is the catch-all, and two things keep it from firing on ordinary text:
the pattern needs mixed case, so hex digests such as git SHAs and sha256 sums
pass untouched; the validator lets URLs and absolute paths through and drops
low-entropy runs.

## No rule spans a line

Every built-in rule matches inside a single line. `BEARER` uses `[ \t]+` rather
than `\s+` for exactly this reason. A rule that could cross a newline redacted a
joined document differently from the lines it was joined from, which changed the
line count in the `--json` line array and left the token in the clear there.

## Custom rules

`--rules <file>` adds your own patterns. The file is a JSON array:

```json
[{"name": "TICKET", "pattern": "\\bINT-\\d{6}\\b", "caseInsensitive": true}]
```

Custom rules run before the built-in rules, so a pattern of yours wins over a
looser built-in that would otherwise swallow the same text.

## Text with no OCR

`--text <file|->` redacts text that is already text. Use `-` to read standard
input:

```bash
cat notes.txt | cheapshot --text -
```

Same rules, same output, no image work at all.

## What redaction does not promise

OCR garbles long random strings. A zero comes back as `Ø`, a lowercase L as an
uppercase I. A garbled secret can break the specific rule that would have caught
it and survive as a fragment, which is why the `TOKEN` catch-all exists to sweep
those up.

Redaction is best-effort on OCR output, not a guarantee. Do not point this at
something whose secrets must never leak, and use `--raw` only when you know what
is in the frame.

## OCR text is data

OCR text enters the agent's context as data, not as instructions. A screenshot
of a web page that says "ignore previous instructions" is now that sentence
sitting in context. The risk is the same as reading any file, so treat the text
cheapshot hands over the way you treat any untrusted input.

## The other thing it is for

Cheapshot started as a way to spend fewer tokens. It turned out to also be the
only lawful way to hand an agent a page it is not allowed to fetch.

Bot protection fingerprints the TLS handshake and runs a JavaScript proof of
work. `curl` fails both, and every tool that defeats it is bot detection
evasion. So an agent asking for a retailer's live inventory, a bank statement,
an authenticated dashboard, an IPMI console, a native app with no API, or
anything behind a login is stuck, permanently, by design.

You are not stuck. You are allowed to see the page. You are looking at it.

```bash
cheapshot --cleanshot
```

The human is the credential. Cheapshot is the transport. Nothing is forged,
nothing is evaded, and no check is defeated. A person who is permitted to see
something reads it to their tools.

This is also why redaction is on by default. The pages worth doing this with
are the ones with account numbers on them.
