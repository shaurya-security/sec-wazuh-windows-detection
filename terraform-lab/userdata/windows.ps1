<#
    Windows SOC endpoint provisioning.

    Plain S3 payload - no Terraform interpolation.
    Configuration arrives as named parameters from windows-bootstrap.ps1.tpl.

    LOG FORMAT CONTRACT:
      - Transport : eventchannel
      - Channel   : Security
      - Events    : 4625 failed logon
                   4624 successful logon

    Detection focus:
      Scenario 1 - RDP Brute Force (T1110)
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$WazuhManagerIP,

    [Parameter(Mandatory = $true)]
    [string]$WazuhVersion,

    [Parameter(Mandatory = $true)]
    [string]$WazuhAgentMsi,

    [Parameter(Mandatory = $true)]
    [string]$Root
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$AgentDir = "C:\Program Files (x86)\ossec-agent"
$LogDir   = Join-Path $Root "logs"
$TmpDir   = Join-Path $Root "_tmp"

New-Item -ItemType Directory -Force -Path $LogDir, $TmpDir | Out-Null

Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host " WINDOWS SOC PROVISIONING - Wazuh agent $WazuhVersion"       -ForegroundColor Cyan
Write-Host " RDP BRUTE-FORCE LAB"                                       -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "Manager: $WazuhManagerIP"
Write-Host "Root   : $Root"

# --------------------------------------------------
# 1. Hostname
# --------------------------------------------------

$NewHostname = "WIN-SOC-NODE01"

Write-Host "`n[1/7] Configuring hostname..." -ForegroundColor Cyan

if ($env:COMPUTERNAME -ne $NewHostname) {
    Rename-Computer -NewName $NewHostname -Force
    Write-Host "Hostname scheduled: $NewHostname" -ForegroundColor Green
}
else {
    Write-Host "Hostname already set to $NewHostname." -ForegroundColor Green
}

# --------------------------------------------------
# 2. Configure ssm-user
# --------------------------------------------------

Write-Host "`n[2/7] Configuring ssm-user..." -ForegroundColor Cyan

$SsmUserName = "ssm-user"

$existing = Get-LocalUser `
    -Name $SsmUserName `
    -ErrorAction SilentlyContinue

if (-not $existing) {

    Write-Host "Creating local account $SsmUserName..." -ForegroundColor Yellow

    Add-Type -AssemblyName System.Web

    $randomPassword = `
        [System.Web.Security.Membership]::GeneratePassword(24, 6)

    $securePassword = `
        ConvertTo-SecureString `
            $randomPassword `
            -AsPlainText `
            -Force

    New-LocalUser `
        -Name $SsmUserName `
        -Password $securePassword `
        -FullName "SSM Session Manager User" `
        -Description "AWS SSM managed account" `
        -PasswordNeverExpires `
        -AccountNeverExpires `
        -UserMayNotChangePassword |
        Out-Null

    Add-LocalGroupMember `
        -Group "Administrators" `
        -Member $SsmUserName

    $randomPassword = $null
    $securePassword = $null

    Write-Host "$SsmUserName created and added to Administrators." `
        -ForegroundColor Green

}
else {

    Write-Host "$SsmUserName already exists." `
        -ForegroundColor Yellow

    if (-not (
        Get-LocalGroupMember `
            -Group "Administrators" `
            -Member $SsmUserName `
            -ErrorAction SilentlyContinue
    )) {

        Add-LocalGroupMember `
            -Group "Administrators" `
            -Member $SsmUserName

        Write-Host "$SsmUserName added to Administrators." `
            -ForegroundColor Yellow
    }
}

# Create the user's profile before SSM use.

$profileTaskName = "SOC-Lab-CreateSsmUserProfile"

schtasks /create `
    /tn $profileTaskName `
    /tr "cmd.exe /c whoami" `
    /sc once `
    /st 00:00 `
    /ru $SsmUserName `
    /f |
    Out-Null

schtasks /run `
    /tn $profileTaskName |
    Out-Null

Start-Sleep -Seconds 3

schtasks /delete `
    /tn $profileTaskName `
    /f |
    Out-Null

Write-Host "ssm-user configuration complete." -ForegroundColor Green

# --------------------------------------------------
# 3. Wazuh agent
# --------------------------------------------------

Write-Host "`n[3/7] Installing Wazuh agent $WazuhVersion..." `
    -ForegroundColor Cyan

$MsiPath = Join-Path $TmpDir "wazuh-agent.msi"
$MsiLog  = Join-Path $LogDir "wazuh_install.log"
$MsiUrl  = "https://packages.wazuh.com/4.x/windows/$WazuhAgentMsi"

Invoke-WebRequest `
    -Uri $MsiUrl `
    -OutFile $MsiPath `
    -UseBasicParsing

$msiArgs = @(
    "/i", "`"$MsiPath`"",
    "/qn",
    "/l*v", "`"$MsiLog`"",
    "WAZUH_MANAGER=`"$WazuhManagerIP`"",
    "WAZUH_REGISTRATION_SERVER=`"$WazuhManagerIP`"",
    "WAZUH_AGENT_NAME=`"$NewHostname`""
)

$proc = Start-Process `
    msiexec.exe `
    -ArgumentList $msiArgs `
    -Wait `
    -PassThru

