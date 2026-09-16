<#
  SOC-SIM Scenario 1 - Suspicious PowerShell Execution (T1059.001)

  Manual use only. Not invoked by any bootstrap script - run this yourself
  from a Session Manager shell as ssm-user:

      C:\SOC-Lab\simulations\scenario1-powershell-encoded.ps1

  Expects to trigger:
    - Rule 115100 (Security 4688, encoded/hidden PowerShell)
    - Active response "task-kill" (kills the spawned process)

  Log format contract: relies on the Security channel via eventchannel,
  with ProcessCreationIncludeCmdLine enabled - both set up by windows.ps1.
  If command lines aren't showing up in Wazuh, that registry key is the
  first thing to check.
#>

$ErrorActionPreference = "Stop"

Write-Host "=== Scenario 1: Encoded PowerShell Execution ===" -ForegroundColor Cyan

$cmd = "Start-Sleep -Seconds 30"
$bytes = [System.Text.Encoding]::Unicode.GetBytes($cmd)
$encodedCmd = [Convert]::ToBase64String($bytes)

Write-Host "Launching encoded PowerShell process..." -ForegroundColor Yellow
$proc = Start-Process powershell.exe `
    -ArgumentList "-NoProfile -WindowStyle Hidden -EncodedCommand $encodedCmd" `
    -PassThru

Write-Host "Started PID $($proc.Id)" -ForegroundColor Cyan
Start-Sleep -Seconds 3

if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) {
    Write-Host "Process still running - active response did not fire (or hasn't caught up yet)." -ForegroundColor Red
    Write-Host "Check on the manager: /var/ossec/logs/active-responses.log" -ForegroundColor Yellow
} else {
    Write-Host "SUCCESS: PID $($proc.Id) was terminated - active response fired." -ForegroundColor Green
}

Write-Host "`nCheck the Wazuh dashboard for rule 115100." -ForegroundColor Cyan
