<powershell>
# Terraform-rendered bootstrap shim for the Windows SOC endpoint.
# Thin by design: fetch from S3, pass configuration as named parameters.
#
# Sysmon is NOT part of this payload set - windows.ps1 downloads it directly
# from Sysinternals at install time. Nothing here stages, fetches, or routes
# a sysmon.exe/Sysmon64.exe file; Get-Payload below has no special-case for
# it anymore.
#
# Payload fingerprints:
%{ for key, hash in payloads ~}
#   ${key} = ${hash}
%{ endfor ~}

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# --------------------------------------------------
# Configuration injected by Terraform
# --------------------------------------------------
$ManagerIP     = "${wazuh_manager_ip}"
$WazuhVersion  = "${wazuh_version}"
$WazuhAgentMsi = "${wazuh_agent_msi}"
$Bucket        = "${s3_bucket}"

# --------------------------------------------------
# Single root for everything this lab writes to disk.
#
# Fetched payload keys (e.g. "simulations/scenario1-....ps1") land directly
# under this root at their final resting place - there is no separate
# scratch directory and no later copy step. windows.ps1 receives this same
# root as -Root and organizes its own subfolders (logs\, _tmp\,
# simulations\) underneath it.
# --------------------------------------------------
$Root   = "C:\SOC-Lab"
$LogDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $Root, $LogDir | Out-Null

%{ if ami_unpinned ~}
Write-Warning "Windows AMI is NOT pinned - this instance may be replaced on the next apply. Copy the resolved_windows_ami_id output into terraform.tfvars."
%{ endif ~}

Start-Transcript -Path (Join-Path $LogDir "bootstrap.log") -Append -Force -ErrorAction SilentlyContinue

# --------------------------------------------------
# AWS CLI v2 - installer MSI is transient, lives in $env:TEMP, never under
# $Root, since it's deleted immediately after install anyway.
# --------------------------------------------------
if (-not (Get-Command aws.exe -ErrorAction SilentlyContinue)) {
    Write-Output "Installing AWS CLI v2..."
    $msiPath = Join-Path $env:TEMP "AWSCLIV2.msi"
    Invoke-WebRequest -Uri "https://awscli.amazonaws.com/AWSCLIV2.msi" -OutFile $msiPath -UseBasicParsing
    Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /quiet /norestart" -Wait
    Remove-Item $msiPath -Force
}

$AwsCmd = "aws"
if (Test-Path "C:\Program Files\Amazon\AWSCLIV2\aws.exe") {
    $AwsCmd = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
}

# --------------------------------------------------
# Fetch payloads - destination IS the final path, no staging/copy needed.
#
# No sysmon special-case here anymore: every key in $payloads (windows.ps1,
# simulations/*) lands at $Root\<relative key path> via the plain else
# branch. Sysmon is fetched independently, straight from Sysinternals,
# inside windows.ps1 itself - see that script's step 4.
# --------------------------------------------------
function Get-Payload {
    param([string]$Key)

    $relativePath = $Key -replace '/', '\'
    $dest = Join-Path $Root $relativePath

    $destDir = Split-Path $dest -Parent
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null

    for ($i = 1; $i -le 5; $i++) {
        & $AwsCmd s3 cp "s3://$Bucket/$Key" $dest

        if ($LASTEXITCODE -eq 0) {
            Write-Output "Fetched $Key -> $dest"
            return
        }

        Write-Output "Fetch of $Key failed, retry $i/5 in 5s..."
        Start-Sleep -Seconds 5
    }

    throw "FATAL: could not fetch $Key from s3://$Bucket"
}

%{ for key, hash in payloads ~}
Get-Payload -Key "${key}"
%{ endfor ~}

# --------------------------------------------------
# Execute provisioning
# --------------------------------------------------
& "$Root\windows.ps1" `
    -WazuhManagerIP $ManagerIP `
    -WazuhVersion   $WazuhVersion `
    -WazuhAgentMsi  $WazuhAgentMsi `
    -Root           $Root

Stop-Transcript -ErrorAction SilentlyContinue
</powershell>
