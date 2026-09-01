output "s3_bucket_id" {
  description = "The name/ID of the S3 bucket."
  value       = aws_s3_bucket.terraform_state.id
}

output "s3_bucket_arn" {
  description = "The ARN of the S3 bucket."
  value       = aws_s3_bucket.terraform_state.arn
}
