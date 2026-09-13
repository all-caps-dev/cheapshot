---
title: Video
description: Screen recordings to a timestamped transcript, the ffmpeg filter chain, and the three tuning flags.
---

`--video` is the same idea aimed at screen recordings. Agents normally read a
video by sampling frames and sending each one as an image, which costs thousands
of tokens per frame. Cheapshot instead asks ffmpeg for only the frames where the
screen actually changed, OCRs those locally, drops any screen nearly identical
to the one before it, and emits a timestamped transcript.

```bash
cheapshot --video screen.mp4
```

Measured on a 13 minute, 2.9 GB screen recording at 2560x1440: 12 scene frames,
22,128 image tokens to 1,091 text tokens, 95% saved.

## The transcript

Plain output is one stamped block per distinct screen:

```
[00:00]
cheapshot --video demo.mp4

[00:14]
12 scene frames, 9 distinct screens
```

The stamp is `mm:ss`. With `--json` each segment carries `time` in seconds,
`stamp`, and `text`, alongside the frame count and the redaction counts for the
whole recording.

## The ffmpeg filter chain

```
-an -sn -vf "fps=4,mpdecimate=hi=64*12:lo=64*5:frac=0.1,select=eq(n\,0)+gt(scene\,T),metadata=print:file=-" -fps_mode vfr -q:v 2 f_%05d.jpg
```

`fps=4` cuts filter work by about 15 times on a 60 fps capture. `mpdecimate`
drops static stretches before the scene metric runs, so a screen that sat still
for two minutes costs nothing. `select` keeps frame 0 plus every frame whose
scene score is over the threshold, and `metadata=print` writes the timestamps to
standard output so they line up with the files.

`-fps_mode vfr` is load bearing. The image2 muxer writes at a constant frame
rate by default, so every input frame became a file even though `select` passed
only a few. Because `--max-frames` capped files rather than kept frames, a
recording longer than a few seconds was silently truncated and the timestamps
after the first few frames fell back to the file index. With `-fps_mode vfr` only
changed frames are written, so `--max-frames` counts kept frames, not input
frames.

## Tuning

```bash
cheapshot --video screen.mp4 --scene 0.2 --max-frames 400 --dedupe 0.95
```

`--scene <f>` is the change threshold that decides when a new frame is worth
reading. Default 0.25. Lower it to catch smaller changes, raise it to keep only
big ones.

`--max-frames <n>` caps how many frames a recording contributes. Default 200.

`--dedupe <f>` drops a screen that is at least this similar to the one before it,
measured on the recognized text rather than the pixels. Default 0.90.

## Requirements

Requires ffmpeg on your PATH. Cheapshot uses whichever one you have.

```bash
brew install ffmpeg
```
