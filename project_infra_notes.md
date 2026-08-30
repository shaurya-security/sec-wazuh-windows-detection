# Windows SOC Lab — Infra Notes

Personal notes from building a Wazuh + Windows Server SOC simulation lab on AWS with Terraform. Covers the architecture decisions made along the way and every non-obvious problem hit (and how it got fixed), so I can revisit the reasoning later without re-deriving it.

---

## 1. Architecture Overview

**Stack:** Terraform → AWS (VPC, EC2) → Wazuh all-in-one (manager + indexer + dashboard) on Amazon Linux 2023 → Windows Server 2022 endpoint running the Wazuh agent.

```
                    Internet
                       │
                ┌──────┴──────┐
                │  Wazuh EC2  │  (Amazon Linux 2023, all-in-one)
                │  10.0.1.x   │
                └──────┬──────┘
                       │  1514 (agent) / 1515 (enrollment) / 55000 (API)
                ┌──────┴──────┐
                │ Windows EC2 │  (Windows Server 2022, Wazuh agent)
                │  10.0.1.x   │
                └─────────────┘
                       │
                      SSM (no RDP exposed)
```

**Key early decisions:**
- Single public subnet, single VPC, `ap-south-1`.
- No RDP/SSH exposed — administration done entirely through **SSM Session Manager** (instance profile with `AmazonSSMManagedInstanceCore`). Removes the need to manage a bastion or open inbound ports for shell access.
- Wazuh dashboard (443) is the only inbound rule scoped to a specific IP (`data.http.my_public_ip` fetched dynamically at `terraform apply` time via `https://ipv4.icanhazip.com`).
- Agent traffic (1514/1515/55000) is restricted via **security-group-to-security-group** references, not CIDR blocks — Windows SG → Wazuh SG only, instead of opening those ports to 0.0.0.0/0.
- Agent-to-manager communication uses **private IPs only**. No reason to route agent traffic out to the internet and back.

**Instance sizing (the interesting trade-off):**
- Wazuh all-in-one (manager + indexer + dashboard) is memory-hungry — indexer is the dominant cost. Wazuh's own docs list 4 GB min for the server and 4–8 GB for the dashboard.
- AWS account had a **Free Tier instance-type restriction** (`InvalidParameterCombination: not eligible for Free Tier`), which ruled out `t3.medium`.
- `describe-instance-types --filters Name=free-tier-eligible,Values=true` showed the allowed set: `t4g.small`, `t4g.micro`, `t3.micro`, `t3.small`, `c7i-flex.large`, `m7i-flex.large`.
- `t4g.*` was rejected immediately — it's Graviton/ARM64, and the AMI filter (`al2023-ami-*-x86_64`) is x86_64 only. Mixing them would just create a new class of problem.
- Between `c7i-flex.large` (2 vCPU / 4 GiB) and `m7i-flex.large` (2 vCPU / 8 GiB): picked **m7i-flex.large**. The workload isn't CPU-bound, it's memory-bound (OpenSearch/indexer), so the extra RAM mattered more than the compute-optimized profile.
- Windows endpoint: `t3.medium` when available, `c7i-flex.large` as the practical fallback under the Free Tier constraint.

---

## 2. Bootstrap / Userdata Design Evolution

This went through a few iterations, each one fixing a real limitation of the last.

**v1 — inline scripts via `templatefile()`**
Concatenating `common.sh` + `wazuh.sh` directly into `user_data` via `join()` + `templatefile()`. Worked, but every Terraform-managed variable meant learning `$` vs `$$` escaping (see §3), and large scripts bump into EC2's 16 KB user-data limit.

**v2 — move provisioning to S3**
Store `common.sh`, `wazuh.sh`, `windows.ps1` in a private S3 bucket; `user_data` becomes a tiny bootstrap wrapper that downloads and executes them.

Why this is better:
- No more escaping `${VAR}` for bash/PowerShell — those files are downloaded and run as-is, not put through Terraform's template engine.
- No 16 KB user-data ceiling.
- Scripts can be tested/edited independently of `terraform apply`.
- Reusable: `common.sh` (generic Linux comfort setup — packages, Starship, `bat`, aliases) is now decoupled from `wazuh.sh` (workload-specific) and `windows.ps1` (Windows-specific).

Final bucket layout (flat, no prefix needed since the bucket is dedicated to userdata):
```
s3://shaurya-terraform-userdata-2026/
├── common.sh
├── wazuh.sh
└── windows.ps1
```

