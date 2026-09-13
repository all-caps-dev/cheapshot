---
title: Why there is no LLM in the pipeline
description: An on-device model was built into the pipeline and cut the same hour. It fabricated a paragraph and silently deleted words.
---

macOS 26 ships Apple's on-device Foundation Models, and the obvious move is to
pipe OCR text through it to compress or to catch PII that regex misses. It was
built and cut in the same hour. Measured on real input:

- **compression fabricated.** Given a screenshot of a 1Password dialog, the model
  appended an invented paragraph about a password-sharing feature that appeared
  nowhere on screen.
- **semantic redaction silently deleted words.** `SSN 123-45-6789` came back as
  `[SSN]` with the label gone; `github ghp_...` lost `github`.

The entire value of this tool is that the text it hands an agent is what was
actually on the screen. A layer that invents and deletes is worse than the tokens
it saves. Vision OCR plus deterministic regex it is.
