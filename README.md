# Wazuh Windows SOC Simulation

A hands-on SOC portfolio project: a Wazuh SIEM/XDR stack and a Windows Server endpoint, both provisioned on AWS via Terraform, used to generate real attack telemetry, write and tune custom detection rules, map alerts to MITRE ATT&CK, and (where working) trigger automated response — with every problem hit along the way documented rather than hidden.

> **Status: paused (temporarily on hold).** Telemetry, detection, and MITRE mapping are proven end-to-end for all three scenarios. Active Response integration and one correlation rule are still unresolved — see [Known Issues](#known-issues--next-steps). This is the first repo in a wider multi-platform SOC simulation series (see [Project Series](#project-series)).

---

## Table of Contents

- [Architecture](#architecture)
- [Attack Scenarios](#attack-scenarios)
- [Repository Structure](#repository-structure)
- [Infrastructure Details](#infrastructure-details)
- [Getting Started](#getting-started)
- [Known Issues / Next Steps](#known-issues--next-steps)
- [Detection Engineering Highlights](#detection-engineering-highlights)
- [Project Series](#project-series)
- [Documentation](#documentation)
- [Disclaimer](#disclaimer)

---

## Architecture

Everything runs on AWS, provisioned entirely through Terraform + EC2 user-data (no manual clicking through consoles).

```
                              Internet
                                 │
                          ┌──────┴──────┐
                          │  Wazuh EC2  │  Amazon Linux 2023
                          │ (all-in-one)│  m7i-flex.large
                          │  manager +  │  10.0.1.x
                          │  indexer +  │
                          │  dashboard  │
                          └──────┬──────┘
                                 │ 1514 (agent) / 1515 (enrollment) / 55000 (API)
                          ┌──────┴──────┐
                          │ Windows EC2 │  Windows Server 2022
                          │ (Wazuh      │  c7i-flex.large
                          │  agent +    │  10.0.1.x
                          │  Sysmon)    │
                          └─────────────┘
                                 │
                          AWS SSM Session Manager
                          (no RDP/SSH exposed)
```

**Key design choices:**

- **No inbound RDP/SSH** — all administration goes through **SSM Session Manager**. The Wazuh dashboard (443) is the only port opened to the internet, and it's locked to the operator's current public IP (fetched dynamically at `terraform apply` time).
- **Security-group-to-security-group references** for agent traffic (1514/1515/55000), not CIDR blocks — the Windows SG can talk to the Wazuh SG and nothing else can.
- **Provisioning scripts live in S3**, not inlined into Terraform's `user_data` — sidesteps the 16 KB user-data limit and Terraform's `${...}` interpolation footguns, and lets scripts be edited/tested independently of `terraform apply`.
- **Sysmon uses the SwiftOnSecurity community config** (with a fallback to Sysmon defaults) for telemetry that's actually useful for detection engineering, not just noise.
- **Command-line auditing, PowerShell Script Block/Module Logging, and Logon/Process Creation audit policies** are all enabled via registry/`auditpol` as part of endpoint bootstrap — this is what makes the detections below possible in the first place.

Full architecture rationale, instance-sizing trade-offs, and every infra bug hit (IAM propagation races, `templatefile()` escaping gotchas, EC2Launch v2 silently discarding malformed user-data, dashboard crash loops, etc.) are written up in [`project_infra_notes.md`](./project_infra_notes.md).

---

## Attack Scenarios

Three scenarios, chosen deliberately over a larger "intrusion chain" style lineup — a small number of fully verified, well-documented scenarios is more defensible in an interview than a large number of shallow ones.

| # | Scenario | Attack | Primary Telemetry | MITRE ATT&CK | Response |
|---|---|---|---|---|---|
| 1 | Suspicious PowerShell | Encoded/obfuscated PowerShell execution (`-EncodedCommand`, `-ExecutionPolicy Bypass`) | Windows Security 4688 (command-line auditing enabled) + Sysmon Event ID 1 | [T1059.001](https://attack.mitre.org/techniques/T1059/001/) | Terminate process (Active Response) — **unresolved, see below** |
| 2 | Failed logon / brute-force | Repeated failed Windows logons | Security 4625 | [T1110](https://attack.mitre.org/techniques/T1110/) | Block source (Active Response) |
| 3 | Scheduled task persistence | `schtasks /create` | Security 4688 + 4698 (correlated) | [T1053.005](https://attack.mitre.org/techniques/T1053/005/) | Remove task, verify absence — **correlation rule unresolved, see below** |

**Scenario 1 also includes a true-positive / false-positive split**, to avoid the naive "PowerShell = malicious" framing:
- **1A (false positive):** benign admin commands (`Get-Service`, `Get-Process`) — should *not* trigger a high-severity alert.
- **1B (true positive):** `-EncodedCommand` / `-ExecutionPolicy Bypass` usage — high-severity alert, MITRE-mapped, response triggered.

Detection rule design, tuning history, and why each scenario is built the way it is are in [`simulation_notes.md`](./simulation_notes.md).

---

## Repository Structure

```
wazuh-windows-soc-simulation/
├── README.md                    # you are here
├── simulation_notes.md          # detection engineering: rules, tuning, problems & fixes
├── project_infra_notes.md       # infrastructure: architecture, AWS/Terraform problems & fixes
├── terraform-bootstrap/         # one-time bootstrap: remote state S3 bucket
│   ├── backend.tf
│   ├── provider.tf
│   ├── s3.tf
│   ├── variables.tf
│   └── outputs.tf
└── terraform-lab/                # main lab: VPC, EC2, IAM, security groups
    ├── main.tf
    ├── vpc.tf
    ├── compute.tf                # Wazuh + Windows EC2 instances
    ├── iam.tf                    # SSM instance profile, S3 read policy, IAM propagation delay
    ├── data.tf
    ├── locals.tf
    ├── s3.tf                     # userdata bucket objects
    ├── output.tf
    ├── variables.tf
    ├── backend.tf
    ├── .checkov.yaml              # documented, intentional Checkov skips
    ├── .github/workflows/terraform.yml   # CI: fmt, validate, Checkov
    └── userdata/
        ├── common.sh              # generic Linux comfort setup (packages, shell config)
        ├── s3-bootstrap.sh.tpl    # tiny wrapper: pulls & runs the real script from S3
        ├── wazuh.sh               # Wazuh all-in-one install + config
        ├── windows-bootstrap.ps1.tpl  # tiny wrapper for the Windows side
        └── windows.ps1            # Wazuh agent, Sysmon, audit policy, logging setup
```

`terraform-bootstrap/` is applied once, standalone, to create the S3 backend for Terraform state before `terraform-lab/` is ever run.

---

## Infrastructure Details

| Component | Choice | Why |
|---|---|---|
| Region | `ap-south-1` | Lowest latency to operator |
| Wazuh instance | `m7i-flex.large` (2 vCPU / 8 GiB) | OpenSearch/indexer is memory-bound, not CPU-bound; Free Tier instance-type restriction ruled out `t3.medium` and ARM (`t4g.*`) doesn't match the x86_64 AMI |
| Windows instance | `c7i-flex.large` (`t3.medium` when available) | Practical fallback under the same Free Tier account restriction |
| Root volume | 50 GB gp3, encrypted | Wazuh all-in-one (indexer + manager + dashboard) needs headroom |
| Access | AWS SSM Session Manager only | No bastion host, no open inbound SSH/RDP |
| State backend | S3 (`terraform-bootstrap`), SSE-S3 encrypted, public access blocked | Standard remote-state hygiene |
| CI | GitHub Actions — `terraform fmt`, `terraform validate`, Checkov (non-blocking) | Catches drift/syntax issues before apply; Checkov exceptions are documented in `.checkov.yaml`, not silently ignored |

Cost discipline: `m7i-flex.large` / `c7i-flex.large` against a fixed ~$160 cloud credit budget. Instances are not left running 24/7 — the lifecycle is **build → run simulation → collect evidence → destroy/stop → update docs → next scenario**, to avoid idle burn.

---

## Getting Started

> This lab provisions real AWS resources (EC2, VPC, IAM, S3) and will incur cost. Review `terraform plan` output before applying, and remember to `terraform destroy` when done.

**Prerequisites:** an AWS account with programmatic access, [Terraform](https://developer.hashicorp.com/terraform/downloads) ≥ 1.x, and the AWS CLI configured.

```bash
# 1. One-time: create the remote state backend
cd terraform-bootstrap
terraform init
terraform apply

# 2. Deploy the lab (Wazuh manager + Windows endpoint)
cd ../terraform-lab
terraform init
terraform plan
terraform apply
```

After apply completes:

1. Grab the Wazuh dashboard's public IP and admin credentials — see the "Wazuh Dashboard Notes" section of [`project_infra_notes.md`](./project_infra_notes.md) for where credentials land (`/root/wazuh-install-files.tar`, or the install log as a fallback) and why the self-signed cert warning is expected.
2. Confirm the Windows agent shows **Active** in the dashboard.
3. Reproduce a scenario from [`simulation_notes.md`](./simulation_notes.md) on the Windows endpoint (e.g., run an encoded PowerShell command) and watch the corresponding alert fire in Wazuh.
4. When finished, tear the lab down:

```bash
cd terraform-lab
terraform destroy
```

---

## Known Issues / Next Steps

Documented honestly rather than hidden, since debugging methodology is as much a part of this portfolio project as the working parts:

- **Active Response not reaching the Windows agent.** The response binary is present, admin rights are confirmed, but `active-responses.log` stays empty and manual invocation does nothing. Prime suspect: the Active Response block may have been appended as a second, structurally invalid `<ossec_config>` root element in `ossec.conf`. Parked after ~2 days of debugging to avoid diminishing returns under fatigue — the detection/telemetry layer is proven and doesn't depend on this.
- **Scenario 3's correlation rule (level 13, ID `115310`) doesn't fire**, even though its base rule (`115300`, the `schtasks.exe /create` detection) fires reliably. Root cause not yet isolated.
- **Formal false-positive test for the PowerShell rule** (benign `Get-Service` / `Get-Process`) hasn't been executed against the final tuned rule yet.

See [`simulation_notes.md`](./simulation_notes.md) for full technical detail and the reasoning behind each decision.

---

## Detection Engineering Highlights

A few things worth calling out for anyone reviewing the rule logic in [`simulation_notes.md`](./simulation_notes.md):

- **Telemetry-first, rule-second methodology.** Every custom rule was written against the actual Wazuh alert JSON produced by a real, generated event — not against guessed decoder field names or assumed SIDs.
- **Confidence-tiered PowerShell detection.** An early rule fired at high severity on weak indicators alone (e.g., `-NoProfile`), which is unrealistically noisy. The final rule treats `-EncodedCommand` / `-ExecutionPolicy Bypass` as high-confidence and keeps weaker flags as supporting signals only.
- **Two independent telemetry paths for one activity.** PowerShell execution is detected via both native Windows Security 4688 (with command-line auditing) and Sysmon Event ID 1 — deliberately kept as two paths rather than collapsed into one, to demonstrate both auditing mechanisms working together.
- **Correlation over single broad rules.** The brute-force (Scenario 2) and scheduled-task (Scenario 3) detections both use frequency/timeframe or two-stage correlation rather than one wide-net rule, producing more defensible high-confidence alerts.

---

## Project Series

This is the first entry in a planned platform-neutral SOC simulation portfolio:

| Repo | Lineup | Status |
|---|---|---|
| `wazuh-windows-soc-simulation` | 1st | **This repo — paused temporarily** |
| `wazuh-linux-soc-simulation` | 2nd | Upcoming |
| `wazuh-aws-soc-simulation` | 3rd | Planned |
| `splunk-windows-soc-simulation` | 4th | Planned |
| `splunk-linux-soc-simulation` | 5th | Planned |
| `splunk-aws-soc-simulation` | 6th | Planned |

Each repo follows the same conceptual shape: **attack → telemetry generation → detection → investigation → MITRE mapping → containment/remediation → verification → evidence.** Splunk repos are planned to demonstrate genuinely different detection engineering (SPL, different data sources) rather than reproducing the same attacks on a different SIEM.

---

## Documentation

| File | Contents |
|---|---|
| [`simulation_notes.md`](./simulation_notes.md) | Detection engineering: scope/philosophy, scenario design, rule iteration history, problems and fixes, verified-working checklist |
| [`project_infra_notes.md`](./project_infra_notes.md) | Infrastructure: architecture decisions, instance sizing, Terraform/user-data evolution, every infra bug hit and its fix, Windows telemetry baseline, dashboard notes |

---

## Disclaimer

This lab is built for **defensive security education and portfolio demonstration only**. All attacks (encoded PowerShell, brute-force logons, scheduled-task persistence) are simulated against infrastructure the author owns and controls. Nothing here is intended for use against systems you don't have explicit authorization to test.
