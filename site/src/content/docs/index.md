---
title: Apple Vision OCR and secret redaction for coding agents
description: Read screenshots, screen recordings and PDFs on your own Mac with Apple's Vision framework. cheapshot gives a coding agent the words instead of the pixels, redacts secrets before they reach the model, and counts the image tokens it saved.
template: splash
hero:
  title: 'cheapshot: Apple Vision OCR, redaction, and token savings on any Mac running macOS 13 or later'
  tagline: Give your coding agent the words on your screen, not the pixels. On-device OCR that redacts secrets first and shows you the tokens it saved.
  actions:
    - text: Install
      link: /cheapshot/install/
      icon: right-arrow
    - text: Source on GitHub
      link: https://github.com/all-caps-dev/cheapshot
      icon: external
      variant: minimal
---

cheapshot reads screenshots, screen recordings, and PDFs with Apple's Vision framework, redacts secrets before the text leaves your Mac, and keeps a ledger of the image tokens your agent did not have to pay for. No model in the loop. MIT. Phase 3 adds a Claude Code plugin and an MCP server.

An image costs roughly `(width x height) / 750` tokens, and it stays in the conversation, riding along on every later turn. The words are usually all the agent needed.

Measured on real runs, one of each kind:

| Input | Image tokens | Text tokens | Saved |
|---|---:|---:|---:|
| A screenshot | 1,018 | 37 | **96%** |
| A 36 frame screen recording | 66,384 | 1,005 | **98%** |
| A PDF page | 2,317 | 601 | **74%** |

A recording wins biggest because it is thousands of frames of mostly unchanged screen, and a PDF wins least because a page of prose is genuinely a lot of words. Those three are median runs, not best cases.

Over ten days of real use on one Mac: **2,039 runs, 69,389 images, PDF pages and video frames read on-device, 119,284,980 tokens never sent.** Video is 98.9% of that saving, so read `cheapshot --ledger --by-mode` before treating any total as money: a screenshot is spend you would really have paid, a video frame is one of thousands nobody was going to upload one at a time.
