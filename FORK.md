# This fork

Development home for my own cake-autorate work, running on a NixOS router on a
Starlink line. Upstream is <https://github.com/lynxthecat/cake-autorate>; this
fork is not a competing project and carries no ambition to become one.

## Branches

| branch | what it is |
| --- | --- |
| `master` | a plain mirror of upstream. Never commit here — it exists so everything else can be rebased onto a clean base. |
| `homelab` | **what actually runs on my hardware**: `master` plus the patches below. This is the branch my NixOS flake vendors. |
| `feat/*`, `fix/*`, `harden/*` | one branch per upstream pull request, each based on `master`. |

Sync:

```sh
git fetch upstream
git push origin upstream/master:master        # move the mirror
git rebase master homelab                     # replay the local patches
```

If the rebase conflicts, the patch has been overtaken by upstream — check
whether it is still needed before resolving it.

## What `homelab` carries, and why

**Reject non-numeric RTT samples.** fping reports a negative RTT when the system
clock steps backwards mid-ping, which happens on this box when chrony
disciplines the clock after boot. `10#${rtt_us//.}` cannot represent a negative,
the arithmetic error kills the main loop, and the trap exits 0 — so systemd
records success, does not restart, and the shaper silently stops adapting.
Observed twice, out of six backward steps since July.

The mechanism is specific to fping: it prints such a value (`sprint_tm()` has a
branch labelled `/* negative (unexpected) */` that formats it `%.2g`), whereas
iputils ping clamps it to zero and warns. It also depends on the build — with
`HAVE_SO_TIMESTAMPNS` defined, which is the default on Linux, fping takes its
timestamps from `CLOCK_REALTIME` rather than `CLOCK_MONOTONIC`.

Merged upstream (#392); the local copy drops out of `homelab` at the next sync
rebase. The guard covers the fping parser arm only: iputils
clamps a backward step to zero rather than reporting it, so the ping arm cannot
receive a value that breaks the arithmetic. It uses a glob class check rather
than a regex — `[[ =~ ]]` recompiles the ERE on every sample, which is ~65x the
cost on that hot path.

**Declare the `sqm_*` cake option keys.** `sqm-setup.sh`, in
<https://github.com/ooonea/cake-autorate-openrc>, creates the qdiscs that
cake-autorate then adjusts, and reads its CAKE option strings from the config.
Undeclared keys make config validation reject the instance file, and the daemon
exits without explaining why.

**Harden controller state and process lifecycle.** The homelab deployment also
carries the audited runtime fixes on `local/runtime-safety-audit`: a failed
`tc qdisc change` no longer advances the controller's internal rate, fatal
errors remain visible to the service manager, stale or malformed pinger samples
cannot mutate delay state, byte-rate calculations use actual monotonic elapsed
time, and process metadata is published atomically with PID start times. The
launcher now fails fast and reaps all children. Instance startup is serialized
with a kernel `flock`, which auto-releases across crashes and avoids stale-lock
recovery races; `flock` is therefore an explicit runtime dependency.

## Contributing back

Anything meant for upstream is branched from `master`, never from `homelab`, so
it carries no local divergence.