**IAM for S3 access:** initially split into per-file resource ARNs (`.../common.sh`, `.../wazuh.sh`), which is fragile — a filename mismatch (`.tpl` vs no `.tpl`) silently breaks a specific script with `AccessDenied`. Consolidated into a single wildcard policy (`arn:.../bucket-name/*`) with `s3:GetObject`, plus `s3:ListBucket` on the bucket ARN itself (needed because `aws s3 cp` does a HEAD/list call, not just GetObject).

**Cross-account note (came up when thinking about open-sourcing this):** hardcoding a bucket name in the repo is safe to publish. If someone else clones and runs the Terraform, their EC2 instance profile gets IAM permission to *try* `s3:GetObject` against the same bucket name — but AWS evaluates both the caller's IAM policy *and* the resource owner's bucket policy. Without an explicit cross-account bucket policy granting their account, it's `AccessDenied (403)` by default. S3 bucket names are also globally unique, so if the original account still owns the name, `terraform apply` for someone else would fail outright on `aws_s3_object`/`aws_s3_bucket` creation anyway. For genuine reuse, parameterize the bucket name as a Terraform variable.

**Terraform not detecting S3 content changes:** editing `wazuh.sh` on S3 doesn't change the *local* `.tpl` file Terraform hashes for `user_data`, so `terraform plan` sees zero diff even with `user_data_replace_on_change = true`. Fixed by managing the S3 objects as `aws_s3_object` resources with `etag = filemd5(...)`, and injecting the same `filemd5()` hash into the bootstrap template as a comment:
```hcl
user_data = templatefile("...", {
  common_hash = filemd5("${path.module}/userdata/common.sh")
  wazuh_hash  = filemd5("${path.module}/userdata/wazuh.sh")
})
```
```bash
# common.sh hash: ${common_hash}
# wazuh.sh hash:   ${wazuh_hash}
```
Now editing the script changes the rendered `user_data` string, which triggers instance replacement. (Also hit this exact bug again on the Windows side — a hash variable was declared in the `templatefile()` map but never actually referenced inside the `.tpl`, so it had zero effect. The variable has to appear somewhere in the rendered file, even just as a comment, to matter.)

**Relative path resolution gotcha:** `templatefile("${path.module}/../../private/x")` resolves relative to the *module*, not the shell's cwd. Miscounting `../` levels gives a "no file exists" error that looks like a permissions problem but is just a wrong path depth.

---

## 3. Terraform Templating Gotchas ($ vs $$)

This ate a lot of debugging time and is worth having straight:

| Function | Behavior on `${...}` |
|---|---|
| `file(path)` | Passed through literally — **no** Terraform interpolation. Shell/PowerShell variables need no escaping. |
| `templatefile(path, vars)` | **Interpolates** every `${...}` it sees against the `vars` map. Anything meant to survive as a literal shell/PowerShell variable must be written `$${...}`. |

Consequences hit in practice:
- A bash script moved from `file()` to `templatefile()` broke because pre-existing `${VERSION}` shell variables got treated as missing Terraform vars (`Invalid value for "vars" parameter: vars map does not contain key "BOLD"`).
- `templatefile()` requires **both** arguments — `templatefile(path)` alone is invalid; use `templatefile(path, {})` or switch to `file(path)` if there's nothing to interpolate.
- PowerShell has its own extra trap: `$$` is not a valid PowerShell token for defining a variable (`$$Bucket = ...` → `Unexpected token 'Bucket'`). The fix was to **not** escape PowerShell locals at all and instead scope the templating narrowly — only the one Terraform-supplied value (`${wazuh_manager_ip}`) goes through interpolation; every other `$Variable` in the `.ps1.tpl` is a plain, unescaped PowerShell variable that Terraform never touches because it isn't named in the vars map... which only works because none of those names collide with the vars map. (Escaping isn't needed unless the exact string `${name}` appears and `name` isn't a supplied variable — then it must be `$${name}` or Terraform errors, but if it *is* meant to be interpolated, leave it as `${name}`.)
- Python has the same class of problem only if using `string.Template` (`${name}` syntax) — f-strings and `.format()` use plain `{name}`, which Terraform ignores entirely.

