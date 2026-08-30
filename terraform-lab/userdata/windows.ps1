param(
    [Parameter(Mandatory = $true)]
    [string]$WazuhManagerIP
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Write-Output "Wazuh manager target: $WazuhManagerIP"

# --------------------------------------------------
# Hostname Configuration
# --------------------------------------------------
$NewHostname = "WIN-SOC-NODE01"
Write-Output "Renaming computer to $NewHostname..."
Rename-Computer -NewName $NewHostname -Force

# --------------------------------------------------
# Working directory
# --------------------------------------------------
New-Item -ItemType Directory -Force -Path "C:\SOC-Lab" | Out-Null

# --------------------------------------------------
# Windows audit telemetry
# --------------------------------------------------
auditpol /set /subcategory:"Logon" /success:enable /failure:enable
auditpol /set /subcategory:"Process Creation" /success:enable

# --------------------------------------------------
# PowerShell Script Block Logging
# --------------------------------------------------
New-Item `
    -Path "HKLM:\Software\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" `
    -Force | Out-Null

Set-ItemProperty `
    -Path "HKLM:\Software\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" `
    -Name "EnableScriptBlockLogging" `
    -Value 1

# --------------------------------------------------
# PowerShell Module Logging
# --------------------------------------------------
New-Item `
    -Path "HKLM:\Software\Policies\Microsoft\Windows\PowerShell\ModuleLogging" `
    -Force | Out-Null

Set-ItemProperty `
    -Path "HKLM:\Software\Policies\Microsoft\Windows\PowerShell\ModuleLogging" `
    -Name "EnableModuleLogging" `
    -Value 1

# --------------------------------------------------
# Install & Register Wazuh Agent
# --------------------------------------------------
$WazuhMsi = "C:\SOC-Lab\wazuh-agent.msi"
$WazuhUrl = "https://packages.wazuh.com/4.x/windows/wazuh-agent-4.9.0-1.msi"

Write-Output "Downloading Wazuh Agent package..."
Invoke-WebRequest -Uri $WazuhUrl -OutFile $WazuhMsi -UseBasicParsing

Write-Output "Installing and enrolling Wazuh Agent to $WazuhManagerIP..."
Start-Process msiexec.exe -ArgumentList "/i `"$WazuhMsi`" /q WAZUH_MANAGER=`"$WazuhManagerIP`" WAZUH_REGISTRATION_SERVER=`"$WazuhManagerIP`" WAZUH_AGENT_NAME=`"$NewHostname`"" -Wait

Write-Output "Starting Wazuh Service..."
Start-Service -Name "wazuh"
Set-Service -Name "wazuh" -StartupType Automatic

Write-Output "Windows SOC telemetry baseline & Wazuh Agent setup complete."
