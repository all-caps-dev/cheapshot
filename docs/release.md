# Release runbook: v0.5.0

Everything below is a hand step for Ryan unless marked AGENT. Do them in order. Nothing in this repo pushes, tags, or creates remote things on its own.

## 0. Preconditions (AGENT, done in Phase 2)
- `scripts/check-phase2.sh` prints `ok: phase 2` on a clean main.
- `main` is ahead of `origin/main` by the Phase 1 and Phase 2 commits, unpushed.
- The commits after `f352db5` were made unsigned. Re-sign them before step 1, on the mini with 1Password unlocked: `git rebase --exec 'git commit --amend --no-edit -S' f352db5`. Verify: `git log --show-signature f352db5..HEAD` shows a good signature on every commit. That local check only proves the commits were signed with the Agentic Vault key in 1Password; GitHub labels them Verified only if that key's public half is registered as a signing key on the all-caps-dev account at https://github.com/settings/keys .

## 0.5. Turn Pages on before the first push (RYAN, 1 minute)
One click: https://github.com/all-caps-dev/cheapshot/settings/pages > Build and deployment > Source: GitHub Actions. It has to happen before step 1, because the first push touches `site/**`, which fires pages.yml, and the deploy job goes red if the source is still Pages' default.

## 1. Push main (RYAN, 1 minute)
`git push origin main`. Verify: https://github.com/all-caps-dev/cheapshot/actions shows the CI workflow green.

## 2. Apple Developer Program for the LLC (RYAN, up to a week of waiting)
1. D-U-N-S lookup or request for `ALL CAPS RESEARCH & DESIGN LLC` at the LLC's registered address from the Articles of Organization: https://developer.apple.com/enroll/duns-lookup/
2. Enroll as an organization with the LLC Apple Account: https://developer.apple.com/programs/enroll/ ($99/yr). Legal name must match the Articles exactly.
3. Verify: https://developer.apple.com/account shows the team with a Team ID.

## 3. Developer ID Application certificate (RYAN, 10 minutes)
1. On the mini, Keychain Access > Certificate Assistant > Request a Certificate From a Certificate Authority, saved to disk.
2. https://developer.apple.com/account/resources/certificates/add > Developer ID Application > upload the request > download the .cer > double-click to install.
3. Verify: `security find-identity -v -p codesigning` lists `Developer ID Application: ALL CAPS RESEARCH & DESIGN LLC (TEAMID)`.
4. Export: Keychain Access > My Certificates > right-click the certificate > Export as .p12 with a password. Keep the password for step 5.

## 4. App Store Connect API key for notarization (RYAN, 5 minutes)
Substitute the bracketed values before pasting.
1. https://appstoreconnect.apple.com/access/integrations/api > Generate API Key, name `cheapshot-notary`, access Developer.
2. Download the `.p8` once (it cannot be downloaded again). Note the Key ID and the Issuer ID shown on that page.
3. Verify locally: `xcrun notarytool history --key 'AuthKey_<KEYID>.p8' --key-id '<KEYID>' --issuer '<ISSUER>'` returns without an auth error.

## 5. Repository secrets (RYAN, 5 minutes; paste values, never into chat)
`KEYCHAIN_PASSWORD` is a throwaway. It only unlocks the temporary keychain the release job builds and deletes on that runner, so a fresh random string is correct and it never needs to be written down or reused.

The certificate and the key go in by pipe, not by `-b`, so neither ever lands in shell history or in the argv of a running process. Run from the folder holding the .p12 and .p8:
```sh
base64 -i cheapshot-devid.p12 | gh secret set BUILD_CERTIFICATE_BASE64 -R all-caps-dev/cheapshot
gh secret set P12_PASSWORD -R all-caps-dev/cheapshot
gh secret set KEYCHAIN_PASSWORD -R all-caps-dev/cheapshot -b "$(openssl rand -hex 16)"
base64 -i 'AuthKey_<KEYID>.p8' | gh secret set ASC_KEY_BASE64 -R all-caps-dev/cheapshot
gh secret set ASC_KEY_ID -R all-caps-dev/cheapshot -b "<KEYID>"
gh secret set ASC_ISSUER -R all-caps-dev/cheapshot -b "<ISSUER>"
```
Verify: `gh secret list -R all-caps-dev/cheapshot` shows six names.

