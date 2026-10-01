# 📓 Lessons Learned

What building, running, debugging and validating the RDP brute-force lab taught me.

**Contents:** [Observed results](#-what-i-observed) · [Engineering](#-engineering-lessons) · [Security](#-security-lessons) · [Open questions](#-open-questions) · [Takeaway](#-key-takeaway)

---

## 🔭 What I observed

### ✅ Worked

| Observation | Detail |
|---|---|
| **Full detection chain** | One simulation produced four `4625` events and one `4624`. Wazuh raised the individual failure alerts, the brute-force alert, and the success-after-failures alert. |
| **Containment verified, not assumed** | With the RDP rule removed, `nc -vz -w 5 <ip> 3389` timed out. The account was disabled and confirmed with `Get-LocalUser`. |

### 🐛 Broke, then fixed

| Problem | Cause | Fix |
|---|---|---|
| **`115220` never fired** | Wrong parent rule. I assumed `60106`, but successful remote logons here matched `92657`. | Pointed the rule at `92657`. Lesson: check the real rule hierarchy, don't borrow an ID from another setup. |
| **No Windows events from FreeRDP** | Wrong authentication setup. | Use NLA with the local-account format `.\FakeSOCUser`. This produced the expected `4625` and `4624`. |

### 🤔 Misleading signals

| Observation | Detail |
|---|---|
| **FreeRDP exit status** | A successful authentication printed `Authentication complete; SEC_E_OK`, yet the `+auth-only` run still exited with status `1`. The Windows Security events are the source of truth, not the exit code. |
| **Alert wording** | The correlation alert rendered `$(frequency)` as blank text. The logic was right but the analyst-facing message was not. |
| **Attack timing** | The script waits between attempts so failures stay inside the 60 s window. Changing the timing changes which correlation rule fires. |

### ⚠️ Terraform vs reality

Removing the RDP ingress from Terraform did **not** remove the live AWS rule as expected. `terraform plan` showed no change while the Security Group still had the `3389` rule. For this run, the rule was removed directly with the AWS CLI and then verified. The cause was not investigated (see [open questions](#-open-questions)).

---

## 🛠️ Engineering lessons

| # | Lesson | Why it matters |
|:-:|---|---|
| 1 | **Pin AMIs** | An unpinned Windows AMI plus `user_data_replace_on_change = true` can replace the endpoint when the resolved AMI changes. |
| 2 | **Hash only what each instance uses** | A Linux script edit should not rebuild the Windows box, and the reverse. Per-instance payload selection keeps them separate. |
| 3 | **Keep user-data thin** | Shims fetch payloads and run standalone scripts. Host configuration is easier to inspect and debug. |
| 4 | **One version variable for manager and agent** | A single `wazuh_version` removes a classic source of silent failures. |
| 5 | **Ordering matters** | The S3 bucket and IAM resources must exist before instances can fetch and run payloads. IAM propagation delay needed an explicit wait. |
| 6 | **CI should enforce the claims** | Format, validate and Checkov checks catch problems before anything is deployed. |

---

## 🔐 Security lessons

| Lesson | Detail |
|---|---|
| **Restrict RDP** | Port 3389 is open only to the operator's IP, never the whole internet. |
| **Contain at the network first** | Removing the ingress rule blocks the attack path whichever account is targeted. Disabling the account adds a second layer. |
| **Verify every remediation** | A successful AWS or PowerShell command is not proof. Check the resulting state independently. |
| **Isolate lab credentials** | `FakeSOCUser` and its password exist only for the lab. Never reuse them. |
| **Screenshots leak** | Alert screenshots can show a real ISP address. Blur before publishing. |

---

## ❓ Open questions

Things I observed but did not resolve.

| Question | Why it matters |
|---|---|
| Why did `terraform plan` show no change while the live Security Group still had the `3389` rule? | Containment through IaC is only trustworthy if the plan reflects the live state. |
| What is the right fix for the blank `$(frequency)` text? | Analysts read the description first. |
| How long did detect-to-contain take? | Timestamps for containment were not captured. |

---

## 🧭 Key takeaway

Getting a rule to match is only one part of detection engineering.

The workflow that mattered:

```
Windows event → Wazuh rule → correlation → success-after-failures → containment → verification → evidence
```

The debugging was as valuable as the final result. It exposed assumptions about Wazuh rule IDs, Windows authentication, FreeRDP behavior, Terraform state, and AWS Security Group changes.

---

📎 Related: [`detection-rules.md`](detection-rules.md) · [`incident-report.md`](incident-report.md) · [`architecture.md`](architecture.md)
