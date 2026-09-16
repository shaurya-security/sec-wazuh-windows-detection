# Changelog — sec-wazuh-windows-detection/terraform-lab

Running changelog across the full rewrite. Started as a 4-batch fix for the
Wazuh manager/agent version mismatch, pinned agent log format, real active
response wiring, pinned Windows AMI, and simulation scripts split out of
`wazuh.sh` into standalone, staged-but-not-executed payloads. Extended
since with folder-layout centralization on the Windows box, explicit
`ssm-user` provisioning (mirroring `common.sh` on Linux), a pinned Linux
AMI, and a fix for the deferred hostname rename.

---

## Batch 1 — `variables.tf`, `locals.tf`, `s3.tf`, `output.tf`

### `variables.tf`
**Before:** `vpc_cidr`, `public_subnet_cidr`, `owner` only. No version, bucket,
region, or AMI variables — everything else was hardcoded across files.

**After:** Added `aws_region`, `availability_zone`, `userdata_bucket`,
`wazuh_version` (validated `MAJOR.MINOR.PATCH`), `wazuh_agent_msi_revision`,
`windows_ami_id` (validated `ami-xxxxxxxx` or empty), `timezone`.

**Flagged:**
- `windows_ami_id` defaults to `""`. On first apply it resolves via SSM;
  you must copy `resolved_windows_ami_id` (new output) into
  `terraform.tfvars` yourself to actually pin it. Nothing pins it
  automatically.
- `wazuh_version` default `4.14.0` is a guess at a valid patch release —
  verify it exists on `packages.wazuh.com` before applying.

### `locals.tf`
**Before:** Naming locals only.

**After:** Added `wazuh_branch` (derives `4.14` from `4.14.0` for the
installer URL) and `wazuh_agent_msi` (derives the full MSI filename) — both
computed from the single `wazuh_version` variable so manager and agent can't
drift apart again. Added `userdata_dir`, `userdata_objects` (via `fileset`,
excludes `*.tpl`), `userdata_hashes` (per-file MD5, keyed by S3 key).

**Flagged:**
- `userdata_objects` expects `local_rules.xml`, `active-response.conf`, and
  a `simulations/` directory that don't exist until Batches 3–4. Before
  then, `fileset` just returns fewer files — no error, but don't expect the
  full manifest until all batches are applied.

### `s3.tf`
**Before:** Three near-identical `aws_s3_object` resources
(`common_sh`, `wazuh_sh`, `windows_ps1`), each bucket name hardcoded.

**After:** Single `aws_s3_object.userdata` with `for_each` over
`local.userdata_objects`. Adds a `content_type` lookup by extension and
`ManagedBy = "terraform"` tag.

**Flagged:**
- Dropping a file from `userdata/` now silently drops it from S3 on next
  apply (for_each removes stale keys) — this is a behavior change from the
  old fixed-resource approach, worth knowing before deleting files casually.

### `output.tf`
**Before:** Outputs named with trailing-dash padding
(`"wazuh_private_ip----"`, `"output_time_ist-----"`, etc.) — apparent
terminal-alignment artifact.

**After:** Renamed to plain identifiers. Added `wazuh_dashboard_url`,
`resolved_windows_ami_id`, `resolved_amazon_linux_ami_id`, `wazuh_versions`
(struct showing version/branch/MSI/installer URL in effect).

**Flagged — breaking change:** any script or muscle-memory command that
parsed `terraform output` by the old padded names will break. Intentional,
but call it out if others use this repo.

---

## Batch 2 — `data.tf`, `compute.tf`, `s3-bootstrap.sh.tpl`, `windows-bootstrap.ps1.tpl`

### `data.tf`
**Before:** `aws_ssm_parameter.windows_2022_ami` always queried; AMI could
silently change on any apply.

**After:** SSM lookup now wrapped in `count = var.windows_ami_id == "" ? 1 : 0`.
Added `local.windows_ami_id` (pinned value wins, else SSM) and
`local.windows_ami_unpinned` flag, surfaced later as a boot-time warning.

**Flagged:** none new — this is the mechanism that makes the Batch 1
pinning variable actually take effect.

