# Licensing code assets

- `licensing-animated.svg` — animated, error correction level H, 96px square
  reserved in the centre for a logo. Drop artwork inside that box only.
- `licensing.png` — static fallback.

## Rules if you edit the SVG

1. **Never use `animation-fill-mode: both`.** It makes every module adopt the
   keyframe's `from` state (`opacity: 0`) in any renderer that does not run
   animations. Quick Look, PDF export, print and image proxies then show a
   blank white square instead of a code. Verified: with `both`, a Quick Look
   render came out 0% dark pixels.
2. Keep the `fill` attribute on every rect. GitHub sanitizes `<style>` out of
   inline SVG, and the attribute is what keeps it a valid code there.
3. The wave animation may lighten modules to `#454a57` and no further. That
   holds contrast above 7:1 on white, so every frame still scans.
4. Re-verify after any change by rendering and decoding, not by eye:
   `qlmanage -t -s 800 -o /tmp/out file.svg` then decode the PNG.
