########################################
# Amazon Linux 2023 (Wazuh manager)
########################################


data "aws_ami" "amazon_linux" {
  count       = var.linux_ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-20*-kernel-*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

########################################
# Windows Server 2022
#
# Only queried when var.windows_ami_id is empty. Once you copy the
# resolved_windows_ami_id output into terraform.tfvars, this data source
# stops being read entirely and the AMI can no longer drift.
########################################

data "aws_ssm_parameter" "windows_2022_ami" {
  count = var.windows_ami_id == "" ? 1 : 0
  name  = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}

########################################
# Local public IP (dashboard allowlist)
########################################

data "http" "my_public_ip" {
  url = "https://ipv4.icanhazip.com"
}

locals {
  # Pinned value wins; otherwise fall back to the SSM lookup.
  windows_ami_id = var.windows_ami_id != "" ? var.windows_ami_id : data.aws_ssm_parameter.windows_2022_ami[0].value
  linux_ami_id   = var.linux_ami_id != "" ? var.linux_ami_id : data.aws_ami.amazon_linux[0].id

  # True on the first apply, before the AMI has been pinned. Surfaced as a
  # warning in the bootstrap logs so an unpinned lab is obvious.
  windows_ami_unpinned = var.windows_ami_id == ""
  linux_ami_unpinned   = var.linux_ami_id == ""
}