### `compute.tf`
**Before:** `user_data` rendered from `*.tpl` with ad hoc, individually
named variables (`s3_bucket`, `script_name`, `common_hash`, `script_hash`,
`timezone`). Wazuh instance depended on named S3 objects
(`aws_s3_object.common_sh`, `.wazuh_sh`) that no longer exist after Batch 1.
Windows AMI came straight from the unpinned data source.

**After:** `ami = local.windows_ami_id` (pinned-or-resolved). Both
`depends_on` blocks point at `aws_s3_object.userdata` (the new for_each
resource). Each template now receives a `payloads` map — a *filtered* slice
of `local.userdata_hashes` scoped to what that instance actually consumes
(manager gets `common.sh`/`wazuh.sh`/`local_rules.xml`/`active-response.conf`;
Windows gets `windows.ps1` + anything under `simulations/`). Windows root
volume gained explicit `volume_size = 60` / `volume_type = "gp3"` (previously
unset, inheriting AMI default).

**Flagged:**
- Filtering hashes per-instance means editing `windows.ps1` no longer forces
  a manager rebuild, and vice versa — this was one of the original review
  findings (unnecessary coupling) and is now fixed structurally.
- Commented-out `lifecycle { ignore_changes = [ami] }` left in for the
  Amazon Linux instance — not enabled, since `most_recent = true` is still
  live for that AMI (only Windows got a pinning variable). Worth deciding if
  you want the same treatment for the manager AMI.

### `userdata/s3-bootstrap.sh.tpl` and `userdata/windows-bootstrap.ps1.tpl`
**Before:** Templates embedded specific filenames and hashes directly
(`script_name`, `common_hash`, `script_hash`), fetched exactly two files,
ran them by fixed name.

**After:** Both templates now loop over the generic `payloads` map (`%{ for
key, hash in payloads }`) to fetch an arbitrary set of files, pass
configuration to the fetched scripts via **environment variables** (Linux:
`BUCKET`, `TIMEZONE`, `WAZUH_VERSION`, `WAZUH_BRANCH`, `BOOTSTRAP_DIR`) or
**named parameters** (Windows: `-WazuhManagerIP -WazuhVersion
-WazuhAgentMsi -PayloadDir`) instead of baking values into the fetched
scripts. This is what allows `wazuh.sh`/`windows.ps1` to become plain,
Terraform-free files in Batch 3.

**Flagged:**
- **This batch is not independently applicable.** `windows.ps1` at this
  point in the sequence still has its old one-parameter signature; the new
  template calls it with four. Apply together with Batch 3, not alone.
- Every payload hash appears as a comment at the top of the rendered
  `user_data` — combined with `user_data_replace_on_change = true`, editing
  *any* watched file will force-replace that instance on next apply. Known
  and accepted for a disposable lab, but worth remembering if an apply
  rebuilds a box unexpectedly.

---

## Batch 3 — `local_rules.xml` (new), `active-response.conf` (new), `wazuh.sh`, `windows.ps1`

### Pinned log-format decision (drives everything in this batch)
**Before:** Rules matched `if_sid 67027` (Sysmon process-creation decoder)
while comments claimed Event ID 4688 (native Security log) — decoder and
documentation disagreed, and it's unclear either was verified against a
real alert.

**After:** Pinned to **native Windows `Security` channel via
`eventchannel`** log format for every scenario rule: 4688 (process
creation), 4625 (failed logon), 4698 (scheduled task audit). Rules use
`<decoded_as>windows_eventchannel</decoded_as>` + explicit
`win.system.channel` match instead of `<if_sid>`, so they don't depend on
Wazuh's internal base-rule numbering across versions. Sysmon and
PowerShell/Operational channels are still collected (for future rules) but
no current scenario rule depends on them.

**Flagged:** This is a one-way architectural choice — if you'd rather
detect via Sysmon (richer field set, e.g. hashes, parent process chains),
scenario 1 and 3 would need re-authoring against Sysmon event IDs (1, etc.)
instead of Security 4688/4698. Native was chosen here because it needed no
extra channel config beyond audit policy, but it's a legitimate trade-off
either way.

