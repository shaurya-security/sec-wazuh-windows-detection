########################################
# Bootstrap payloads
#
# The bucket itself is managed outside this configuration (it has to exist
# before this module can write to it). Only the objects are managed here.
#
# etag = filemd5(...) makes Terraform re-upload whenever file content changes,
# which in turn feeds the per-instance user_data hashes in compute.tf.
########################################

resource "aws_s3_object" "userdata" {
  for_each = local.userdata_objects

  bucket = var.userdata_bucket
  key    = each.key
  source = each.value
  etag   = filemd5(each.value)

  # Keeps `aws s3 cp` + local execution honest about text vs binary.
  content_type = lookup(
    {
      "sh"   = "text/x-shellscript"
      "ps1"  = "text/plain"
      "xml"  = "application/xml"
      "conf" = "text/plain"
      "txt"  = "text/plain"
    },
    element(reverse(split(".", each.key)), 0),
    "application/octet-stream"
  )

  tags = {
    Name      = each.key
    ManagedBy = "terraform"
  }
}
