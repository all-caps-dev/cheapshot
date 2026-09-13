#!/bin/sh
# WCAG 2.x contrast ratio for normal text. No dependencies beyond sh and awk.
#
# Usage: scripts/contrast-ratio.sh <fg> <bg>
#   where each colour is '#rgb', '#rrggbb', or 'oklch(L% C H)'.
#
# Prints:  <fg> on <bg>: <ratio> AA:pass|fail AAA:pass|fail
# Exits 1 when the pair fails AA for normal text (4.5:1), so it gates on its own.
#
# oklch is accepted because the docs theme defines its colours that way, and the
# contrast check reads them straight out of the built CSS rather than a hand-typed hex.
set -e
[ $# -eq 2 ] || { echo "usage: contrast-ratio.sh <fg> <bg>   (#rrggbb or 'oklch(L% C H)')" >&2; exit 2; }

awk -v A="$1" -v B="$2" '
function hex1(c) { return index("0123456789abcdef", tolower(c)) - 1 }

# "#rgb" or "#rrggbb" -> linear sRGB triple in g[1..3]
function parse_hex(s, g,   h, i, n, v) {
  h = tolower(substr(s, 2))
  if (length(h) == 3) { n = ""; for (i = 1; i <= 3; i++) n = n substr(h, i, 1) substr(h, i, 1); h = n }
  if (length(h) != 6) return 0
  for (i = 0; i < 3; i++) {
    v = hex1(substr(h, i*2+1, 1)) * 16 + hex1(substr(h, i*2+2, 1))
    g[i+1] = srgb_to_linear(v / 255)
  }
  return 1
}

function srgb_to_linear(c) { return (c <= 0.04045) ? c / 12.92 : ((c + 0.055) / 1.055) ^ 2.4 }
function linear_to_srgb(c) { return (c <= 0.0031308) ? 12.92 * c : 1.055 * (c ^ (1/2.4)) - 0.055 }
function clamp01(c) { return (c < 0) ? 0 : ((c > 1) ? 1 : c) }

# "oklch(L% C H)" -> linear sRGB triple in g[1..3]. Oklab -> LMS -> linear sRGB.
function parse_oklch(s, g,   body, n, f, L, C, H, pi, a, b, l_, m_, s_, l, m, sc) {
  body = s
  sub(/^[ \t]*[Oo][Kk][Ll][Cc][Hh][ \t]*\(/, "", body)
  sub(/\).*$/, "", body)
  gsub(/[,\/]/, " ", body)
  n = split(body, f, /[ \t]+/)
  if (n < 1) return 0
  L = f[1]; if (f[1] ~ /%/) { sub(/%/, "", f[1]); L = f[1] / 100 }
  C = (n >= 2) ? f[2] + 0 : 0
  H = (n >= 3) ? f[3] + 0 : 0
  pi = 3.14159265358979323846
  a = C * cos(H * pi / 180)
  b = C * sin(H * pi / 180)
  l_ = L + 0.3963377774 * a + 0.2158037573 * b
  m_ = L - 0.1055613458 * a - 0.0638541728 * b
  s_ = L - 0.0894841775 * a - 1.2914855480 * b
  l = l_ * l_ * l_; m = m_ * m_ * m_; sc = s_ * s_ * s_
  g[1] = clamp01( 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * sc)
  g[2] = clamp01(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * sc)
  g[3] = clamp01(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * sc)
  return 1
}

function parse(s, g) {
  if (s ~ /^#/) return parse_hex(s, g)
  if (s ~ /^[ \t]*[Oo][Kk][Ll][Cc][Hh][ \t]*\(/) return parse_oklch(s, g)
  return 0
}

function luminance(g) { return 0.2126 * g[1] + 0.7152 * g[2] + 0.0722 * g[3] }

BEGIN {
  if (!parse(A, ga)) { printf "contrast-ratio: cannot parse colour %s\n", A > "/dev/stderr"; exit 2 }
  if (!parse(B, gb)) { printf "contrast-ratio: cannot parse colour %s\n", B > "/dev/stderr"; exit 2 }
  la = luminance(ga); lb = luminance(gb)
  hi = (la > lb) ? la : lb
  lo = (la > lb) ? lb : la
  r = (hi + 0.05) / (lo + 0.05)
  printf "%s on %s: %.2f:1 AA:%s AAA:%s\n", A, B, r, (r >= 4.5 ? "pass" : "fail"), (r >= 7 ? "pass" : "fail")
  exit (r >= 4.5) ? 0 : 1
}
'