### `userdata/local_rules.xml` (new file, previously a heredoc inside `wazuh.sh`)
**Before (inside `wazuh.sh`):**
- Rule 115100: `if_sid 67027` + Sysmon-style fields, contradicting its own
  comment about Event 4688.
- Rule 115210 (brute-force correlation): grouped by `<same_source_ip />`.
  Since the simulation attacks `\\localhost`, the source IP on 4625 is
  typically `-` or `127.0.0.1` — same-IP correlation either fails to group
  distinct runs or over-groups unrelated ones.
- Rule 115310 (scheduled-task correlation): `<if_sid>115300</if_sid>` +
  `<if_matched_sid>115301</if_matched_sid>` — fires only when 115300 (the
  schtasks.exe process event) arrives *after* 115301 is already cached.
  Ordering between a process-creation event and its corresponding audit
  event isn't guaranteed, so this could silently fail to correlate.

**After:**
- 115100 rewritten against native 4688 + `commandLine` regex, broadened to
  also catch `-exec bypass` / short-form `-e`/`-en` flags.
- 115210 now correlates on `<same_field>win.eventdata.targetUserName</same_field>`
  instead of source IP — matches how the simulation actually authenticates.
- 115310 flipped: `<if_sid>115301</if_sid>` (the audit event, 4698) with
  `<if_matched_sid>115300</if_matched_sid>` (looking back for the
  command-line event) — audit events are logged after process creation
  completes, so this ordering is the one that's actually guaranteed to work.
- All rules now carry `win.system.channel` explicitly, so a same-numbered
  event from a different source (e.g. a forwarded log) can't accidentally
  match.

**Flagged:** `decoded_as` matching is slightly more expensive than
`if_sid`-based inheritance at scale — irrelevant for a two-host lab, worth
knowing if this ruleset is ever reused against real traffic volume.

### `userdata/active-response.conf` (new file)
**Before:** The `<command>`/`<active-response>` XML block existed only
inside a heredoc that `wazuh.sh` wrote out to
`~ssm-user/active_response_config.sh` — a script that nothing ever ran.
Active response for Scenario 1 was documented as working but was inert by
default.

**After:** Extracted to its own S3 payload, fetched by `wazuh.sh` and
merged into `ossec.conf` automatically at boot, with an idempotency marker
(`<!-- soc-sim-active-response -->`) so re-running the merge logic doesn't
duplicate the block.

**Flagged:** This alone doesn't make active response work — see the
`windows.ps1` entry below. The command binary (`task-kill.cmd`) has to
exist on the agent side too; both halves were missing before, only the
manager half is fixed here.

### `userdata/wazuh.sh`
**Before:** Hardcoded to Wazuh **4.14** installer URL regardless of any
variable; embedded the ruleset and active-response config as inline
heredocs; embedded all three alert-generation PowerShell scripts as a
fourth heredoc (`alert_gen_commands.txt`) written to the user's home
directory — meant to be copy-pasted manually, not staged as runnable files.
No validation that the installed version matched what was requested; no
`ossec.conf` syntax check before restart; active-response merge step never
executed.

**After:** Reads `WAZUH_VERSION`/`WAZUH_BRANCH` from environment (set by the
bootstrap shim, sourced from the single `wazuh_version` variable). Installs
`local_rules.xml` and merges `active-response.conf` from fetched S3
payloads rather than heredocs. Checks installed version against requested
version and warns on mismatch instead of failing silently. Runs
`wazuh-logtest -t` before restarting the manager, to catch a malformed
config before it takes down the service. Restarts `wazuh-manager`
specifically so the new ruleset loads. No longer contains any simulation
script content — that's gone entirely (see Batch 4).

**Flagged:**
- The `ossec.conf` merge uses `sed` to insert before the *last*
  `</ossec_config>` tag and rewrite it — functionally correct against a
  stock config, but fragile if Wazuh's default file structure ever changes
  shape. Worth checking the resulting file by hand on first boot.
- Password parsing from the install log (`grep -a "Password:"`) is
  unchanged in fragility — still breaks silently if Wazuh's log wording
  changes between versions. Now at least surfaces a `WARNING` in the log
  instead of just producing an empty password field.

