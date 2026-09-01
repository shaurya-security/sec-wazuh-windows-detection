locals {
  name_prefix = "${var.project_name}-${var.environment}"
  bucket_name = "${local.name_prefix}-state-${var.aws_account_id_or_suffix}"

  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    },
    var.additional_tags
  )
}

# Main Bucket with force_destroy enabled for smooth tear-downs
resource "aws_s3_bucket" "terraform_state" {
  bucket        = local.bucket_name
  force_destroy = true

  tags = merge(
    local.common_tags,
    {
      Name = "${local.name_prefix}-state-bucket"
    }
  )
}

# Free SSE-S3 Encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Free Public Access Block Security
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}
