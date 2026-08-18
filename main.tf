data "aws_caller_identity" "current" {}

locals {
  bucket_name = var.bucket_name != "" ? var.bucket_name : "${var.repo_name}-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_kms_key" "state" {
  description             = "Encrypts OpenTofu remote state for ${var.repo_name}"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = {
    Purpose = "opentofu-remote-state"
    Repo    = var.repo_name
  }

  # Losing this key makes every state object permanently unreadable, so
  # deletion is guarded the same way as the bucket itself.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "state" {
  name          = "alias/${var.repo_name}-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  tags = {
    Purpose = "opentofu-remote-state"
    Repo    = var.repo_name
  }

  # This bucket holds the state that describes it. Destroying it destroys
  # the record of everything in this configuration, so make `tofu destroy`
  # refuse to touch it unless this guard is removed first.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_logging" "state" {
  count = var.access_log_bucket != "" ? 1 : 0

  bucket        = aws_s3_bucket.state.id
  target_bucket = var.access_log_bucket
  target_prefix = coalesce(var.access_log_prefix, "${local.bucket_name}/")
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "deny_insecure_transport" {
  bucket = aws_s3_bucket.state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.state.arn,
          "${aws_s3_bucket.state.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
