########################################
# Region / Networking
########################################

variable "aws_region" {
  description = "AWS region for all resources. Must match backend.tf (backends cannot use variables)."
  type        = string
  default     = "ap-south-1"
}

variable "availability_zone" {
  description = "AZ for the public subnet."
  type        = string
  default     = "ap-south-1a"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "owner" {
  type    = string
  default = "shaurya"
}

########################################
# Buckets
########################################

variable "userdata_bucket" {
  description = "Pre-existing S3 bucket holding bootstrap scripts. Created outside this module."
  type        = string
  default     = "shaurya-terraform-userdata-2026"
}

########################################
# Wazuh
########################################

variable "wazuh_version" {
  description = <<-EOT
    Full Wazuh version, e.g. "4.14.0". Used for BOTH the manager installer and the
    Windows agent MSI so they never drift apart. The manager installer script is
    published per major.minor branch; the agent MSI uses the full version plus a
    revision suffix (see wazuh_agent_msi_revision).
  EOT
  type        = string
  default     = "4.14.0"

  validation {
    condition     = can(regex("^\\d+\\.\\d+\\.\\d+$", var.wazuh_version))
    error_message = "wazuh_version must be in MAJOR.MINOR.PATCH form, e.g. 4.14.0."
  }
}

variable "wazuh_agent_msi_revision" {
  description = "Package revision suffix on the Windows agent MSI (the '-1' in wazuh-agent-4.14.0-1.msi)."
  type        = string
  default     = "1"
}

########################################
# AMIs
########################################

variable "windows_ami_id" {
  description = <<-EOT
    Pinned Windows Server 2022 AMI ID. Leave empty on first apply to resolve the
    latest via SSM, then copy the resolved_windows_ami_id output into terraform.tfvars
    so re-applies stop silently replacing the instance.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.windows_ami_id == "" || can(regex("^ami-[0-9a-f]{8,17}$", var.windows_ami_id))
    error_message = "windows_ami_id must be empty or a valid ami-xxxxxxxx identifier."
  }
}


variable "linux_ami_id" {
  description = "Pinned Amazon Linux 2023 AMI ID"
  type        = string
  default     = "ami-094210f044117049d"
}


########################################
# Misc
########################################

variable "timezone" {
  description = "IANA timezone applied to instances and the Wazuh dashboard."
  type        = string
  default     = "Asia/Kolkata"
}
