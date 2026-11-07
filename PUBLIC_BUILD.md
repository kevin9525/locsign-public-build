# Public build snapshot

This source snapshot was prepared from commit `ecbb7ee3973c3506c9e6acb76398dcd4316c1aeb`.
It excludes the private development repository's Git history and device evidence
logs. Device identifiers and original workstation paths in documentation are
redacted. The private development repository remains the source of truth.

All committed pairing/profile/key fixtures are deliberately synthetic test data.
No real Apple ID, token, pairing record, signing key or CI secret is required.

Builds use the standard GitHub-hosted `macos-15-intel` runner and run on main pushes or manual dispatch. ARM capacity failures are avoided without using paid larger runners. Public commit `1890319` passed 169 XCTest tests, 4 packaging tests, simulator and unsigned iphoneos builds in run `42262193781`. Real Apple login, material issuance and device installation remain on-device acceptance items; no real credentials are used in CI.

Publishing this snapshot makes all files and future Actions logs/artifacts public.
Never supply real Apple credentials, ADI or signing materials to CI.
