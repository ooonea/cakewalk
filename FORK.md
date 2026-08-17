# cakewalk — provenance and layout

cakewalk is a GPL-2.0 fork of
<https://github.com/lynxthecat/cake-autorate>, carrying the full upstream
history up to `7934c3e` plus the divergences below. Credit for the original
design and years of tuning belongs to lynxthecat, rany2 and the cake-autorate
contributors. This repository is the canonical source consumed by the NixOS
router it runs on (Starlink WAN).

## Why a standalone project

The fixes this deployment depends on did not land upstream: a failed
`tc qdisc change` was committed as installed state (so it was never retried
and the delay compensations drifted), and a daemon killed by an internal
error exited 0, invisible to the service manager. Development continues here,
reviewed and tested against the deployment instead.

## Divergences from upstream `7934c3e`

- shaper state is committed only when `tc` succeeds, with qdisc-kind
  re-detection on failure
- fatal exits propagate a non-zero status to the service manager
- associative pinger-PID bookkeeping fix
- ping parser rejects ICMP error lines whatever their token count
- `sqm_dl_cake_opts` / `sqm_ul_cake_opts` defaults keys plus the
  generic-Linux `sqm-setup.sh` helper
- controller and process lifecycle hardening; terse comment style

`git log 7934c3e..main` is the authoritative list.

## History

The GitHub fork <https://github.com/ooonea/cake-autorate> is the frozen
archive of the upstream-contribution era (17 merged PRs, ending 2026-08).
