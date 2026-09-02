# Windows SOC Simulation — Project Notes

Personal notes on the Windows + Wazuh SOC simulation lab: architecture, detection engineering decisions, the problems I hit, and how each was fixed.

---

## 1. Project Scope & Design Philosophy

**Goal:** Build a small number of well-engineered attack simulations rather than many shallow ones.

Core pipeline used across every scenario:

```
Attack scenario → Windows activity/logs → Wazuh detection → correlation → MITRE mapping → response/remediation → verification → evidence
```

Guiding principle adopted early: **simple attack + excellent SOC engineering beats a sophisticated attack with mediocre detection.** The differentiator in a SOC portfolio project is the quality of telemetry, correlation, response, and verification — not how exotic the attack looks.

### Final scenario lineup (Windows + Wazuh)

| Scenario | Attack | Primary telemetry | MITRE | Response |
|---|---|---|---|---|
| 1. Suspicious PowerShell | Encoded/obfuscated PowerShell execution | Windows Security 4688 (with command-line auditing) + Sysmon Event ID 1 | T1059.001 | Terminate process (Active Response) |
| 2. Failed logon / brute-force | Repeated failed Windows logons | Security 4625 | T1110 | Block source (Active Response) |
| 3. Scheduled task persistence | `schtasks /create` | Security 4688 + 4698 | T1053.005 | Remove task, verify absence |

Dropped a more "intrusion-chain" style lineup (LSASS credential dumping, full persistence chains) in favor of this simpler set — easier to make reproducible, reliable, and well-documented, which matters more for a portfolio project than attack sophistication.

### True positive / false positive split (PowerShell)

Refined Scenario 1 further into two cases to avoid the naive "PowerShell = malicious" framing:

- **1A (false positive):** benign admin commands (`Get-Service`, `Get-Process`) → should not trigger a high-severity alert.
- **1B (true positive):** `-EncodedCommand` / `-ExecutionPolicy Bypass` usage → high-severity alert + MITRE mapping + response.

This demonstrates that detection needs context, since PowerShell itself is legitimate administrative tooling. Also decided the FP case shouldn't just be "no `-EncodedCommand`" — that's too simplistic, since benign admins also use flags like `-NoProfile`. FP/TP were instead defined by known-benign vs. deliberately suspicious command patterns.

---

## 2. Infrastructure Decisions

- **All-in-one Wazuh stack** (indexer + manager + dashboard) provisioned via a bash script run as EC2 user-data, with an idempotency guard (`/root/.wazuh-provisioned` marker file) so re-running the script doesn't reinstall.
- **Windows endpoint provisioning** done as a separate PowerShell script (agent-side), parameterized by `WazuhManagerIP` and `WazuhAgentVersion`, structured as numbered steps:
  1. Hostname (`WIN-SOC-NODE01`) + timezone (India Standard Time) + RDP firewall rule
  2. Wazuh agent install (MSI, silent install, enrollment args passed via `msiexec`)
  3. Sysmon install using the **SwiftOnSecurity community config** instead of Sysmon defaults, for meaningful telemetry — with a fallback to Sysmon's minimal default config if the community config can't be fetched
  4. Add Sysmon eventchannel (`Microsoft-Windows-Sysmon/Operational`) into the Wazuh agent's `ossec.conf`, with automatic backup of the existing config before editing
  5. Enable audit policies (`Logon`, `Process Creation`) and PowerShell Script Block / Module Logging via registry
  6. Restart Wazuh service and verify it's running

- **Reproducibility over snowflake configs:** the whole point of scripting provisioning end-to-end (rather than manually clicking through settings) was to have something that works from a clean endpoint every time — important for defensibility in an interview.

- **Repo structure decision:** initially considered one big repo per platform combining infra + scenarios + evidence. Settled on:
  ```
  windows-soc-simulation/
  ├── README.md
  ├── infrastructure/
  ├── scenarios/
  │   ├── powershell/
  │   ├── credential-access/
  │   └── persistence/
  ├── configs/
  │   ├── sysmon/
  │   ├── windows/
  │   └── wazuh/
  └── evidence/
  ```
  Each scenario reproducible independently from a clean endpoint.

- **Separate repo per platform/SIEM combination**, rather than one giant multi-platform repo:
  ```
  wazuh-windows-soc-simulation
  wazuh-linux-soc-simulation
  wazuh-aws-soc-simulation
  ```
  Rationale: a single sprawling repo dilutes each project's story; separate polished repos each answer one clear question ("how did I build and validate detection/response for this platform?"). A lightweight index/portfolio repo can link to all of them later.

