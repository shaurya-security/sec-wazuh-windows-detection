<div align="center">

# 🛡️ RDP Brute-Force Detection & Response Lab

**Attack → Detect → Contain → Verify, on AWS, built entirely as code.**

![Terraform](https://img.shields.io/badge/IaC-Terraform_≥1.10-7B42BC?style=flat-square)
![Wazuh](https://img.shields.io/badge/SIEM-Wazuh_4.14-005571?style=flat-square)
![AWS](https://img.shields.io/badge/Cloud-AWS_ap--south--1-FF9900?style=flat-square)
![MITRE](https://img.shields.io/badge/MITRE-T1110_·_T1078-C0392B?style=flat-square)
![License](https://img.shields.io/badge/License-MIT-lightgrey?style=flat-square)

</div>

---

## 📌 Summary

A small SOC lab that simulates an RDP brute-force attack against a Windows Server, detects it with three custom [Wazuh](https://wazuh.com) correlation rules, and contains it by closing the exposed network path and disabling the compromised account.

The full loop was executed end to end. Proof is in [`evidence/`](evidence/README.md), and the run is written up as an incident report in [`docs/incident-report.md`](docs/incident-report.md).

| | |
|---|---|
| **Attack** | RDP brute force followed by a successful login ([T1110](https://attack.mitre.org/techniques/T1110/), [T1078](https://attack.mitre.org/techniques/T1078/)) |
| **Detection** | Rules `115200` → `115210` → `115220`: single failure, brute-force burst, success-after-failures |
| **Response** | Network containment (remove the Security Group ingress rule) + identity containment (disable the account) |
| **Infra** | VPC, 2× EC2, S3, IAM + SSM. Terraform with remote state. GitHub Actions + Checkov |

---

## 🔬 Results

| # | Step | Outcome | Evidence |
|:-:|---|---|:-:|
| 1 | Terraform allows RDP from one IP | Baseline exposure | [01](evidence/01-windows-sg-before.png) |
| 2 | 4 bad logins, then 1 good login | Rules **115200 → 115210 → 115220** fire (levels 13 → 13 → **14**) | [02](evidence/02-wazuh-correlation-alerts.png) |
| 3 | RDP ingress rule removed | Terraform definition has no ingress block | [03](evidence/03-windows-sg-after.png) |
| 4 | Probe port 3389 | `nc` times out (the actual proof the port is closed) | [04](evidence/04-verification-rdp-blocked.png) |
| 5 | Disable `FakeSOCUser` | `Enabled : False` | [05](evidence/05-verification-user-disabled.png) |

> **The alert that matters is `115220`.** A *successful* login that follows repeated failures from the same source separates "someone is knocking" from "someone got in."

---

## 🗺️ Architecture at a glance

```
 Operator workstation ──RDP 3389──▶ Windows Server 2022 ──Wazuh agent──▶ Wazuh manager + dashboard
 (runs the simulation)               (Security log 4624/4625)  1514/1515   (custom rules 115200/10/20)
```

Detailed diagrams, network rules, and design decisions: **[`docs/architecture.md`](docs/architecture.md)**

---

## 📂 Repository layout

| Path | Contents |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | Infrastructure, data flow, security boundaries |
| [`docs/incident-report.md`](docs/incident-report.md) | Timeline, containment and action items for the recorded run |
| [`docs/detection-rules.md`](docs/detection-rules.md) | How each rule works and why |
| [`docs/lessons-learned.md`](docs/lessons-learned.md) | What broke and what changed |
| [`terraform/bootstrap/`](terraform/bootstrap) | One-time setup: state bucket + userdata bucket |
| [`terraform/lab/`](terraform/lab) | The lab: VPC, EC2, IAM, Wazuh rules, provisioning scripts |
| [`simulation/`](simulation/soc-sim-brute-force.sh) | Attack script: 4× event 4625, then 1× event 4624 |
| [`evidence/`](evidence/README.md) | Annotated screenshots |
| [`.github/workflows/`](.github/workflows/terraform.yml) | CI: fmt, validate, Checkov |

---

## 🚀 Quick start

**Requirements**

- AWS account and credentials
- Terraform ≥ 1.10
- Linux workstation with `dnf` (the simulation installs FreeRDP if missing)
- Default region: `ap-south-1`

```bash
# 1 ─ One-time: create the S3 buckets (state + bootstrap scripts)
cd terraform/bootstrap
terraform init && terraform apply

# 2 ─ Build the lab (allow extra time: Wazuh installs at first boot)
cd ../lab
terraform init && terraform apply

# 3 ─ Get the dashboard URL
terraform output wazuh_dashboard_url
#     Admin password: /home/ssm-user/wazuh-passwords.txt on the manager
#     (connect with SSM Session Manager)

# 4 ─ Run the attack, then watch alerts appear in the dashboard
cd ../../simulation
./soc-sim-brute-force.sh

# 5 ─ Tear everything down
cd ../terraform/lab
terraform destroy
```

<details>
<summary><b>Forking this repo?</b></summary>

<br>

S3 bucket names are global, so they must be unique.

1. Change `aws_account_id_or_suffix` in `terraform/bootstrap/variables.tf`
2. Update the matching names in `terraform/lab/backend.tf` and `terraform/lab/variables.tf`

</details>

<details>
<summary><b>Pinning AMIs (recommended after first apply)</b></summary>

<br>

With an unpinned Windows AMI, a later `terraform apply` can replace the instance. After the first apply:

```bash
terraform output resolved_windows_ami_id   # sensitive output
# then set windows_ami_id in terraform.tfvars
```

</details>

---

## ⚠️ Safety notes

- **Lab only.** `FakeSOCUser` has a known password in the provisioning script, on purpose. Never reuse it anywhere real.
- **IP allow-listing.** RDP and the dashboard accept traffic only from the public IP of the machine that ran `terraform apply`. If your IP changes, re-apply.
- **Cost.** Two instances bill while running. Run `terraform destroy` when finished.

---

## 📄 License

[MIT](LICENSE)
