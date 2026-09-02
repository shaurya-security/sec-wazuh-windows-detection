# Wazuh Windows SOC Simulation


## Rough planning for Hands on SOC simulations. 
Every Thing will be Provisioned on AWS Instances through terraform and UserData

```
                    SOC Portfolio
                         │
          ┌──────────────┴──────────────┐
          │                             │
       Wazuh                         Splunk
          │                             │
   ┌──────┼──────┐                ┌─────┼─────┐
 Linux  Windows  AWS             Linux Windows AWS
   │       │       │                │      │     │
  2–3     2–3     2–3              2–3    2–3   2–3
scenarios each                   DIFFERENT scenarios
```
---

## Planned Repo Names

| Repo Names | Lineup | Current Status |
|---|---|---|
| `wazuh-windows-soc-simulation` | 1st | Dropping Temprorily Due burnout from debugging local rules and active response configs |
| `wazuh-linux-soc-simulation` | 2nd | Upcoming |
| `wazuh-aws-soc-simulation` | --- | --- |
| `splunk-windows-soc-simulation` | --- | --- |
| `splunk-linux-soc-simulation` | --- | --- |
| `splunk-aws-soc-simulation` | --- | --- |

---

### Scenario Lineup (Windows + Wazuh)
 
| Scenario | Attack | Primary telemetry | MITRE | Response |
|---|---|---|---|---|
| 1. Suspicious PowerShell | Encoded/obfuscated PowerShell execution | Windows Security 4688 (with command-line auditing) + Sysmon Event ID 1 | T1059.001 | Terminate process (Active Response) |
| 2. Failed logon / brute-force | Repeated failed Windows logons | Security 4625 | T1110 | Block source (Active Response) |
| 3. Scheduled task persistence | `schtasks /create` | Security 4688 + 4698 | T1053.005 | Remove task, verify absence |
 
Dropped a more "intrusion-chain" style lineup (LSASS credential dumping, full persistence chains) in favor of this simpler set — easier to make reproducible, reliable, and well-documented, which matters more for a portfolio project than attack sophistication.
 
