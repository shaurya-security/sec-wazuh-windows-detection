<#
    Windows SOC endpoint provisioning.

    Plain S3 payload - no Terraform interpolation. Configuration arrives as
    named parameters from windows-bootstrap.ps1.tpl.

    LOG FORMAT CONTRACT (pinned, must match local_rules.xml):
      - Every <localfile> uses <log_format>eventchannel</log_format>
      - Scenario detection rides on the Security channel
      - Sysmon and PowerShell/Operational are collected for future rules only

    LAYOUT: everything this script writes lives under -Root:
      $Root\logs\          install/transcript logs
      $Root\_tmp\          transient installer files (MSI, Sysmon64.exe/zip)
      $Root\simulations\   already populated by the bootstrap shim's fetch -
                            this script only permissions it, never copies into it

    SYSMON: fetched directly from Sysinternals at install time (not staged
    via S3/userdata). There is no sysmon.exe payload key anywhere in this
    pipeline - see step 4 below.
#>
param(
    [Parameter(Mandatory = $true)] [string]$WazuhManagerIP,
    [Parameter(Mandatory = $true)] [string]$WazuhVersion,
    [Parameter(Mandatory = $true)] [string]$WazuhAgentMsi,
    [Parameter(Mandatory = $true)] [string]$Root
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$AgentDir = "C:\Program Files (x86)\ossec-agent"
$LogDir   = Join-Path $Root "logs"
$TmpDir   = Join-Path $Root "_tmp"
$SimDir   = Join-Path $Root "simulations"

New-Item -ItemType Directory -Force -Path $LogDir, $TmpDir | Out-Null

Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host " WINDOWS SOC PROVISIONING - Wazuh agent $WazuhVersion"          -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "Manager: $WazuhManagerIP"
Write-Host "Root   : $Root"

# --------------------------------------------------
# 1. Hostname
# --------------------------------------------------
$NewHostname = "WIN-SOC-NODE01"
Write-Host "`n[1/8] Renaming to $NewHostname..." -ForegroundColor Cyan
if ($env:COMPUTERNAME -ne $NewHostname) {
    Rename-Computer -NewName $NewHostname -Force
}

# --------------------------------------------------
# 2. Configure ssm-user
#
# Mirrors what common.sh does for the Linux side: create the account
# explicitly, up front, rather than letting the platform create it lazily
# on first connection. On Linux, useradd + NOPASSWD sudoers happens before
# anything else touches the filesystem; this does the Windows equivalent
# (local user + Administrators membership) at the same point in the flow.
#
# Why this matters: AWS SSM Agent's "Run As" support only auto-provisions
# ssm-user itself if the account does NOT already exist. By creating it
# here, at boot, we remove the race that was flagged earlier (the account
# not existing yet when step 8 tried to set an ACL on it). Session Manager
# will pick up and use this pre-existing account instead of creating its
# own.
#
# Windows local accounts require a password even though SSM auth doesn't
# use it interactively - generate one, mark it non-expiring, and never
# persist it anywhere.
# --------------------------------------------------
Write-Host "`n[2/8] Configuring ssm-user account..." -ForegroundColor Cyan

$SsmUserName = "ssm-user"
$existing = Get-LocalUser -Name $SsmUserName -ErrorAction SilentlyContinue

if (-not $existing) {
    Write-Host "Creating local account $SsmUserName..." -ForegroundColor Yellow

    Add-Type -AssemblyName System.Web
    $randomPassword = [System.Web.Security.Membership]::GeneratePassword(24, 6)
    $securePassword = ConvertTo-SecureString $randomPassword -AsPlainText -Force

    New-LocalUser -Name $SsmUserName `
        -Password $securePassword `
        -FullName "SSM Session Manager User" `
        -Description "AWS SSM managed account" `
        -PasswordNeverExpires `
        -AccountNeverExpires `
        -UserMayNotChangePassword | Out-Null

    # Local-admin equivalent of the Linux side's NOPASSWD:ALL sudoers entry -
    # required for SSM's "Run As" support to actually elevate as this user.
    Add-LocalGroupMember -Group "Administrators" -Member $SsmUserName

    $randomPassword = $null
    $securePassword = $null

    Write-Host "$SsmUserName created and added to Administrators." -ForegroundColor Green
} else {
    Write-Host "$SsmUserName already exists, skipping creation." -ForegroundColor Yellow

    if (-not (Get-LocalGroupMember -Group "Administrators" -Member $SsmUserName -ErrorAction SilentlyContinue)) {
        Add-LocalGroupMember -Group "Administrators" -Member $SsmUserName
        Write-Host "$SsmUserName added to Administrators (was missing)." -ForegroundColor Yellow
    }
}

# Force profile creation now rather than on first interactive logon - the
# closest Windows equivalent to `mkdir -p` on a home directory in common.sh.
# A scheduled task run once, as that user, is the standard way to do this
# without a full interactive session.
$profileTaskName = "SOC-Sim-CreateSsmUserProfile"
schtasks /create /tn $profileTaskName /tr "cmd.exe /c whoami" /sc once /st 00:00 /ru $SsmUserName /f | Out-Null
schtasks /run /tn $profileTaskName | Out-Null
Start-Sleep -Seconds 3
schtasks /delete /tn $profileTaskName /f | Out-Null

Write-Host "ssm-user configuration complete." -ForegroundColor Green

# --------------------------------------------------
# 3. Wazuh agent (version pinned to match the manager)
# --------------------------------------------------
Write-Host "`n[3/8] Installing Wazuh agent $WazuhVersion..." -ForegroundColor Cyan

$MsiPath = Join-Path $TmpDir "wazuh-agent.msi"
$MsiLog  = Join-Path $LogDir "wazuh_install.log"
$MsiUrl  = "https://packages.wazuh.com/4.x/windows/$WazuhAgentMsi"

Invoke-WebRequest -Uri $MsiUrl -OutFile $MsiPath -UseBasicParsing

$msiArgs = @(
    "/i", "`"$MsiPath`"",
    "/qn",
    "/l*v", "`"$MsiLog`"",
    "WAZUH_MANAGER=`"$WazuhManagerIP`"",
    "WAZUH_REGISTRATION_SERVER=`"$WazuhManagerIP`"",
    "WAZUH_AGENT_NAME=`"$NewHostname`""
)

$proc = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    throw "Wazuh agent MSI failed with exit code $($proc.ExitCode). See $MsiLog"
}

# --------------------------------------------------
# 4. Sysmon
#
# Fetched directly from Sysinternals at install time - no S3 payload, no
# userdata/ entry, no Get-Payload routing. This removes an entire class of
# key-name/regex mismatch bugs between the bootstrap shim's payload map and
# this script's expected path (that's exactly what broke previously: the
# old flow expected a "sysmon.exe" key to land at $TmpDir\sysmon.exe via a
# regex match in Get-Payload, but no such payload was ever produced because
# compute.tf's Windows `payloads` filter never included it and userdata/
# never contained the binary).
#
# live.sysinternals.com always serves the current Sysmon64.exe directly, no
# zip extraction needed. Requires outbound HTTPS from the instance - if your
# security group/VPC blocks general internet egress, switch to the zip URL
# (download.sysinternals.com/files/Sysmon.zip) or pin a specific release.
# --------------------------------------------------
Write-Host "`n[4/8] Downloading and installing Sysmon..." -ForegroundColor Yellow

$SysmonExe = Join-Path $TmpDir "Sysmon64.exe"
$SysmonUrl = "https://live.sysinternals.com/Sysmon64.exe"

for ($i = 1; $i -le 5; $i++) {
    try {
        Invoke-WebRequest -Uri $SysmonUrl -OutFile $SysmonExe -UseBasicParsing
        break
    } catch {
        if ($i -eq 5) { throw "FATAL: could not download Sysmon from $SysmonUrl after 5 attempts: $_" }
        Write-Host "Sysmon download failed, retry $i/5 in 5s..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }
}

if (-not (Test-Path $SysmonExe)) {
    throw "Sysmon binary not found at $SysmonExe after download."
}

$proc = Start-Process `
    -FilePath $SysmonExe `
    -ArgumentList "-i", "-accepteula" `
    -Wait `
    -PassThru

Write-Host "Sysmon installer exit code: $($proc.ExitCode)"

if ($proc.ExitCode -ne 0) {
    throw "Sysmon installation failed with exit code $($proc.ExitCode)"
}

Start-Sleep -Seconds 5

$installedSysmon = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue

if (-not $installedSysmon) {
    throw "Sysmon installer finished but Sysmon64 service was not found."
}

Write-Host "Sysmon installed successfully." -ForegroundColor Green

# --------------------------------------------------
# 5. Pin the agent log format
# --------------------------------------------------
Write-Host "`n[5/8] Pinning eventchannel log format in ossec.conf..." -ForegroundColor Cyan

$ConfPath = Join-Path $AgentDir "ossec.conf"
if (-not (Test-Path $ConfPath)) { throw "ossec.conf not found at $ConfPath" }

Copy-Item $ConfPath (Join-Path $LogDir "ossec.conf.bak_$(Get-Date -Format 'yyyyMMddHHmmss')") -Force

$content = Get-Content -Path $ConfPath -Raw
$content = [regex]::Replace($content, '(?s)\s*<localfile>.*?</localfile>', '')

$logFormatBlock = @"

  <!-- soc-sim-log-format: eventchannel only. Must match local_rules.xml. -->
  <localfile>
    <location>Security</location>
    <log_format>eventchannel</log_format>
    <query>Event/System[EventID=4688 or EventID=4625 or EventID=4698 or EventID=4697 or EventID=4624]</query>
  </localfile>

  <localfile>
    <location>System</location>
    <log_format>eventchannel</log_format>
  </localfile>

  <localfile>
    <location>Application</location>
    <log_format>eventchannel</log_format>
  </localfile>

  <localfile>
    <location>Microsoft-Windows-Sysmon/Operational</location>
    <log_format>eventchannel</log_format>
  </localfile>

  <localfile>
    <location>Microsoft-Windows-PowerShell/Operational</location>
    <log_format>eventchannel</log_format>
  </localfile>

</ossec_config>
"@

$lastIndex = $content.LastIndexOf("</ossec_config>")
$content = $content.Substring(0, $lastIndex) + $logFormatBlock

Set-Content -Path $ConfPath -Value $content -Encoding UTF8
Write-Host "Log format pinned to eventchannel." -ForegroundColor Green

# --------------------------------------------------
# 6. Audit policy + active response binary
# --------------------------------------------------
Write-Host "`n[6/8] Configuring audit policy and active response..." -ForegroundColor Cyan

auditpol /set /subcategory:"Process Creation" /success:enable /failure:disable | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit" `
    -Name "ProcessCreationIncludeCmdLine_Enabled" -Value 1 -Type DWord -Force

auditpol /set /subcategory:"Logon" /success:enable /failure:enable | Out-Null
auditpol /set /subcategory:"Other Object Access Events" /success:enable /failure:disable | Out-Null

New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" `
    -Name "EnableScriptBlockLogging" -Value 1 -Type DWord -Force

$ArBin = Join-Path $AgentDir "active-response\bin"
New-Item -ItemType Directory -Force -Path $ArBin | Out-Null

$arPs1 = @'
$ErrorActionPreference = "Stop"
$logFile = "C:\SOC-Lab\logs\active-response.log"

try {
    $raw = [Console]::In.ReadToEnd()
    $msg = $raw | ConvertFrom-Json

    if ($msg.command -ne "add") { exit 0 }

    $eventData = $msg.parameters.alert.data.win.eventdata
    $hexPid = $eventData.newProcessId
    if (-not $hexPid) { exit 0 }

    $targetPid = [Convert]::ToInt32($hexPid, 16)

    Stop-Process -Id $targetPid -Force -ErrorAction Stop
    "$(Get-Date -f s) killed PID $targetPid ($($eventData.newProcessName))" |
        Out-File $logFile -Append
}
catch {
    "$(Get-Date -f s) AR error: $_" | Out-File $logFile -Append
}
'@

Set-Content -Path (Join-Path $ArBin "task-kill.ps1") -Value $arPs1 -Encoding UTF8

$arCmd = '@echo off' + "`r`n" +
         'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0task-kill.ps1"' + "`r`n"
Set-Content -Path (Join-Path $ArBin "task-kill.cmd") -Value $arCmd -Encoding ASCII

Write-Host "Active response binary deployed." -ForegroundColor Green

# --------------------------------------------------
# 7. Start the agent
# --------------------------------------------------
Write-Host "`n[7/8] Starting Wazuh agent..." -ForegroundColor Cyan

$svc = Get-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
if (-not $svc) { $svc = Get-Service -Name "wazuh*" -ErrorAction SilentlyContinue | Select-Object -First 1 }
if (-not $svc) { throw "Wazuh service not found after installation." }

Set-Service -Name $svc.Name -StartupType Automatic
Restart-Service -Name $svc.Name -Force

# --------------------------------------------------
# 8. Permission simulation scripts (already fetched here - no copy step)
#
# Because step 2 now creates ssm-user at boot rather than relying on SSM to
# lazily create it on first connection, this ACL should reliably succeed -
# the "does the account exist yet" branch below is now a defensive
# fallback for an edge case (e.g. account creation failed silently upstream)
# rather than the expected path it was before.
# --------------------------------------------------
Write-Host "`n[8/8] Permissioning simulation scripts (not executed)..." -ForegroundColor Cyan

if (Test-Path $SimDir) {
    $ssmUser = Get-LocalUser -Name $SsmUserName -ErrorAction SilentlyContinue

    if ($ssmUser) {
        $acl = Get-Acl $SimDir
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $SsmUserName, "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $acl.AddAccessRule($rule)
        Set-Acl -Path $SimDir -AclObject $acl

        Get-ChildItem $SimDir -Filter "*.ps1" | ForEach-Object { Unblock-File -Path $_.FullName }

        Write-Host "Permissioned $((Get-ChildItem $SimDir -Filter '*.ps1').Count) simulation script(s) at $SimDir" -ForegroundColor Green
    } else {
        Write-Warning "ssm-user unexpectedly missing despite step 2 - scripts are staged at $SimDir but the ACL isn't set."
    }
} else {
    Write-Warning "No simulation payloads found at $SimDir - nothing to permission."
}

Write-Host "`nProvisioning complete. Agent $WazuhVersion -> $WazuhManagerIP" -ForegroundColor Green
Write-Host "Log format: eventchannel (Security, System, Application, Sysmon, PowerShell)" -ForegroundColor Green
Write-Host "Simulation scripts staged at $SimDir (not executed)." -ForegroundColor Cyan



# --------------------------------------------------
# 9. Apply the pending hostname rename
# --------------------------------------------------

if ($env:COMPUTERNAME -ne $NewHostname) {
    Write-Host "`n[9/9] Rebooting to finalize hostname rename to $NewHostname..." -ForegroundColor Cyan
    shutdown.exe /r /t 15 /c "SOC lab provisioning complete - rebooting to finalize hostname rename"
} else {
    Write-Host "`n[9/9] Hostname already $NewHostname, no reboot needed." -ForegroundColor Cyan
}