### `userdata/windows.ps1`
**Before:** Single `-WazuhManagerIP` parameter; agent MSI hardcoded to
**4.9.0-1**, independent of the manager's 4.14; MSI arguments passed as one
long string containing a literal embedded newline inside the quoted
`-ArgumentList` (relying on msiexec tolerating it); no active-response
binary deployed anywhere; no explicit log-format configuration beyond
adding the Sysmon channel to whatever `ossec.conf` shipped with the MSI.

**After:** Takes `-WazuhManagerIP -WazuhVersion -WazuhAgentMsi -PayloadDir`.
Agent MSI URL now built from `$WazuhAgentMsi` (itself derived from the same
`wazuh_version` variable the manager uses) — the version-mismatch bug is
structurally closed, not just patched once. MSI arguments passed as a
PowerShell array, not a hand-built string. `ossec.conf`'s `<localfile>`
section is now rebuilt wholesale (regex-stripped and re-declared) to
guarantee exactly five channels, all `eventchannel` format: Security
(filtered by `<query>` to the four event IDs the rules need), System,
Application, Sysmon/Operational, PowerShell/Operational. Deploys
`task-kill.cmd` + `task-kill.ps1` into the agent's
`active-response\bin` directory, completing the AR wiring started in
`active-response.conf`. Added a step 7 (Batch 4) that stages simulation
scripts without running them — this step's number shifted to 8 after
Batch 6 inserted `ssm-user` creation as step 2; the step numbers throughout
this changelog reflect the numbering *at the time each batch was written*,
not necessarily the final script.

**Flagged:**
- `Rename-Computer` still runs without `-Restart`, same as before — the
  hostname doesn't actually take effect until a reboot, so the agent
  enrolls under the EC2-generated name on first boot, not
  `WIN-SOC-NODE01`. Unchanged from the original; flagged again because it's
  still true.
- The `<query>` filter on the Security channel (limits to EventID
  4688/4625/4698/4697/4624) cuts log volume but means any new detection
  rule needs its event ID added there first, or it'll never see the event.
- The active-response PowerShell script assumes `win.eventdata.newProcessId`
  arrives as a hex string (`0x...`) per 4688's normal format — not verified
  against a live alert yet. Worth checking
  `/var/ossec/logs/alerts/alerts.json` on the manager and
  `C:\SOC-Lab\active-response.log` on the endpoint after a real run.

---

## Batch 4 — `simulations/scenario{1,2,3}-*.ps1` (new), `windows.ps1` (step 7 added)

### Simulation scripts (new files, previously one heredoc block in `wazuh.sh`)
**Before:** All three PowerShell simulation snippets lived inside `wazuh.sh`
as a single heredoc (`alert_gen_commands.txt`) written to the Wazuh
*manager's* home directory — the wrong host entirely, since the commands
are meant to run on the Windows endpoint. Nothing copied them anywhere
useful; a user would have had to manually copy-paste from that file into a
Windows session.

**After:** Split into three independent files
(`scenario1-powershell-encoded.ps1`, `scenario2-brute-force.ps1`,
`scenario3-scheduled-task.ps1`), each self-contained with its own header
comment documenting which rule(s) it should trigger and what log-format
assumptions it depends on. Uploaded to S3 under `simulations/` via the
existing `for_each` in `s3.tf` (no changes needed there — `fileset` picks
them up automatically). Fetched onto the Windows box by the existing
bootstrap-shim loop (wired in Batch 2).

**Flagged:** Scenario 2's cleanup now explicitly runs
`net use \\localhost\C$ /delete` after the failed attempts, which the
original script didn't do — a minor addition to avoid leaving a stale
failed mapping around, not a functional requirement of the detection.

### `userdata/windows.ps1` — step 7 (new)
**Before:** No staging step existed; simulation content wasn't on the
Windows box in any form.

**After:** Copies fetched `simulations/*.ps1` from the bootstrap scratch
directory to `C:\SOC-Lab\simulations`, grants `ssm-user`
Read+Execute via ACL, runs `Unblock-File` on each script, and explicitly
does **not** execute anything.