- **Phased platform rollout:** finish all Wazuh scenarios (Windows → Linux → AWS) before starting Splunk. Splunk should demonstrate *different* detection engineering (SPL, different data sources), not just reproduce the same attacks — otherwise it's redundant work.

- **Cloud cost management:** using `m7i-flex.large` / `c7i-flex.large` instance types against a fixed $160 credit budget over ~2.5 months (~$2.13/day average). Decision: don't leave instances running 24/7 just because credits are available — follow a build → run simulation → collect evidence → destroy/stop → update README → next scenario lifecycle to avoid idle burn.

---

## 3. Detection Engineering — Problems & Fixes

### Problem: Guessing rule fields before checking real telemetry
Initial `local_rules.xml` draft assumed generic Sysmon field names (`win.eventdata.image`, `win.eventdata.commandLine`) and a guessed parent SID (`60122`) for the brute-force correlation rule. This was flagged as risky — alert level ≠ detection quality, and a rule is only as good as its match against the actual decoder output.

**Fix / methodology adopted:** *telemetry first, rule second.* Generate the real event (e.g., run an encoded PowerShell command or a failed login), inspect the actual Wazuh alert JSON, and build the rule against confirmed field names — never assume decoder field names for Sysmon/Windows events.

### Problem: 4688 events had no command line
Windows Security 4688 process-creation events were arriving in Wazuh, but `Process Command Line:` was empty, making command-line pattern matching impossible.

**Root cause:** Windows process command-line auditing wasn't enabled on the endpoint.

**Fix:** Enable it via registry (equivalent to the GPO setting *Audit Process Creation → Include command line in process creation events*):
```
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit" `
  -Name "ProcessCreationIncludeCmdLine_Enabled" -Value 1 -Type DWord -Force
```
After this, 4688 events included the full command line, making the PowerShell detection rule viable.

### Problem: Sysmon Event ID 1 wasn't showing up initially
Despite Sysmon being installed, Event ID 1 (process creation) telemetry wasn't appearing in Wazuh right away. After further debugging and configuration adjustments, it started appearing correctly — confirmed by directly querying the Windows event log (`Get-WinEvent -LogName 'Microsoft-Windows-Sysmon/Operational' -Id 1`) before trusting the Wazuh-side view.

**Lesson:** validate telemetry at the source (raw Windows event log) before debugging the SIEM side — it isolates whether the problem is generation or ingestion/parsing.

### Result: dual telemetry sources for the same activity
Ended up with **two independent telemetry paths** for the same PowerShell execution — Windows Security 4688 and Sysmon Event ID 1 — which is actually a plus for a portfolio project (shows both native Windows auditing and Sysmon-based detection working together):

```
PowerShell execution
   ├── Windows Security 4688 → "A process was created" (base rule 67027, level 3)
   │        └── Custom rule: Encoded PowerShell detected (level 12–15)
   └── Sysmon Event ID 1
            ├── PowerShell spawned PowerShell (level 4)
            └── Base64/Encoded PowerShell (level 12)
```

### Detection rule iteration (PowerShell, T1059.001)
First version combined too many weak indicators in one regex (`-enc|-encodedcommand|-nop|-noprofile|-w hidden|-windowstyle hidden`) at level 15 — meant something as mundane as `powershell.exe -NoProfile` alone would fire a high-severity alert. Too aggressive/noisy for a realistic SOC rule.

**Fix:** split into confidence tiers — treat `-EncodedCommand` / `-ExecutionPolicy Bypass` as the high-confidence indicator (kept at high severity), and treat weaker flags like `-NoProfile` as supporting/lower-severity indicators only. Final working rule, layered on top of Wazuh's built-in base rule:

```
4688
  └── 67027: "A process was created" (base rule)
        └── 115100: Encoded PowerShell detected
              ├── Level 12–15 (tuned down from an initial over-eager 15)
              └── MITRE T1059.001
```

Minor style fix along the way: Wazuh `<group>` tags should conventionally be comma-terminated, e.g. `<group>powershell,execution,</group>`.

### Scenario 2 — Failed logon brute-force (T1110)
Correlation rule built on top of the actual failed-logon base rule (rather than a guessed SID), with frequency/timeframe thresholds (5 hits / 60s):
```xml
<rule id="115210" level="12" frequency="5" timeframe="60">
  <if_matched_sid>60122</if_matched_sid>
  <description>SOC-SIM [Scenario 2]: Multiple failed logon attempts detected (Potential Brute-Force)</description>
  <mitre><id>T1110</id></mitre>
