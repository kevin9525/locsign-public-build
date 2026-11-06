# Public build snapshot

This source snapshot was prepared from commit `ecbb7ee3973c3506c9e6acb76398dcd4316c1aeb`.
It excludes the private development repository's Git history and device evidence
logs. Device identifiers and original workstation paths in documentation are
redacted. The private development repository remains the source of truth.

All committed pairing/profile/key fixtures are deliberately synthetic test data.
No real Apple ID, token, pairing record, signing key or CI secret is required.

Builds use the standard GitHub-hosted macOS runner. Start the `build` workflow
manually with **Run workflow**. Pending provisioning tests may fail: the latest
fully verified development commit is `96e4e63` (120 tests, both iOS builds).
Current source includes fail-closed scaffolding under active development.

Publishing this snapshot makes all files and future Actions logs/artifacts public.
Never supply real Apple credentials, ADI or signing materials to CI.