**Flagged — the main open item from this batch:**
- **`ssm-user` doesn't exist at boot time on Windows.** Unlike Linux, where
  `common.sh` creates the account directly, Windows' SSM Agent only
  provisions the local `ssm-user` account lazily, on the *first* Session
  Manager connection — which happens well after `windows.ps1` finishes
  running. So on a fresh instance, this step will almost always hit its
  `else` branch: it warns, leaves the scripts staged without the ACL
  applied, and moves on rather than failing provisioning. In practice this
  is mostly cosmetic — Session Manager connections run as `ssm-user` by
  default anyway — but the ACL as written won't reliably "take" on first
  boot. If you need the ACL to definitely be in place before first login,
  the reliable fix is a separate SSM Run Command (or re-running this block
  by hand) after the first Session Manager connection, not a bootstrap-time
  change.
- `Unblock-File` is effectively a no-op here since files arrive via S3
  rather than a browser download and never get the Mark-of-the-Web zone
  identifier — kept as cheap defense-in-depth in case the fetch path
  changes later, not because it's currently doing anything.

---

## Batch 5 — `windows-bootstrap.ps1.tpl`, `windows.ps1` (folder centralization)

Triggered by an audit of every path written to disk on the Windows box:
`C:\TerraformBootstrap` (bootstrap scratch), `C:\SOC-Lab` (final artifacts),
plus installer-owned paths (`ossec-agent`, `AWSCLIV2`) left alone. Found
that simulation scripts existed in *two* places at once — fetched into
`C:\TerraformBootstrap\simulations`, then copied into
`C:\SOC-Lab\simulations` by `windows.ps1` step 7 — a duplication caused by
fetching (bootstrap shim) and staging (`windows.ps1`) not agreeing on one
canonical location.

### `windows-bootstrap.ps1.tpl`
**Before:** Fetched payloads into `C:\TerraformBootstrap`, a directory
distinct from `C:\SOC-Lab` where `windows.ps1` put everything else.

**After:** Single root `$Root = "C:\SOC-Lab"` for everything the bootstrap
shim and `windows.ps1` write. Payload keys (including anything under
`simulations/`) are fetched straight to their final resting place under
this root — no separate scratch directory. `windows.ps1` is now invoked
with `-Root $Root` instead of the old `-PayloadDir`. The transient AWS CLI
installer MSI still uses `$env:TEMP`, not `$Root`, since it's deleted
immediately after install and was never meant to persist.

### `windows.ps1`
**Before:** Took `-PayloadDir` (the bootstrap scratch dir) as a parameter.
Step 7 explicitly `Copy-Item`'d `$PayloadDir\simulations\*.ps1` into
`C:\SOC-Lab\simulations` before setting the ACL — the duplication step.
Logs, MSI/Sysmon installer files, and the `ossec.conf` backup were all
written loose directly under `C:\SOC-Lab` with no subfolder structure.

