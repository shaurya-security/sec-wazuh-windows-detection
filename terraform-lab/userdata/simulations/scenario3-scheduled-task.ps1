<#
  SOC-SIM Scenario 3 - Scheduled Task Persistence (T1053.005)

  Manual use only:

      C:\SOC-Lab\simulations\scenario3-scheduled-task.ps1

  Expects to trigger:
    - Rule 115300 (Security 4688, schtasks.exe /create)
    - Rule 115301 (Security 4698, audit log of task creation)
    - Rule 115310 (correlation of both within 60s)

  Log format contract: 4698 requires the "Other Object Access Events" audit
  subcategory, enabled by windows.ps1. If 115301/115310 never fire but
  115300 does, check that subcategory first with:
      auditpol /get /subcategory:"Other Object Access Events"
#>

$ErrorActionPreference = "Stop"
$TaskName = "SOC_Persistence_Task"

Write-Host "=== Scenario 3: Scheduled Task Persistence ===" -ForegroundColor Cyan

Write-Host "Creating task '$TaskName'..." -ForegroundColor Yellow
schtasks /create /tn $TaskName /tr "C:\Windows\System32\notepad.exe" /sc daily /st 09:00 /f

Write-Host "Task created." -ForegroundColor Green
Start-Sleep -Seconds 3

Write-Host "Cleaning up..." -ForegroundColor Yellow
schtasks /delete /tn $TaskName /f | Out-Null
Write-Host "Task '$TaskName' removed." -ForegroundColor Green

Write-Host "`nCheck the Wazuh dashboard for rule 115310 (correlation alert)." -ForegroundColor Cyan