**Rule of thumb:** `file()` for scripts with zero Terraform variables (simplest, no escaping surprises). `templatefile()` only when a value genuinely needs to come from Terraform state/resources (e.g., `aws_instance.wazuh.private_ip`).

---

## 4. Problems & Fixes (chronological-ish)

### IAM eventual consistency / race condition
Terraform reports the IAM role, instance profile, and S3 policy as "created" the moment the API call succeeds, but IAM permissions propagate to EC2's IMDS asynchronously. An instance launched ~11 seconds after its instance profile was created booted before the S3 read permission had propagated — `aws s3 cp` failed, `set -euo pipefail` killed the bootstrap instantly, and the instance came up with nothing installed.

**Fix:** `hashicorp/time` provider's `time_sleep` resource, with an explicit `depends_on` chain, inserted between IAM resource creation and instance launch:
```hcl
resource "time_sleep" "wait_for_iam" {
  create_duration = "30s"
  depends_on = [
    aws_iam_instance_profile.ec2_ssm,
    aws_iam_role_policy.userdata_s3_read,
    aws_iam_role_policy_attachment.ec2_ssm
  ]
}
```
`aws_instance.wazuh` then depends on `time_sleep.wait_for_iam`. Also added a retry loop around the `aws s3 cp` calls in the bootstrap script itself as a second layer of defense.

### `dnf install curl` conflicts with `curl-minimal` (Amazon Linux 2023)
AL2023 ships `curl-minimal` pre-installed; explicitly installing `curl` conflicts with it (`package curl-minimal ... conflicts with curl provided by curl-...`). Fix: drop `curl` from the package list (minimal already provides the binary), or use `dnf install -y --allowerasing curl` if the full package is genuinely needed.

### `ssm-user` sudo lockout (user-creation race with SSM Agent)
SSM Agent normally creates `ssm-user` on first connect and grants it passwordless sudo via `/etc/sudoers.d/ssm-agent-users`. The bootstrap script ran `useradd -m ssm-user` *itself* (to pre-create the home directory for Starship/dotfiles setup) before SSM Agent got to it — so SSM's own user-init step was skipped, and `ssm-user` ended up with no sudo rights and no way to grant itself any (can't write to `/etc/sudoers.d/` without... sudo).

**Fix (going forward):** write the sudoers rule explicitly, immediately after `useradd`, regardless of who "should" have created the user:
```bash
if ! id "ssm-user" &>/dev/null; then
    useradd -m -s /bin/bash "ssm-user"
fi
echo "ssm-user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ssm-agent-users
chmod 0440 /etc/sudoers.d/ssm-agent-users
```
**Fix (for an already-broken running instance):** can't fix from inside the locked-out session — has to come from outside as root, via `aws ssm send-command` with `AWS-RunShellScript` (which executes as root, unlike an interactive SSM session which drops into `ssm-user`).

### Mangled shell variable in `common.sh` (`v2449{VERSION}`)
A `$${VERSION}` inside a file that was actually being loaded with `file()`, not `templatefile()`, got passed through *unprocessed* by Terraform but then the surrounding context (a separate bug) mangled it. Root lesson re-confirmed: **know which Terraform function is loading the file** before deciding whether `$` needs escaping — `file()` never interpolates, so `$${...}` in a `file()`-loaded script is simply wrong (produces literal `$${...}` instead of `${...}`).

### `grep: binary file matches` on Wazuh's install log
`/var/log/wazuh-install.log` contains non-text bytes (progress-bar control characters from the package manager), so plain `grep` refuses to search it as text. Fix: `grep -a` forces text-mode matching regardless of detected binary content.

### `grep: unrecognized option '--- Summary ---'`
`grep` interprets a search pattern starting with `-` as a flag. Fix: use `-e` to mark the following argument as the pattern explicitly (`grep -a -A 3 -e "--- Summary ---" file`), or prefix with `--`.

### Wazuh install script deletes its own credentials archive
`wazuh-install.sh -a` deletes `/root/wazuh-install-files.tar` right after finishing, as a security measure. A script that waits and polls for that file *after* installation has already completed will never see it — it's already gone.

**Fix:** extract credentials from the tar *immediately* as part of the same script run, right after `wazuh-install.sh -a` returns — no polling needed, since the installer runs synchronously and blocks until done. As a fallback for cases where the tar is already gone (e.g., manual re-run), fall back to grepping the install log directly: `grep -a -A 3 -e "--- Summary ---" /var/log/wazuh-install.log`.

