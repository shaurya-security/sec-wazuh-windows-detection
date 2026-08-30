# Upload common.sh and track file changes via MD5 hash
resource "aws_s3_object" "common_sh" {
  bucket = "shaurya-terraform-userdata-2026"
  key    = "common.sh"
  source = "${path.module}/userdata/common.sh"
  etag   = filemd5("${path.module}/userdata/common.sh")
}

# Upload wazuh.sh and track file changes via MD5 hash
resource "aws_s3_object" "wazuh_sh" {
  bucket = "shaurya-terraform-userdata-2026"
  key    = "wazuh.sh"
  source = "${path.module}/userdata/wazuh.sh"
  etag   = filemd5("${path.module}/userdata/wazuh.sh")
}

# Optional: Upload windows.ps1 if managed via Terraform

resource "aws_s3_object" "windows_ps1" {
  bucket = "shaurya-terraform-userdata-2026"
  key    = "windows.ps1"
  source = "${path.module}/userdata/windows.ps1"
  etag   = filemd5("${path.module}/userdata/windows.ps1")
}
