# Evidence

Five screenshots that show the lab working end to end. Each one answers a single question.

| # | File | What it proves |
|---|---|---|
| 1 | ![before](01-windows-sg-before.png)<br>`01-windows-sg-before.png` | **Before:** the Windows server's Security Group allows RDP (3389) from exactly one address, the operator's. This is the exposure the attack uses. |
| 2 | ![alerts](02-wazuh-correlation-alerts.png)<br>`02-wazuh-correlation-alerts.png` | **Detection works:** Wazuh raised rule 115200 (×3), 115210 (brute force) and 115220 (login after failures, level 14) for agent `WIN-SOC-NODE01`, mapped to T1110 / T1078. |
| 3 | ![after](03-windows-sg-after.png)<br>`03-windows-sg-after.png` | **Containment (network):** the RDP ingress block has been removed. The Security Group now has only an egress rule. |
| 4 | ![blocked](04-verification-rdp-blocked.png)<br>`04-verification-rdp-blocked.png` | **Verified:** a TCP probe to port 3389 now times out. The fix is real, not assumed. |
| 5 | ![disabled](05-verification-user-disabled.png)<br>`05-verification-user-disabled.png` | **Containment (identity):** the compromised account `FakeSOCUser` is disabled (`Enabled : False`). |

## Reproducing the containment steps

```bash
# Network: delete the `ingress { ... 3389 ... }` block in terraform/lab/vpc.tf, then
cd terraform/lab && terraform apply

# Verify the port is closed (expect a timeout)
nc -vz -w 5 "$(terraform output -raw windows_public_ip)" 3389
```

```powershell
# Identity: run on the Windows endpoint (via SSM Session Manager)
Disable-LocalUser -Name "FakeSOCUser"
Get-LocalUser -Name "FakeSOCUser" | Select-Object Name, Enabled
```

## Note on the IP addresses in the images

The screenshots show two public IPs: the operator workstation's (in the Wazuh alerts) and the Windows instance's (in the `nc` output). The instance address is ephemeral, but the workstation address is your real ISP address. Consider blurring it before publishing.