</rule>
```
This one fired correctly and generated a custom alert successfully.

### Scenario 3 — Scheduled task persistence (T1053.005)
Built as a two-stage correlation: one rule for the `schtasks.exe /create` process (4688) and one for the resulting audit event (4698), correlated within a 60s window into a single high-confidence alert:
```xml
<rule id="115300" level="8"><!-- schtasks.exe /create via 4688 --></rule>
<rule id="115301" level="8"><!-- 4698: Security Audit logged task creation --></rule>
<rule id="115310" level="13" timeframe="60">
  <if_sid>115300</if_sid>
  <if_matched_sid>115301</if_matched_sid>
  <description>HIGH CORRELATION: Scheduled Task persistence created via command line</description>
  <mitre><id>T1053.005</id></mitre>
</rule>
```

**Open problem (unresolved at time of writing):** the base rule (115300) fires reliably, but the correlated high-level alert (115310, level 13) does not fire — and as a consequence, Active Response never triggers for this scenario. Root cause not yet isolated.

### Active Response — unresolved integration bug
Symptoms while testing Active Response for Scenario 1 (kill the malicious PowerShell process):
- Binary (`task-kill.exe`) present on the endpoint: yes
- Active response actually reaching the agent: no (active-responses.log empty)
- Manually invoking the AR JSON: silently does nothing
- Admin rights: confirmed present

**Suspected root cause (flagged for next debugging session):** the active-response block was appended to `/var/ossec/etc/ossec.conf` as its own wrapping `<ossec_config>...</ossec_config>` block:
```xml
tee -a /var/ossec/etc/ossec.conf > /dev/null << 'EOF'
<ossec_config>
  <command>...</command>
  <active-response>...</active-response>
</ossec_config>
EOF
```
If `ossec.conf` already has its own root `<ossec_config>` element, appending a second one is structurally invalid XML — this is the top suspect and the first thing to check when resuming. Also worth checking whether `task-kill.exe` is actually being invoked by the manager/agent at all.

**Decision:** after ~2 days debugging Active Response (and about 8% of a $160 cloud credit budget, ~$13, burned in the process), parked this specific issue rather than continuing to debug it under fatigue. Rationale: the detection/telemetry layer is proven and working; Active Response is "the ugly integration/debugging layer" and doesn't invalidate the rest of the project. Moved on to Linux and AWS simulations, with intent to return to this later.

---

## 4. Verified Working End-to-End (as of parking the Windows track)

- Windows endpoint provisioning (scripted, idempotent, reproducible)
- Wazuh agent enrollment
- Windows Security 4688 telemetry, including command-line auditing
- Sysmon installation (SwiftOnSecurity config) and Event ID 1 telemetry
- Custom Wazuh local rules matched against real (not assumed) event fields
- MITRE ATT&CK mapping (T1059.001, T1110, T1053.005) on fired rules
- At least one confirmed high-severity detection (encoded PowerShell, level 12–15)
- Failed-logon brute-force correlation alert generation

## 5. Not Yet Working / Next Steps When Resuming

- Scenario 3 correlation rule (115310) not firing despite base rule 115300 firing
- Active Response not reaching the Windows agent — prime suspect is a duplicated/invalid `<ossec_config>` root block in `ossec.conf`
- Verify `task-kill.exe` is actually invoked by manager/agent once the config issue is resolved
- Formal false-positive test case for PowerShell (benign `Get-Service`/`Get-Process`) not yet executed against the tuned rule

---

## 6. General Takeaways

- Telemetry-first rule design avoids wasted effort writing rules against fields that don't actually exist in your decoder output.
- Layering custom high-fidelity rules on top of Wazuh's existing base rules (e.g., 67027) is cleaner than trying to replace built-in detection logic.
- Alert severity should reflect actual confidence — resist the urge to set everything to the maximum level; overly broad regex indicators create noisy, unrealistic detections.
- Correlation (two weaker signals combined within a time window) produces more defensible high-confidence alerts than a single broad rule.
- Getting the "boring" plumbing right (audit policies, command-line logging, Sysmon config, decoder field mapping) took far more effort than the actual attack simulation — and that plumbing is the real engineering substance of a SOC project.
- Scope control matters more than breadth: a smaller number of fully-verified, well-documented scenarios is more defensible in an interview than a large number of shallow ones.
- Budgeting cloud credits by lifecycle (build → run → collect evidence → tear down) prevents idle-instance cost bleed.