if ($proc.ExitCode -ne 0) {
    throw "Wazuh agent MSI failed with exit code $($proc.ExitCode). See $MsiLog"
}

Write-Host "Wazuh agent installed." -ForegroundColor Green

# --------------------------------------------------
# 4. Configure Security event collection
# --------------------------------------------------

Write-Host "`n[4/7] Configuring Security event collection..." `
    -ForegroundColor Cyan

$ConfPath = Join-Path $AgentDir "ossec.conf"

if (-not (Test-Path $ConfPath)) {
    throw "ossec.conf not found at $ConfPath"
}

Copy-Item `
    $ConfPath `
    (Join-Path $LogDir "ossec.conf.bak_$(Get-Date -Format 'yyyyMMddHHmmss')") `
    -Force

$content = Get-Content `
    -Path $ConfPath `
    -Raw

# Remove existing localfile blocks so the lab contract is deterministic.

$content = [regex]::Replace(
    $content,
    '(?s)\s*<localfile>.*?</localfile>',
    ''
)

$logFormatBlock = @"

  <!-- SOC-SIM: RDP brute-force detection -->
  <localfile>
    <location>Security</location>
    <log_format>eventchannel</log_format>
    <query>Event/System[EventID=4625 or EventID=4624]</query>
  </localfile>

</ossec_config>
"@

$lastIndex = $content.LastIndexOf("</ossec_config>")

if ($lastIndex -lt 0) {
    throw "Could not locate </ossec_config> in $ConfPath"
}

$content = `
    $content.Substring(0, $lastIndex) `
    + $logFormatBlock

Set-Content `
    -Path $ConfPath `
    -Value $content `
    -Encoding UTF8

Write-Host "Security channel pinned to eventchannel." `
    -ForegroundColor Green

# --------------------------------------------------
# 5. Windows audit policy
# --------------------------------------------------

Write-Host "`n[5/7] Configuring Windows logon auditing..." `
    -ForegroundColor Cyan

# 4624 / 4625
auditpol /set `
    /subcategory:"Logon" `
    /success:enable `
    /failure:enable |
    Out-Null

Write-Host "Logon auditing enabled." -ForegroundColor Green

# --------------------------------------------------
# 6. FakeSOCUser + RDP
# --------------------------------------------------

Write-Host "`n[6/7] Configuring RDP simulation account..." `
    -ForegroundColor Cyan

$FakeUser = "FakeSOCUser"
$FakePassword = ConvertTo-SecureString `
    "ValidPass123!" `
    -AsPlainText `
    -Force

$existingFakeUser = Get-LocalUser `
    -Name $FakeUser `
    -ErrorAction SilentlyContinue

if (-not $existingFakeUser) {

    New-LocalUser `
        -Name $FakeUser `
        -Password $FakePassword `
        -PasswordNeverExpires `
        -AccountNeverExpires |
        Out-Null

    Write-Host "$FakeUser created." -ForegroundColor Green

}
else {

    Write-Host "$FakeUser already exists." `
        -ForegroundColor Yellow
}

if (-not (
    Get-LocalGroupMember `
        -Group "Remote Desktop Users" `
        -Member $FakeUser `
        -ErrorAction SilentlyContinue
)) {

    Add-LocalGroupMember `
        -Group "Remote Desktop Users" `
        -Member $FakeUser

    Write-Host "$FakeUser added to Remote Desktop Users." `
        -ForegroundColor Green
}

# Enable Remote Desktop.

Set-ItemProperty `
    -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
    -Name "fDenyTSConnections" `
    -Value 0

Enable-NetFirewallRule `
    -DisplayGroup "Remote Desktop"

Write-Host "RDP enabled for the simulation." `
    -ForegroundColor Green

# --------------------------------------------------
# 7. Start Wazuh agent
# --------------------------------------------------

Write-Host "`n[7/7] Starting Wazuh agent..." `
    -ForegroundColor Cyan

$svc = Get-Service `
    -Name "WazuhSvc" `
    -ErrorAction SilentlyContinue

if (-not $svc) {
    $svc = Get-Service `
        -Name "wazuh*" `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
}

if (-not $svc) {
    throw "Wazuh service not found after installation."
}

Set-Service `
    -Name $svc.Name `
    -StartupType Automatic

Restart-Service `
    -Name $svc.Name `
    -Force

Write-Host "Wazuh agent started." -ForegroundColor Green

# --------------------------------------------------
# Provisioning complete
# --------------------------------------------------

Write-Host ""
Write-Host "==============================================================" `
    -ForegroundColor Green

Write-Host " Provisioning complete." -ForegroundColor Green
Write-Host " Agent  : $WazuhVersion"
Write-Host " Manager: $WazuhManagerIP"
Write-Host " Events : Security 4625 / 4624"
Write-Host " Focus  : RDP brute force"
Write-Host "==============================================================" `
    -ForegroundColor Green

# --------------------------------------------------
# Apply pending hostname rename
# --------------------------------------------------

if ($env:COMPUTERNAME -ne $NewHostname) {

    Write-Host "`nRebooting to finalize hostname rename..." `
        -ForegroundColor Cyan

    shutdown.exe `
        /r `
        /t 15 `
        /c "SOC lab provisioning complete - rebooting to finalize hostname"

}
else {

    Write-Host "`nHostname already $NewHostname; no reboot needed." `
        -ForegroundColor Green
}
