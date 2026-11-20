# Manual renewal certificate confirmation

The build27 device screenshot reports `revocationDeclined` after the account
check succeeds. `AppRenewalCoordinator` supplies an unconditional false decision
to provisioning for both automatic and manual runs. The installation flow already
supports an explicit certificate decision, but the App list's manual button does
not expose one. This is a confirmed routing defect; it does not mean the user
declined a visible prompt. Why earlier account restoration failed remains unproven.

Manual renewal now forwards the exact candidate list to the existing account
decision model, and AppsView presents the list with names, IDs, serials, expiry,
the consequences of revocation, and explicit keep/cancel versus revoke/continue
actions. No affirmative default is used. Automatic background and unattended
foreground runs still return false without a prompt. Cancellation, dismissing
the decision, leaving the Apps view while it is pending, or moving out of the
foreground declines the pending decision. Late responses outside the foreground
are also declined. Existing provisioning logic rechecks the exact certificate
list after confirmation and preserves cancellation checks before mutations.

Source IPA, bundle/team/device identity, fresh-profile requirements, and the
existing post-relaunch self-installation confirmation remain unchanged.
No remote certificate has been revoked by development tools.

Tests-only baseline `b76c14df04296a13c5b080f5d1590cdec0db52f3`, run `44677384698`,
failed the two new manual decision tests with nine assertions: the visible
candidate list never appeared and approval could not proceed. All previous 439
tests passed. Regression cases cover approve, decline, cancelling while waiting,
and unchanged unattended refusal.

Independent review found that observing only AppsView disappearance while a
prompt already exists misses a quota response arriving after a tab switch.
The follow-up design uses selected-tab and scene state from LocSignApp, not
sheet/presenter disappearance. Each manual run snapshots presentation eligibility;
leaving the tab or foreground invalidates that run's right to prompt, even if the
user returns before the response. A pending decision is cancelled and declined;
automatic renewal and the separate installation flow retain their ownership.
No-quota renewal can continue as before. Tests exercise delayed quota after
leave/return, pending-prompt ownership loss, and an unaffected automatic run.
The failing-test baseline b72c619 has only an inert eligibility field. Its run
44681292642 executed 444 tests; the two new ownership-loss tests failed with
three assertions (two unfinished waits and an orphaned prompt). The other 442
tests passed, including manual approval/decline and unaffected automatic renewal.
The implemented guard now snapshots and invalidates manual eligibility, checks
it before and after awaiting a decision, and declines pending decisions when
their tab/foreground owner is lost.

Full green CI and follow-up independent review pending.

Target 0.4.9 (28). Actual device confirmation UI and self-renewal acceptance must
still be checked after cover-update; no successful end-to-end renewal is claimed.