### `wazuh-dashboard` crash-looping: `Unknown configuration key(s): "dateFormat:tz"`
Tried to force the dashboard's displayed timezone to IST by appending `dateFormat:tz: Asia/Kolkata` directly into `/etc/wazuh-dashboard/opensearch_dashboards.yml`. This key is **not** a valid server-side YAML config for OpenSearch Dashboards — it's a *user preference* stored in a saved-object index, not a schema-validated startup setting. The dashboard's strict config validator rejected it and exited with status 64 on every single restart attempt (systemd kept retrying every ~3 seconds, in a permanent crash loop — port 443 never opened, no amount of security-group or `server.host` fiddling could have fixed it, because the process was never staying up long enough to bind).

**Fix:** never touch that key in the YAML. Set it through the dashboard's REST API instead, after waiting for the API to actually come up:
```bash
curl -s -k -X POST "https://localhost:443/api/opensearch-dashboards/settings" \
  -H "osd-xsrf: true" -H "Content-Type: application/json" \
  -u "admin:${PASS}" \
  -d '{"changes":{"dateFormat:tz":"Asia/Kolkata"}}'
```
(or set it manually once via Dashboard → Stack Management → Advanced Settings). This is a good general lesson: a config file accepting arbitrary keys doesn't mean the *service* will accept them at boot — strict schema validation can turn a cosmetic setting into a full outage.

### Windows EC2Launch v2 silently ignoring PowerShell user-data
`user_data` for the Windows instance started directly with `$ErrorActionPreference = "Stop"`. EC2Launch v2 tries to parse user-data as YAML/JSON config first; a bare PowerShell script fails that parse and gets silently discarded (`User data format: unrecognized`) — nothing runs, no error surfaces anywhere obvious.

**Fix:** wrap the entire script body in `<powershell>...</powershell>` tags so EC2Launch recognizes it as a script to execute rather than a config document.

### PowerShell script erroring out on `Invoke-WebRequest` progress output
Once the `<powershell>` wrapper was in place, the script still failed (`Error: Script produced error output`) purely because `Invoke-WebRequest`'s progress bar writes to a stream that `$ErrorActionPreference = "Stop"` treats as fatal. Fix: `$ProgressPreference = "SilentlyContinue"` at the top of the script, plus `-UseBasicParsing` on the request itself.

### Wrong Wazuh manager IP given to the agent installer
Manually installed the Windows agent with `WAZUH_MANAGER` set to the **Windows instance's own private IP** instead of the Wazuh server's — a straight copy-paste mixup between two similar-looking `10.0.1.x` addresses from `terraform output`. Symptom: agent service starts fine, but the dashboard shows "No agents were added to the manager" because the agent was trying to talk to itself. Fix: edit `ossec.conf`'s `<address>` directly, or reinstall with the correct manager IP, then confirm with `Test-NetConnection <manager-ip> -Port 1514`.

### Duplicate/orphaned agents after instance replacement
Destroying and recreating the Windows EC2 (triggered by a `user_data` hash change) doesn't unregister the old agent from the Wazuh manager's agent database — the manager just accumulates a new agent ID for the new instance while the old one sits there stale. Fix: `sudo /var/ossec/bin/manage_agents -r <old-id>` on the manager to clean up before/after each replacement, and prefer setting an explicit, stable `WAZUH_AGENT_NAME` at install time rather than relying on the auto-generated EC2 hostname (`EC2AMAZ-XXXXXXX`), which also changes on every instance replacement.

### `Rename-Computer` doesn't take effect until reboot
Tried to give the Windows host a clean name (`WIN-SOC-NODE01` instead of the ugly auto-generated `EC2AMAZ-XXXXXXX`) via `Rename-Computer`, then immediately installed the Wazuh agent in the same script run. Windows doesn't actually apply the new computer name to the active session until a reboot, so the Wazuh MSI installer still read the *old* hostname and registered under that. Fix: don't depend on the OS hostname for the agent's identity at all — pass `WAZUH_AGENT_NAME="<desired-name>"` explicitly to the MSI installer's arguments, which takes effect immediately regardless of the pending rename/reboot.

### Free-tier instance-type rejection
`RunInstances` failed with `InvalidParameterCombination: not eligible for Free Tier` for `t3.medium`. This is an **AWS account-level restriction**, not a Terraform or code problem — confirmed the actually-permitted set via `aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true`, and picked from that list rather than guessing (see §1 for the sizing reasoning).

