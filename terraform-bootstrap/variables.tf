variable "project_name" {
  type        = string
  description = "Name of the project."
  default     = "shaurya-terraform"
}

variable "environment" {
  type        = string
  description = "Deployment environment (e.g., dev, stage, prod, lab)."
  default     = "lab"
}

variable "aws_account_id_or_suffix" {
  type        = string
  description = "Unique suffix or account ID to ensure global S3 bucket name uniqueness."
  default     = "2026"
}

variable "enable_versioning" {
  type        = bool
  description = "Enable versioning for state recovery."
  default     = true
}

variable "bucket_force_destroy" {
  type        = bool
  description = "Whether to allow force deletion of the bucket if it contains objects."
  default     = false
}

variable "kms_key_arn" {
  type        = string
  description = "ARN of KMS key if using Customer Managed Keys (CMK). Leave null for AES256."
  default     = null
}

variable "additional_tags" {
  type        = map(string)
  description = "Additional resource tags."
  default     = {}
}
