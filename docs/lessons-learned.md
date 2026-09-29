# Lessons Learned

Notes from actually building, running, debugging, and validating the Windows RDP brute-force lab.

## What I observed when I ran it

- **The full detection chain worked.** One simulation produced the expected Windows events: four failed logons (`4625`) followed by one successful logon (`4624`). Wazuh generated the individual failure alerts, the brute-force correlation alert, and the successful-login-after-failures alert.

- **The successful-login rule initially did not fire.** The rule was using the wrong parent rule ID. I initially used `60106`, but successful remote logons in this setup matched `92657`. Changing the rule to use `92657` made the `115220` correlation alert work. This was a good reminder to verify the actual Wazuh event/rule hierarchy instead of assuming an ID from another setup.

- **FreeRDP needed the right authentication setup.** The first attempts did not produce the expected Windows authentication events. Using NLA with the local Windows account format `./FakeSOCUser` (represented as `.\FakeSOCUser` in the command) produced the expected `4625` and `4624` events.

- **FreeRDP's exit status was misleading.** A successful authentication showed `Authentication complete; SEC_E_OK`, but the `+auth-only` run still ended with exit status `1`. The Windows Security events were therefore treated as the source of truth rather than the FreeRDP process exit code.

- **Containment was verified, not assumed.** Removing the RDP security-group rule made `nc -vz -w 5 <ip> 3389` time out. The Windows account was then disabled and verified with `Get-LocalUser`.

- **Manual AWS containment was needed during the run.** Removing the RDP ingress from Terraform did not remove the existing AWS rule as expected; `terraform plan` showed no infrastructure change while the security group still contained the `3389` rule. For this lab run, the rule was removed directly with AWS CLI and then verified.

- **Alert wording was not perfect.** The correlation alert rendered `$(frequency)` as empty text even though the correlation itself worked. The detection logic was correct, but the analyst-facing message needs improvement.

- **Attack timing matters.** The simulation waits between attempts so the failures remain inside the 60-second correlation window. Changing the timing can change which correlation rule fires.

## Engineering Lessons

1. **Pin AMIs.** Using an unpinned Windows AMI together with `user_data_replace_on_change = true` can unexpectedly replace the endpoint when the resolved AMI changes.

2. **Hash only what each instance uses.** Userdata changes should not rebuild unrelated instances. Per-instance payload selection keeps those dependencies separate.

3. **Keep userdata thin.** The bootstrap scripts mainly fetch payloads and execute standalone provisioning scripts. This made the host configuration easier to inspect and debug.

4. **Keep Wazuh manager and agent versions aligned.** One `wazuh_version` variable is used for both sides.

5. **Bootstrap ordering matters.** The S3 bucket and IAM resources must exist before dependent resources can reliably fetch and execute their payloads. IAM propagation also caused enough delay to require explicit handling.

6. **CI should enforce the infrastructure claims.** Terraform formatting, validation, and Checkov checks catch problems before the lab is deployed.

## Security Lessons

- **Restrict RDP.** The lab only exposes TCP 3389 to the Fedora attacker IP instead of opening RDP to the internet.
- **Contain at the network layer first.** Removing the RDP ingress blocks the attack path regardless of which account is targeted. Disabling the affected account adds a second layer of containment.
- **Verify every remediation.** A successful AWS command or PowerShell command is not enough; the resulting state should be checked independently.
- **Keep simulated credentials isolated.** `FakeSOCUser` and its password exist only for the lab and should never be reused for real systems.

## Key Takeaway

The biggest lesson was that getting a rule to match is only one part of detection engineering.

The useful workflow was:

`Windows event → Wazuh rule → correlation → successful-login correlation → containment → verification → evidence`

The debugging along the way was just as valuable as the final detection because it exposed assumptions about Wazuh rule IDs, Windows authentication, FreeRDP behavior, Terraform state, and AWS security-group changes.
