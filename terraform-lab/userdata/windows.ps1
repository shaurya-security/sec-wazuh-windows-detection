param(
    [Parameter(Mandatory = $true)]
    [string]$WazuhManagerIP
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host "WINDOWS SERVER SOC PROVISIONING & WAZUH AGENT SETUP" -ForegroundColor Cyan
Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host "Wazuh manager target: $WazuhManagerIP"

# --------------------------------------------------
# 1. Hostname Configuration
# --------------------------------------------------
$NewHostname = "WIN-SOC-NODE01"
Write-Host "`n[1/6] Renaming computer to $NewHostname..." -ForegroundColor Cyan
Rename-Computer -NewName $NewHostname -Force

# --------------------------------------------------
# 2. Install Wazuh Agent
# --------------------------------------------------
Write-Host "`n[2/6] Downloading & Installing Wazuh Agent..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path "C:\SOC-Lab" | Out-Null

$WazuhMsi = "C:\SOC-Lab\wazuh-agent.msi"
$MsiLog   = "C:\SOC-Lab\wazuh_install.log"
$WazuhUrl = "https://packages.wazuh.com/4.x/windows/wazuh-agent-4.9.0-1.msi"

Invoke-WebRequest -Uri $WazuhUrl -OutFile $WazuhMsi -UseBasicParsing

Write-Host "Enrolling Wazuh Agent with manager $WazuhManagerIP..."
$process = Start-Process msiexec.exe -ArgumentList "/i `"$WazuhMsi`" /qn /l*v `"$MsiLog`" WAZUH_MANAGER=`"$WazuhManagerIP`" WAZUH_REGISTRATION_SERVER=`"$WazuhManagerIP`" WAZUH_AGENT_NAME=`"$NewHostname`"" -Wait -PassThru

if ($process.ExitCode -ne 0) {
    throw "Wazuh Agent MSI installation failed with exit code $($process.ExitCode). Check $MsiLog for details."
}

# --------------------------------------------------
# 3. Sysmon Installation
# --------------------------------------------------
Write-Host "`n[3/6] Downloading & Installing Sysmon..." -ForegroundColor Cyan
$SysmonExe = "$env:TEMP\sysmon.exe"
Invoke-WebRequest -Uri "https://live.sysinternals.com/sysmon.exe" -OutFile $SysmonExe
& $SysmonExe -i -accepteula -s

# --------------------------------------------------
# 4. Configure Wazuh Agent Channel for Sysmon
# --------------------------------------------------
Write-Host "`n[4/6] Updating Wazuh Agent ossec.conf for Sysmon..." -ForegroundColor Cyan
$confPath = "C:\Program Files (x86)\ossec-agent\ossec.conf"

if (Test-Path $confPath) {
    $content = Get-Content -Path $confPath -Raw
    if ($content -match "Microsoft-Windows-Sysmon/Operational") {
        Write-Host "Sysmon eventchannel is already configured in ossec.conf." -ForegroundColor Yellow
    } else {
        Copy-Item -Path $confPath -Destination "$confPath.bak_$(Get-Date -Format 'yyyyMMddHHmmss')" -Force
        
        $sysmonBlock = @"
  <localfile>
    <location>Microsoft-Windows-Sysmon/Operational</location>
    <log_format>eventchannel</log_format>
  </localfile>
</ossec_config>
"@
        $updatedContent = $content -replace "</ossec_config>", $sysmonBlock
        Set-Content -Path $confPath -Value $updatedContent -Encoding UTF8
        Write-Host "Successfully added Sysmon channel to ossec.conf." -ForegroundColor Green
    }
} else {
    Write-Host "Warning: ossec.conf not found at $confPath" -ForegroundColor Yellow
}

# --------------------------------------------------
# 5. Enable Windows Audit Policies & PowerShell Telemetry
# --------------------------------------------------
Write-Host "`n[5/6] Configuring Audit Policies and PowerShell Logging..." -ForegroundColor Cyan

# Audit Policies
auditpol /set /subcategory:"Logon" /success:enable /failure:enable | Out-Null
auditpol /set /subcategory:"Process Creation" /success:enable /failure:disable | Out-Null
auditpol /set /subcategory:"Other Object Access Events" /success:enable /failure:disable | Out-Null

# Command Line Auditing (Event 4688)
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit" `
    -Name "ProcessCreationIncludeCmdLine_Enabled" -Value 1 -Type DWord -Force

# PowerShell Script Block Logging (Event 4104)
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" `
    -Name "EnableScriptBlockLogging" -Value 1 -Type DWord -Force

# PowerShell Module Logging
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging" `
    -Name "EnableModuleLogging" -Value 1 -Type DWord -Force

# --------------------------------------------------
# 6. Enable & Restart Wazuh Service
# --------------------------------------------------
Write-Host "`n[6/6] Restarting Wazuh Service..." -ForegroundColor Cyan
$wazuhService = Get-Service -Name "WazuhSvc", "wazuh" -ErrorAction SilentlyContinue

if ($wazuhService) {
    Set-Service -Name $wazuhService[0].Name -StartupType Automatic
    Restart-Service -Name $wazuhService[0].Name -Force
    Write-Host "Provisioning complete! Windows SOC telemetry baseline & Wazuh Agent setup finished." -ForegroundColor Green
} else {
    throw "Wazuh service was not found on the system after installation."
}
