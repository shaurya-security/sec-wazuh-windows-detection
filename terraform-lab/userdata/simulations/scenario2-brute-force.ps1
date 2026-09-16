<#
  SOC-SIM Scenario 2 - Failed Logon Brute Force (T1110)

  Manual use only:

      C:\SOC-Lab\simulations\scenario2-brute-force.ps1

  Expects to trigger:
    - Rule 115200 x6 (Security 4625, one per failed attempt)
    - Rule 115210    (correlation: 5+ within 60s, same target account)

  Log format contract: correlation groups on win.eventdata.targetUserName,
  not source IP - the attempts below go against \\localhost, so 4625's
  ipAddress field is unreliable ("-" or 127.0.0.1) and would break an
  IP-based correlation. See local_rules.xml for the rationale.
#>

$ErrorActionPreference = "Continue"   # net use failures are the point; don't stop the loop

Write-Host "=== Scenario 2: Brute-Force Logon Simulation ===" -ForegroundColor Cyan
Write-Host "Target account: FakeSOCUser (6 attempts)`n"

1..6 | ForEach-Object {
    Write-Host "Attempt $_..." -NoNewline
    cmd.exe /c "net use \\localhost\C$ /user:FakeSOCUser InvalidPass123! 2>&1" | Out-Null
    Write-Host " failed (expected)." -ForegroundColor Red
    Start-Sleep -Milliseconds 500
}

# Clean up the failed mapping attempt so it doesn't linger.
cmd.exe /c "net use \\localhost\C$ /delete 2>&1" | Out-Null

Write-Host "`nCheck the Wazuh dashboard for rule 115210 (brute-force correlation)." -ForegroundColor Green
