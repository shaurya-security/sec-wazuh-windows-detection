locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Must match the `bucket` in terraform/lab/backend.tf (backends cannot use variables).
  state_bucket_name = "${local.name_prefix}-state-${var.aws_account_id_or_suffix}"

  # Must match `userdata_bucket` in terraform/lab/variables.tf.
  userdata_bucket_name = "${var.project_name}-userdata-${var.aws_account_id_or_suffix}"

  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    },
    var.additional_tags
  )
}

########################################
# Remote state bucket
#
# Locking uses S3-native lockfiles (use_lockfile = true in the lab backend),
# so no DynamoDB table is required with Terraform >= 1.10.
########################################

resource "aws_s3_bucket" "terraform_state" {
  bucket        = local.state_bucket_name
  force_destroy = var.bucket_force_destroy

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-state-bucket" })
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = var.enable_versioning ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

########################################
# Userdata bucket
#
# Holds the bootstrap scripts the EC2 instances fetch at boot. The lab module
# only manages the objects inside it, so the bucket has to exist first.
########################################

resource "aws_s3_bucket" "userdata" {
  bucket        = local.userdata_bucket_name
  force_destroy = var.bucket_force_destroy

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-userdata-bucket" })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "userdata" {
  bucket = aws_s3_bucket.userdata.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "userdata" {
  bucket = aws_s3_bucket.userdata.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}
