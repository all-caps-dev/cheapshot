---
title: 'Video frame extraction: ffmpeg skill review and AVFoundation path (Opus research agent, 2026-09-12)'
description: 'How video frames get chosen: the ffmpeg skill review, the AVFoundation path, and the -fps_mode vfr bug.'
---

Research note from 2026-09-12, kept as written.

Decision taken from this report lives in docs/superpowers/specs/2026-09-12-two-products-one-engine-design.md, "Video". The `-fps_mode vfr` bug below was found by Fable when verifying the agent's timestamp claim, which turned out to be wrong; the verification is in the spec.

## Local skill findings

`~/.claude/skills/ffmpeg/SKILL.md` (195 lines) wraps `~/local-dev/ffmpeg-skill/scripts/fftools.py` (SKILL.md:12-16). Grepping SKILL.md, ffmpeg.md, README.md, and fftools.py for `scene|mpdecimate|freeze|showinfo|skip_frame|nokey|keyframe|crop` returns zero hits. It covers:

- Fixed-interval sampling: `thumbnails --count 10` (SKILL.md:52-53), N separate `ffmpeg -ss T -vframes 1 -q:v 2` runs (fftools.py:224-246).
- Frame-rate decimation by count: `frames --every 30` (SKILL.md:74-76) -> `select=not(mod(n\,30))` (fftools.py:372).
- ffprobe wrapped as `info` (SKILL.md:23-24; fftools.py:32). "Always start by getting file info" (SKILL.md:95-100).

No scene detection, mpdecimate, freezedetect, thumbnail filter, keyframe-only decode, showinfo, crop, or fps=. The skill recommends nothing cheapshot lacks; cheapshot's `select=gt(scene,...)` is ahead of it. Two transferable items: probe first, and write JPEG `-q:v 2` rather than PNG.

## Apply to cheapshot (cheapshot.swift:166-211, filter at line 177)

1. Decimate before scoring: `fps=4,mpdecimate=hi=64*12:lo=64*5:frac=0.1,select=eq(n\,0)+gt(scene\,THRESH),metadata=print:file=-`. `fps=4` cuts filter work about 15x on 60 fps captures; mpdecimate kills static stretches before the scene metric runs. Threshold needs recalibration.
2. Add `-an -sn` (line 176).
3. PNG -> JPEG `-q:v 2` (line 179). Vision OCR unaffected.
4. Probe first with ffprobe; derive `fps=` and `maxFrames` instead of the hardcoded 200.
5. Optional `crop=w:h:x:y` as `--region`.

Agent claimed a timestamp misalignment at lines 197-209 (frame 0 carrying no `lavfi.scene_score`). Verified false: `metadata=print` emits `frame:0 ... pts_time:0` with `lavfi.scene_score=0.000000`. The real bug is the missing `-fps_mode vfr`, see the spec.

## AVFoundation recommendation

AVAssetImageGenerator at a fixed interval plus `VNGenerateImageFeaturePrintRequest` distance.

- Sample at 2 to 4 Hz via `images(for:)` (AsyncSequence, macOS 13+). Set `requestedTimeToleranceBefore/After` to about half the interval; `.zero` forces exact-frame decode and re-seeks.
- Feature-print each frame, drop when `computeDistance(to:)` falls under threshold. `VNGenerateImageFeaturePrintRequest` is macOS 10.15+. The Swift-native `GenerateImageFeaturePrintRequest` is macOS 15+, so use the VN class for a 13 floor.
- Rough cost, 1 min of 1080p at 2 Hz: about 120 frames, generation 1 to 2 s, feature prints 10 to 20 ms per frame on Apple Silicon. Call it 3 to 4 s per video-minute, against 100 to 200 ms per frame for Vision OCR.

Rejected: AVAssetReader keyframe-only (ScreenCaptureKit GOPs run 10 s+ or are all-intra; keyframe cadence is an encoder artifact). CoreImage histogram difference (typing in a terminal barely moves a global histogram).

## ffmpeg-skill repo check

`github.com/MastroMimmo/ffmpeg-skill` is the skill already installed (`~/local-dev/ffmpeg-skill` has it as origin). Adds nothing. `fabriqaai/ffmpeg-analyse-video-skill` (frames plus AI vision to timestamped summaries) is adjacent prior art.

## Open questions

1. `mpdecimate` plus `scene` threshold need tuning against real agent recordings; they interact.
2. FrameSource is image-typed (decided in the spec); the ffmpeg adapter round-trips through a temp dir it owns.

Sources: https://github.com/MastroMimmo/ffmpeg-skill, https://github.com/fabriqaai/ffmpeg-analyse-video-skill, https://developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequest, https://developer.apple.com/documentation/avfoundation/avassetimagegenerator
