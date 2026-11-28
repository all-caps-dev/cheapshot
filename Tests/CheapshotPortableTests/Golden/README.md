# Golden redaction cases

Each `cases/NN-name.txt` is fed to the redactor and the result is compared with
`expected/NN-name.txt` by `GoldenTests.swift`.

## The join marker `⟦⟧`

Some cases hold fake but realistic secrets (Stripe, Slack, GitLab, 1Password and
similar). Committed whole, they trip secret scanners such as gitleaks and GitHub
push protection. So inside each such token the input file carries the marker
`⟦⟧` (U+27E6 U+27E7), for example `sk_li⟦⟧ve_...` or `hooks.sl⟦⟧ack.com`.

- The test loader deletes every `⟦⟧` from an input before redacting, so the
  redactor always sees the full realistic string.
- `expected/` files never contain the marker; they hold the redacted output.
- `testJoinMarkerIsStripped` checks that a marked case fails with the marker
  left in and passes once it is removed.

When adding a case with a secret-shaped token, put `⟦⟧` inside the token, then
check with `gitleaks dir Tests/CheapshotPortableTests/Golden`.