## 6. Tap repo and committer token (RYAN, 10 minutes)
1. `gh` must be signed in as `all-caps-dev`, not a personal account. Confirm with `gh auth status` first, then clone the tap beside this checkout, not inside it: `(cd .. && gh repo create all-caps-dev/homebrew-tap --public --description "Homebrew tap for cheapshot" --clone)`. The clone lands at `../homebrew-tap`, so it never shows up as an untracked folder in the cheapshot working tree.
2. Seed the tap with a version the bump action sorts below any release candidate: `mkdir -p ../homebrew-tap/Formula && sed 's/v0\.5\.0/v0.0.0/g' packaging/homebrew/cheapshot.rb > ../homebrew-tap/Formula/cheapshot.rb && (cd ../homebrew-tap && git add Formula && git commit -m "cheapshot seed formula" && git push)`. The `0.0.0` matters: mislav/bump-homebrew-formula-action refuses a bump it sorts as a downgrade, and it reports that refusal as a green `Skipping:` warning rather than a failure, so a formula already reading `v0.5.0` would silently never be bumped by the `v0.5.0-rc1` tag in step 8.
3. Fine-grained PAT for the bump step, in a browser signed in as `all-caps-dev`: https://github.com/settings/personal-access-tokens/new , resource owner all-caps-dev, repository access only `homebrew-tap`, permissions Contents: read and write, Metadata: read. Expiry one year.
4. `gh secret set COMMITTER_TOKEN -R all-caps-dev/cheapshot` and paste the token.

Verify: `gh secret list -R all-caps-dev/cheapshot` shows seven names.

## 7. GitHub Pages (RYAN, 2 minutes)
Source was set in step 0.5. https://github.com/all-caps-dev/cheapshot/actions/workflows/pages.yml > Run workflow. Verify: https://all-caps-dev.github.io/cheapshot/ loads, the sidebar has Install through Credits, and Tab from the top of the page reaches the "Skip to content" link first.

## 8. Dry run with a release candidate (RYAN, 15 minutes)
```sh
git tag v0.5.0-rc1 && git push origin v0.5.0-rc1
```
Watch https://github.com/all-caps-dev/cheapshot/actions/workflows/release.yml . Expected: the release job signs, notarizes, and publishes https://github.com/all-caps-dev/cheapshot/releases/tag/v0.5.0-rc1 ; the tap job bumps the seeded `0.0.0` formula to `v0.5.0-rc1` and commits that to homebrew-tap.

Verify, in this order:
1. The release job log shows `"status" : "Accepted"` in the notarytool output. Anything else, including `Invalid`, fails the job on purpose.
2. The tap job log does not contain `Skipping:`. That word means the action sorted the tag below the version already in the formula and exited green without committing, which leaves the tap stale and makes the `brew install` below 404.
3. Download the asset and check the archive shape: `unzip -l cheapshot-v0.5.0-rc1-macos.zip` lists exactly one entry, `cheapshot`, at the archive root. A nested folder or a second file means the packaging step regressed and Homebrew will install the wrong path.
4. On a second Mac or a fresh user: `brew install all-caps-dev/tap/cheapshot && cheapshot --version`.

If notarization comes back anything other than Accepted, run `xcrun notarytool log '<submission-id>' --key 'AuthKey_<KEYID>.p8' --key-id '<KEYID>' --issuer '<ISSUER>'` locally to read the rejection; the submission id is in the job log.

If anything fails, fix the workflow here, delete the rc release and tag (`gh release delete v0.5.0-rc1 -y && git push --delete origin v0.5.0-rc1 && git tag -d v0.5.0-rc1`), and revert the tap commit (`cd ../homebrew-tap && git revert --no-edit HEAD && git push`), then repeat.

## 9. Version and tag (AGENT then RYAN)
1. AGENT: set `cheapshotVersion` to `0.5.0`, update `testVersionConstant`, `swift test`, commit `version: 0.5.0`. (The version string is `0.5.0-dev` until this step by spec.)
2. RYAN: `git push origin main && git tag v0.5.0 && git push origin v0.5.0`. Verify: https://github.com/all-caps-dev/cheapshot/releases/tag/v0.5.0 has `cheapshot-v0.5.0-macos.zip`, and https://github.com/all-caps-dev/homebrew-tap/blob/main/Formula/cheapshot.rb has `url` pointing at v0.5.0 with a real `sha256`. Then `brew upgrade cheapshot` on the test Mac reports 0.5.0.

## Open decision carried
Bundle id hyphen (dev.all-caps.cheapshot vs dev.allcaps.cheapshot) is not needed for the CLI; decide it when the app's App ID is created in Phase 4.
