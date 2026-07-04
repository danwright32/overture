# CI runner setup (one time, by Dan)

Part of #478 (milestone 12), Phase 2 (#504). This registers a self-hosted GitHub Actions
runner on your own Mac so Phase 3's Swift test job (`xcodebuild test`, not yet built) has
somewhere to run. Phase 1's TypeScript job already runs on a GitHub-hosted `ubuntu-latest`
runner and needs none of this.

## Why self-hosted

GitHub-hosted macOS runners apply a 10x minute multiplier even against the Free plan's
included allowance, which works out to roughly 200 real minutes a month, not viable for
this repo's commit velocity. Self-hosted runners have zero GitHub Actions minute cost
regardless of OS, so this runs one on your own Mac instead, scoped to just this repo (not
your whole account or org).

**Policy risk, not a blocker:** "self-hosted runners are free" is GitHub's current policy,
not a permanent guarantee. GitHub floated a per-minute charge for exactly this setup in
December 2025 and withdrew it about 48 hours later. If that policy ever changes, this
phase's cost premise needs revisiting.

## Why it has to run under the danwright32 identity

This machine's default active `gh` account is `nursedexapp`, which cannot see this repo (a
404, not a permissions error). Minting a runner registration token and reading the runner
download info both require repo admin access, so every command in
`register-ci-runner.sh` and `run-ci-runner-loop.sh` runs scoped to `danwright32` via
`GH_TOKEN=$(gh auth token -u danwright32) gh ...`. The scripts verify this access
(`gh api repos/danwright32/overture --jq .permissions.admin` must return `true`) before
doing anything else.

## Why ephemeral, and what that costs you

The runner is configured with `--ephemeral`, meaning GitHub automatically deregisters it
after it processes exactly one job, per GitHub's own security guidance: this shrinks how
long a standing runner credential lives and how much attack surface it has, at the cost of
needing something to keep re-registering a fresh runner for every future job. That
something is `mac/scripts/run-ci-runner-loop.sh`: it mints a new registration token, wipes
the previous job's local runner state (GitHub's own recommendation, since server side
deregistration doesn't clean up local files), configures the runner, and runs one job,
forever, in a loop. The LaunchAgent points at this loop script, not at the runner's own
`run.sh` directly.

## Why a LaunchAgent, not a LaunchDaemon

`xcodebuild test`'s `TEST_HOST` is the full Overture.app binary, which needs a GUI/Aqua
session to run; a LaunchDaemon does not have one. The runner is installed as a per-user
LaunchAgent, bootstrapped into `gui/$(id -u)`, same as Overture's own resident agent
(`com.danwright.overture`, a different label so the two never collide). This means the
runner is only listening while you're logged in. A locked screen is fine; being logged out
is not.

## Why it runs as your own user account

The runner runs as Dan's own user account, exactly like Overture itself, rather than under
a separate restricted account. This repo is private and only Dan/Claude can ever push to
it, so the isolation a dedicated account buys doesn't pay for itself here; this was a
deliberate choice, not an oversight.

## Installing it

Requires: `gh` installed and authenticated as `danwright32`
(`gh auth login` if you haven't), and admin access on `danwright32/overture` for that
identity.

From the repo root:

```
mac/scripts/register-ci-runner.sh
```

This is safe to re-run. Each run: verifies `danwright32` has admin access, downloads and
checksum-verifies the official macOS arm64 runner distribution into
`~/actions-runner-overture` if it isn't already there, stops any currently running agent,
clears a stale registration if one is left over, and (re)installs and starts the
`com.danwright.overture.ci-runner` LaunchAgent. From there, the loop script takes over:
it mints its own registration tokens and reconfigures the runner before every job, so
nothing further needs to be run by hand.

**Re-running this while a CI job might be in flight will stop that job**, the same as
re-running `build-install.sh` restarts Overture itself. Avoid it mid-job.

## Checking on it

```
launchctl print gui/$(id -u)/com.danwright.overture.ci-runner
tail -f ~/Library/Logs/OvertureCIRunner/ci-runner-agent.out.log
```

The log captures every loop cycle (token minted, runner configured, job listened for) for
as long as the agent has been running. GitHub's own docs note that ephemeral runners'
per-job logs should be forwarded to external storage for real fleets; at this repo's scale
(one Mac, one repo), the LaunchAgent's own persistent log file serves that purpose well
enough.

Once Phase 3 lands, its job should target this runner with a label like
`[self-hosted, macOS, overture-mac]` in the workflow's `runs-on`. Phase 3's test wrapper
(`mac/scripts/run-tests-locked.sh`) also needs `flock` installed on this Mac
(`brew install flock`; not present by default).

## Tearing it down

```
launchctl bootout gui/$(id -u)/com.danwright.overture.ci-runner
rm ~/Library/LaunchAgents/com.danwright.overture.ci-runner.plist
```

That stops the loop and removes the login agent. If a runner is still registered on
GitHub's side (it shouldn't be, between ephemeral jobs, but a bootout mid-job can leave one
behind), deregister it from the repo's Settings > Actions > Runners page, or via the API:

```
GH_TOKEN=$(gh auth token -u danwright32) gh api -X POST \
  repos/danwright32/overture/actions/runners/remove-token --jq .token
```

then, from `~/actions-runner-overture`, `./config.sh remove --token <that token>`. Delete
`~/actions-runner-overture` afterward if you want the download gone too.