**After:** Takes `-Root` instead. Introduces `logs\` (install logs,
transcript, `ossec.conf` backup, active-response log) and `_tmp\`
(MSI/Sysmon installer downloads) subfolders under `$Root`. Step 7 (staging
simulation scripts) no longer copies anything — the fetch destination from
the bootstrap shim *is* `$Root\simulations`, so the step only sets the ACL
and runs `Unblock-File` on files already in place.

**Flagged:**
- The active-response PowerShell script's log path moved to
  `C:\SOC-Lab\logs\active-response.log` (was loose at `C:\SOC-Lab\` root) —
  easy to miss if grepping for it from memory of the earlier layout.
- Installer-owned paths (`ossec-agent`, `AWSCLIV2`) were deliberately left
  outside this centralization — not "ours" to relocate, and moving them
  would fight each installer's own conventions for no real benefit.
- This did not touch the `ssm-user` timing issue flagged in Batch 4 — that
  required a separate fix (Batch 6), since centralizing paths doesn't
  address *when* the account gets created.

---

## Batch 6 — `windows.ps1` (explicit `ssm-user` provisioning)

Directly closes the `ssm-user` race flagged in Batch 4: AWS SSM Agent on
Windows only provisions the local `ssm-user` account lazily, on the first
Session Manager connection — well after `windows.ps1` finishes running. So
the ACL step added in Batch 4 was hitting its fallback warning branch on
every fresh instance, not just occasionally.

### `windows.ps1`
**Before:** No account-creation step. `ssm-user` was assumed to exist by
the time step 7 (simulation-script permissioning) ran; it usually didn't.

**After:** New step 2 (immediately after hostname rename, before anything
else touches the filesystem or installs software — same ordering
principle as `useradd` at the top of `common.sh` on Linux). Creates a
local `ssm-user` account with a randomly generated 24-character password
(generated, used to satisfy the account-creation API, then discarded —
never written to disk or logged), `PasswordNeverExpires` +
`AccountNeverExpires` + `UserMayNotChangePassword` set, and adds it to the
local `Administrators` group — the Windows equivalent of the `NOPASSWD:ALL`
sudoers entry `common.sh` grants on the Linux side. Also runs a one-shot
scheduled task (`schtasks /create ... /ru ssm-user`, run once, then
deleted) purely to force Windows to materialize `C:\Users\ssm-user` at boot
rather than waiting for the account's first real interactive logon — there
is no direct `New-LocalUser -CreateProfile` equivalent, so this is the
standard workaround.

Because the account now exists before step 8 (permissioning simulation
scripts, renumbered from step 7 after this insertion) runs, that step's
"account doesn't exist yet" branch is now a defensive fallback for an
unexpected failure, not the expected path it used to be.

**Flagged:**
- `ssm-user` now has full local `Administrators` membership — same
  disposable-lab trade-off already accepted for the Linux `NOPASSWD:ALL`
  sudoers entry, not a new risk category, just the Windows-side version of
  the same call.
- **Not independently verified:** whether AWS SSM Agent, on first Session
  Manager connection, actually detects and reuses a pre-existing
  `ssm-user` account as documented, or resets its password/group
  membership regardless of what's already there. If the account's
  permissions look different after a first real connection than what this
  step set, that's the first thing to check.
- The profile-creation scheduled task is a workaround, not a guaranteed
  outcome — if it fails silently, the account still works fine for SSM
  purposes, it just wouldn't have a materialized profile folder until an
  actual first login happens.

---

## Batch 7 — `variables.tf`, `data.tf`, `compute.tf` (Linux AMI pin)

### `variables.tf`
**Before:** No `linux_ami_id` variable — `data.aws_ami.amazon_linux` always
ran with `most_recent = true`, so the Wazuh manager's AMI could silently
change on any apply, same class of issue already fixed for Windows in
Batch 2.

**After:** Added `linux_ami_id`, default set directly to a real AMI
(`ami-094210f044117049d`) rather than empty string — unlike
`windows_ami_id`, which defaults empty and requires a first-apply-then-copy
step, this one is pinned from the very first apply since a concrete value
was supplied up front.

### `data.tf`
**Before:** `data.aws_ami.amazon_linux` queried unconditionally on every
plan/apply.

**After:** Wrapped in `count = var.linux_ami_id == "" ? 1 : 0` — same
pin-or-resolve pattern already used for `data.aws_ssm_parameter.windows_2022_ami`.
Added `local.linux_ami_id` (pinned value wins, else resolves via the data
source) and `local.linux_ami_unpinned` flag for parity with the Windows
side, in case a future step wants to surface an "unpinned" warning in
`wazuh.sh` the way `windows-bootstrap.ps1.tpl` already does for Windows.

### `compute.tf`
**Before:** `aws_instance.wazuh.ami = data.aws_ami.amazon_linux.id` —
directly wired to the unconditional data source.

**After:** `ami = local.linux_ami_id`. Manager AMI now behaves identically
to the Windows AMI: stable across applies unless the pin is deliberately
changed.

**Flagged:**
- Because the supplied default is already a concrete AMI ID (not `""`),
  this is pinned immediately on next apply — there's no separate "resolve
  once, then copy into tfvars" step like there is for Windows. Worth
  knowing the two AMIs now follow *slightly* different pinning workflows
  (Windows: resolve-then-pin; Linux: pin-by-default) even though the
  underlying mechanism (`count` + fallback local) is identical.
- `local.linux_ami_unpinned` is defined but not yet consumed anywhere
  (no equivalent warning wired into `wazuh.sh` the way
  `windows-bootstrap.ps1.tpl` warns on `ami_unpinned`) — left available for
  parity, not yet acted on.
- This closes the "Amazon Linux AMI is still unpinned" item from the open
  items list below.

---

## Batch 8 — `userdata/windows.ps1`

### Rename-Computer / hostname finalization
**Before:** `Rename-Computer -NewName $NewHostname -Force` called in step 1
with no follow-up reboot anywhere in the script. `Rename-Computer` only
*stages* a hostname change in Windows — it doesn't take effect until the
next reboot. Flagged repeatedly across Batches 3–5 as an open item.

**Clarified while investigating the fix:** the Wazuh agent MSI install
(`WAZUH_AGENT_NAME="$NewHostname"`) was already passing the intended
hostname as a literal string, not reading it from `$env:COMPUTERNAME` — so
**agent enrollment in the Wazuh dashboard was never actually affected** by
the pending rename. The only real consequence of the missing reboot is
that the *OS-level* hostname (and therefore `win.system.computer` inside
raw Security/Sysmon event payloads, `hostname.exe`, RDP session titles)
stays on the EC2-generated name until something reboots the box — a
mismatch between "what the dashboard calls the agent" and "what the raw
event data says the computer is," not a broken enrollment.

**After:** Added a final step 9, `shutdown.exe /r /t 15 /c "..."`, run only
after every other provisioning step (agent install, Sysmon, log-format
pin, audit policy, active-response deployment, ssm-user creation, service
start, simulation-script permissioning) has completed. Guarded by
`if ($env:COMPUTERNAME -ne $NewHostname)` so re-runs against an
already-renamed host don't reboot needlessly. `shutdown.exe` used instead
of `Restart-Computer` to give a short grace window for the transcript log
to flush before the process is torn down.

**Flagged:**
- This delays "provisioning complete" by roughly 15–30 seconds for the
  reboot itself, and causes the agent's first connection to the manager to
  briefly drop and reconnect post-reboot — a cosmetic blip in the manager's
  agent list, not a functional issue, since Wazuh agent and Sysmon are
  already set to `Automatic` startup and come back up unattended.
- No re-entrancy guards were added elsewhere in the script for a
  mid-provisioning reboot — this was deliberately avoided in favor of
  putting the reboot last, after everything else is idempotent-checked
  (ssm-user creation, active-response deployment, log-format rebuild all
  already tolerate being run twice). If a step is ever added *after* step 9
  in the future, remember the reboot needs to stay last.
- Left as an explicit alternative, not implemented: dropping
  `Rename-Computer` entirely and accepting the EC2-generated OS hostname,
  which would avoid the reboot altogether at the cost of `win.system.computer`
  never matching the dashboard's agent name. Not adopted because the raw
  event data would then permanently disagree with the dashboard about the
  host's identity.
- This closes the `Rename-Computer` item from the open-items list below.

---

## Summary of things still worth a decision, not yet changed

- **Credential parsing from the install log via `grep`/`sed`** is still
  brittle across Wazuh versions — now warns instead of failing silently,
  but the underlying fragility (depends on exact log wording) is unchanged.
- **`ssm-user` ACL on Windows** — largely resolved: `windows.ps1` now
  creates the `ssm-user` local account explicitly at boot (mirroring
  `common.sh` on Linux) instead of relying on SSM Agent to lazily create it
  on first connection, so the ACL step should reliably succeed. Not fully
  verified: whether AWS SSM Agent actually respects a pre-existing
  `ssm-user` account rather than overwriting its password/group membership
  on first Session Manager connection — flag to confirm on first real
  login.
- **Active-response PID-kill logic** parses `newProcessId` as hex from the
  raw alert JSON but hasn't been validated against a live alert yet — flag
  for verification on first real run, not a known bug.