---

## 5. Windows Telemetry Baseline

Configured via `auditpol` + registry keys, applied through the Windows bootstrap script:

```powershell
auditpol /set /subcategory:"Logon" /success:enable /failure:enable
auditpol /set /subcategory:"Process Creation" /success:enable

# PowerShell Script Block Logging
New-Item -Path "HKLM:\Software\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -Force
Set-ItemProperty ... -Name "EnableScriptBlockLogging" -Value 1

# PowerShell Module Logging
New-Item -Path "HKLM:\Software\Policies\Microsoft\Windows\PowerShell\ModuleLogging" -Force
Set-ItemProperty ... -Name "EnableModuleLogging" -Value 1
```

**Event IDs confirmed flowing into Wazuh, end-to-end:**
| Event ID | Meaning | Wazuh rule example |
|---|---|---|
| 4624 | Successful logon | — |
| 4625 | Failed logon | Rule 60122, MITRE T1531 (Account Access Removal) |
| 4688 | Process created | — |
| 4720 / 4722 | Account created / enabled | — |
| 4732 | Member added to a security-enabled local group | Rule 60154, MITRE T1484 (Domain Policy Modification), tactics: Defense Evasion / Privilege Escalation |
| 4738 | User account changed | — |

**Generating a controlled 4625 (failed logon) without knowing any real passwords:** `runas` behaves badly over an SSM interactive session (`RUNAS ERROR: Unable to acquire user password`). Reliable alternative — authenticate against the loopback SMB share with a deliberately wrong password:
```powershell
net use \\127.0.0.1\IPC$ /user:.\soc-test "WrongPassword123!"
```
Repeated in a loop, this produces genuine `4625` events with `logonType: 3` (network), `authenticationPackageName: NTLM`, visible in Wazuh within seconds. Worth noting for writeups: this is a **local loopback simulation** of the auth-failure telemetry, not a real remote brute-force — the source IP will show `127.0.0.1`, so it shouldn't be framed as an actual network attack.

**Verifying the agent is alive and correctly enrolled, end to end:**
```powershell
Get-Service -Name "wazuh" | Select-Object Status, StartType
Get-Content "C:\Program Files (x86)\ossec-agent\ossec.conf" | Select-String "<address>"
Get-Content "C:\Program Files (x86)\ossec-agent\client.keys"
```
```bash
sudo /var/ossec/bin/agent_control -l   # on the manager
```

---

## 6. Wazuh Dashboard Notes

- Default all-in-one install generates a random `admin` password — never `admin:admin`. Credentials live in `/root/wazuh-install-files.tar` briefly, then get deleted; the install log (`/var/log/wazuh-install.log`) is the fallback source of truth if the tar is missed.
- Self-signed certificate is expected and correct behavior for a private lab — the browser warning is not evidence of a broken cert, just an untrusted (self-signed) CA. Each fresh install generates its own unique root CA, node certs, and passwords — nothing is shared across installs, by design (security isolation).
- Dashboard install genuinely takes longer than manager/indexer (285 MB RPM, ~955 MB installed) — seeing `Unit wazuh-dashboard.service could not be found` right after manager/indexer come up is normal sequencing, not a failure, as long as the install log eventually shows `wazuh-dashboard service started`.
- Dashboard binds to `server.host` from its YAML config — confirm `0.0.0.0`, not `127.0.0.1`/`localhost`, if it's meant to be reachable from outside the instance.
- HTTPS only — there is no unencrypted listener on 80. A browser test needs the explicit `https://` scheme.

---

## 7. Repo / Portfolio Structure

Planned as a **platform-neutral simulation portfolio** rather than a single Wazuh/Windows repo, so it can grow to cover Linux and AWS (CloudTrail, VPC Flow Logs) simulations later without renaming anything:

```
soc-attack-simulations/
├── terraform/
├── linux/       # 2-3 attack + remediation simulations
├── windows/     # 2-3 attack + remediation simulations
├── aws/         # 2-3 attack + remediation simulations (CloudTrail, VPC Flow Logs)
└── docs/
```

Each simulation follows the same conceptual shape: **attack → telemetry generation → detection → investigation → MITRE mapping → containment/remediation → verification → evidence.** Chosen over naming the repo after Wazuh or Windows specifically, since those are implementation details rather than the actual point of the portfolio.
