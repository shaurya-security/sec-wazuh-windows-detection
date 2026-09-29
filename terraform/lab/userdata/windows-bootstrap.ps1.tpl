<powershell>
# Terraform-rendered bootstrap shim for the Windows SOC endpoint.
# Thin by design: fetch from S3, pass configuration as named parameters.
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
# --------------------------------------------------
$Root   = "C:\SOC-Lab"
$LogDir = Join-Path $Root "logs"

New-Item -ItemType Directory -Force -Path $Root, $LogDir | Out-Null

%{ if ami_unpinned ~}
Write-Warning "Windows AMI is NOT pinned - this instance may be replaced on the next apply. Copy the resolved_windows_ami_id output into terraform.tfvars."
%{ endif ~}

Start-Transcript `
    -Path (Join-Path $LogDir "bootstrap.log") `
    -Append `
    -Force `
    -ErrorAction SilentlyContinue

# --------------------------------------------------
# AWS CLI v2
# --------------------------------------------------
if (-not (Get-Command aws.exe -ErrorAction SilentlyContinue)) {
    Write-Output "Installing AWS CLI v2..."

    $msiPath = Join-Path $env:TEMP "AWSCLIV2.msi"

    Invoke-WebRequest `
        -Uri "https://awscli.amazonaws.com/AWSCLIV2.msi" `
        -OutFile $msiPath `
        -UseBasicParsing

    Start-Process `
        msiexec.exe `
        -ArgumentList "/i `"$msiPath`" /quiet /norestart" `
        -Wait

    Remove-Item $msiPath -Force
}

$AwsCmd = "aws"

if (Test-Path "C:\Program Files\Amazon\AWSCLIV2\aws.exe") {
    $AwsCmd = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
}

# --------------------------------------------------
# Fetch payloads
#
# Payloads are copied directly to their final location
# under C:\SOC-Lab.
# --------------------------------------------------
function Get-Payload {
    param([string]$Key)

    $relativePath = $Key -replace '/', '\'
    $dest = Join-Path $Root $relativePath

    $destDir = Split-Path $dest -Parent

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $destDir | Out-Null

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
# Execute Windows provisioning
# --------------------------------------------------
& "$Root\windows.ps1" `
    -WazuhManagerIP $ManagerIP `
    -WazuhVersion   $WazuhVersion `
    -WazuhAgentMsi  $WazuhAgentMsi `
    -Root           $Root

Stop-Transcript -ErrorAction SilentlyContinue
</powershell>
