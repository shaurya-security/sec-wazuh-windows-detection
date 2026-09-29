# RDP Brute-Force Detection & Response Lab

**A SOC detection lab on AWS, built entirely as code.** It simulates an RDP brute-force attack against a Windows server, detects it with custom [Wazuh](https://wazuh.com) correlation rules mapped to MITRE ATT&CK, and contains it by removing the exposed firewall rule and disabling the compromised account. I ran the whole attack → detect → contain → verify loop end to end; the screenshots are in [`evidence/`](evidence/).

| | |
|---|---|
| **Attack simulated** | RDP brute force → successful login (MITRE [T1110](https://attack.mitre.org/techniques/T1110/), [T1078](https://attack.mitre.org/techniques/T1078/)) |
| **Detection** | 3 custom Wazuh rules: single failure → brute-force correlation → *success after failures* |
| **Response** | Network containment (Security Group change via Terraform) + account disablement |
| **Infra** | AWS (VPC, 2× EC2, S3, IAM/SSM), Terraform with remote state, GitHub Actions CI + Checkov |
| **Skills shown** | Detection engineering, SIEM rule authoring, IaC, incident response, AWS security basics |

## What happened when I ran it

| Step | Result | Proof |
|---|---|---|
| 1. Windows server exposed RDP to one IP | Baseline | [01](evidence/01-windows-sg-before.png) |
| 2. Ran 4 bad logins + 1 good login | Wazuh raised rules **115200 → 115210 → 115220** (level 13 → 13 → **14**) | [02](evidence/02-wazuh-correlation-alerts.png) |
| 3. Contained: removed the RDP ingress rule | Security Group has no inbound rules | [03](evidence/03-windows-sg-after.png) |
| 4. Verified the port is closed | `nc` to 3389 times out | [04](evidence/04-verification-rdp-blocked.png) |
| 5. Disabled the compromised account | `Enabled : False` | [05](evidence/05-verification-user-disabled.png) |

The alert that matters is **115220**: a *successful* login that follows repeated failures from the same source. That pattern is the difference between "someone is knocking" and "someone got in."

## Architecture (short version)

```
 operator workstation ──RDP 3389 (allow-listed IP only)──▶ Windows Server 2022 ──Wazuh agent──▶ Wazuh manager + dashboard
   (runs the simulation)                                    (Security log 4624/4625)             (custom rules 115200/10/20)
```

Full diagram and design decisions: [`docs/architecture.md`](docs/architecture.md).

## Repo map

| Path | What's there |
|---|---|
| [`docs/detection-rules.md`](docs/detection-rules.md) | How each rule works and why it's written that way |
| [`docs/lessons-learned.md`](docs/lessons-learned.md) | What broke, what I found, what I'd change |
| [`terraform/bootstrap/`](terraform/bootstrap) | One-time setup: state bucket + userdata bucket |
| [`terraform/lab/`](terraform/lab) | The lab itself (VPC, EC2, IAM, Wazuh rules, provisioning scripts) |
| [`simulation/`](simulation/soc-sim-brute-force.sh) | The attack script (generates 4× event 4625, 1× event 4624) |
| [`evidence/`](evidence/README.md) | Screenshots with captions |

## Quick start

**Prerequisites:** AWS account + credentials, Terraform ≥ 1.10, and a Linux workstation with `dnf` (the simulation script installs FreeRDP). Region defaults to `ap-south-1`.

```bash
# 1. One-time: create the S3 buckets (state + bootstrap scripts)
cd terraform/bootstrap && terraform init && terraform apply

# 2. Build the lab (allow extra time: the Wazuh install runs at first boot)
cd ../lab && terraform init && terraform apply

# 3. Open the dashboard (URL is a Terraform output; admin password is in
#    /home/ssm-user/wazuh-passwords.txt on the manager - connect with SSM Session Manager)
terraform output wazuh_dashboard_url

# 4. Run the attack, then watch the alerts appear
cd ../../simulation && ./soc-sim-brute-force.sh

# 5. Tear everything down
cd ../terraform/lab && terraform destroy
```

> If you fork this: bucket names must be globally unique. Change `aws_account_id_or_suffix` in `terraform/bootstrap/variables.tf`, and update the matching names in `terraform/lab/backend.tf` and `terraform/lab/variables.tf`.

## Safety notes

- **Lab only.** The simulated account (`FakeSOCUser`) has a known password in the provisioning script on purpose. Do not reuse anything here on a real system.
- RDP and the Wazuh dashboard are reachable **only from the public IP of the machine running `terraform apply`**. If your IP changes, re-apply.
- Instances cost money while running. Run `terraform destroy` when finished.

## License

[MIT](LICENSE)
