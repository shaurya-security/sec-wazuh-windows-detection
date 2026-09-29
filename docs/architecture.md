# Architecture

## Overview

Two EC2 instances in one public subnet. The Windows server is the target; the Wazuh manager is the SIEM. The operator's workstation plays the attacker.

```mermaid
flowchart LR
    OP["Operator workstation<br/>(simulates attacker)<br/>soc-sim-brute-force.sh"]

    subgraph AWS["AWS - ap-south-1 - VPC 10.0.0.0/16"]
        subgraph SUBNET["Public subnet 10.0.1.0/24"]
            WIN["Windows Server 2022<br/>WIN-SOC-NODE01<br/>Wazuh agent"]
            WAZ["Amazon Linux 2023<br/>Wazuh manager + indexer + dashboard<br/>custom rules 115200 / 115210 / 115220"]
        end
        S3[("S3 userdata bucket<br/>bootstrap scripts")]
        SSM["SSM Session Manager<br/>(admin access, no SSH/RDP needed)"]
    end

    OP -- "RDP 3389<br/>allow-listed to operator IP" --> WIN
    WIN -- "1514/tcp events<br/>1515/tcp enrollment" --> WAZ
    OP -- "HTTPS 443<br/>allow-listed to operator IP" --> WAZ
    S3 -. "fetched at first boot" .-> WIN
    S3 -. "fetched at first boot" .-> WAZ
    SSM -.-> WIN
    SSM -.-> WAZ
```

## Detection flow

```mermaid
sequenceDiagram
    participant A as Attacker (operator)
    participant W as Windows endpoint
    participant M as Wazuh manager
    A->>W: RDP login, wrong password (x4)
    W->>W: Security log: Event 4625 (x4)
    W->>M: Agent ships events (eventchannel)
    M->>M: Rule 115200 fires per failure
    M->>M: Rule 115210 fires: 4 failures / 60s / same IP
    A->>W: RDP login, correct password
    W->>W: Security log: Event 4624
    W->>M: Agent ships event
    M->>M: Rule 115220 fires (level 14): success after 4 failures / 120s
```

## Design decisions

| Decision | Why |
|---|---|
| **Security Groups reference each other** for agent traffic (1514/1515/55000) instead of CIDRs | The Wazuh manager only accepts agent traffic from the Windows SG. No IP bookkeeping, and nothing else in the VPC can enroll. |
| **Only the operator IP can reach RDP and the dashboard**, resolved at apply time from `icanhazip.com` | The lab never exposes a brute-forceable port to the whole internet. Trade-off: re-apply if your IP changes. |
| **Thin bootstrap shims + payloads in S3** | User-data has a 16 KB limit and is painful to debug. The Terraform-rendered shim only fetches files and sets environment variables; real logic stays in plain `.sh`/`.ps1` files. |
| **Per-instance payload hashes in user-data** | Editing a Windows script does not rebuild the Wazuh server (and vice versa), because each instance only hashes the files it consumes. |
| **Wazuh manager and agent share one `wazuh_version` variable** | Version mismatch between manager and agent is a classic source of silent failures. One variable, no drift. |
| **Windows and Linux AMIs are pinnable** | With an unpinned "latest" AMI, `terraform apply` can silently replace the instance. Pin after first apply; the bootstrap log warns while unpinned. |
| **SSM Session Manager for admin access** | No inbound SSH, no key pairs to leak. IMDSv2 required on both instances. EBS volumes encrypted. |
| **S3-native state locking** (`use_lockfile`) | Removes the need for a DynamoDB lock table (Terraform ≥ 1.10). |
| **Agent collects only events 4624 and 4625** via an XPath query | Keeps the data contract tiny and the detection deterministic. |

## Known limitations

- Single AZ, public subnet, no NAT or flow logs. This is a lab, not a reference production network. Checkov exceptions for this are documented in `terraform/lab/.checkov.yaml`.
- Containment is done by hand (Terraform change + `Disable-LocalUser`), not by Wazuh Active Response. Automating it is the obvious next step.
- Only one scenario (RDP brute force) is implemented.
