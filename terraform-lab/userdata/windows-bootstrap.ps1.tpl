<powershell>
# Windows Script Hash: ${windows_hash}

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# Interpolated by Terraform
$ManagerIP = "${wazuh_manager_ip}"

# Standard PowerShell local variables
$Bucket = "shaurya-terraform-userdata-2026"
$WorkDir = "C:\TerraformBootstrap"

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

# Download AWS CLI if not present
if (-not (Get-Command aws.exe -ErrorAction SilentlyContinue)) {
    Write-Output "Installing AWS CLI v2..."
    $msiUrl = "https://awscli.amazonaws.com/AWSCLIV2.msi"
    $msiPath = "$WorkDir\AWSCLIV2.msi"
    
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
    Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /quiet /norestart" -Wait
    Remove-Item $msiPath -Force
}

# Resolve path to aws.exe
$AwsCmd = "aws"
if (Test-Path "C:\Program Files\Amazon\AWSCLIV2\aws.exe") {
    $AwsCmd = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
}

# Download and execute script from S3
& $AwsCmd s3 cp "s3://$Bucket/windows.ps1" "$WorkDir\windows.ps1"

# Run windows.ps1 script
& "$WorkDir\windows.ps1" -WazuhManagerIP $ManagerIP
</powershell>
