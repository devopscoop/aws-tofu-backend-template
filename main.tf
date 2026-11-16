data "aws_caller_identity" "current" {}

locals {
  bucket_name         = var.bucket_name != "" ? var.bucket_name : "${var.repo_name}-tfstate-${data.aws_caller_identity.current.account_id}"
  replica_bucket_name = var.replica_bucket_name != "" ? var.replica_bucket_name : "${local.bucket_name}-replica"
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

# -----------------------------------------------------------------------------
# Cross-region replica
#
# Versioning recovers a clobbered or deleted state file; it doesn't help if
# the region itself is lost. Every write to the state bucket is replicated to
# a bucket in replica_region, hardened the same way. Nothing reads or writes
# the replica directly — it's where you point the backend if the primary
# region is gone.
# -----------------------------------------------------------------------------

# KMS keys are regional, so the replica needs its own. S3 decrypts each
# object with the source key and re-encrypts the replica with this one.
resource "aws_kms_key" "replica" {
  provider = aws.replica

  description             = "Encrypts the cross-region replica of OpenTofu remote state for ${var.repo_name}"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = {
    Purpose = "opentofu-remote-state"
    Repo    = var.repo_name
  }

  # Losing this key makes every replica object permanently unreadable.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "replica" {
  provider = aws.replica

  name          = "alias/${var.repo_name}-tfstate-replica"
  target_key_id = aws_kms_key.replica.key_id
}

resource "aws_s3_bucket" "replica" {
  provider = aws.replica

  bucket = local.replica_bucket_name

  tags = merge(
    {
      Purpose = "opentofu-remote-state"
      Repo    = var.repo_name
    },
    var.replica_tags,
  )

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = length(local.replica_bucket_name) <= 63
      error_message = "Replica bucket name \"${local.replica_bucket_name}\" is longer than S3's 63-character limit. Set replica_bucket_name."
    }
  }
}

resource "aws_s3_bucket_versioning" "replica" {
  provider = aws.replica

  bucket = aws_s3_bucket.replica.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "replica" {
  provider = aws.replica

  bucket = aws_s3_bucket.replica.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.replica.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "replica" {
  provider = aws.replica

  bucket = aws_s3_bucket.replica.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 replication delivers over TLS, so denying insecure transport doesn't
# affect it.
resource "aws_s3_bucket_policy" "replica_deny_insecure_transport" {
  provider = aws.replica

  bucket = aws_s3_bucket.replica.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.replica.arn,
          "${aws_s3_bucket.replica.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

# S3 doesn't replicate lifecycle expirations, so the replica needs the same
# rule or its noncurrent versions accumulate forever.
resource "aws_s3_bucket_lifecycle_configuration" "replica" {
  provider = aws.replica

  bucket = aws_s3_bucket.replica.id

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

resource "aws_iam_role" "replication" {
  name = "${var.repo_name}-tfstate-replication"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Purpose = "opentofu-remote-state"
    Repo    = var.repo_name
  }
}

resource "aws_iam_role_policy" "replication" {
  name = "replicate-state"
  role = aws_iam_role.replication.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadSourceBucket"
        Effect = "Allow"
        Action = [
          "s3:GetReplicationConfiguration",
          "s3:ListBucket",
        ]
        Resource = aws_s3_bucket.state.arn
      },
      {
        Sid    = "ReadSourceObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging",
        ]
        Resource = "${aws_s3_bucket.state.arn}/*"
      },
      {
        Sid    = "WriteReplicaObjects"
        Effect = "Allow"
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags",
        ]
        Resource = "${aws_s3_bucket.replica.arn}/*"
      },
      # Both keys are dedicated to this repo's state, so scoping by key ARN
      # is as tight as the encryption-context conditions in AWS's examples,
      # without depending on whether that context is the object or the
      # bucket ARN (it's the bucket ARN once S3 Bucket Keys are on).
      {
        Sid      = "DecryptSourceObjects"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = aws_kms_key.state.arn
      },
      {
        # Encrypt and Decrypt are what AWS documents for a replica key with
        # S3 Bucket Keys (Decrypt verifies the Bucket Key); GenerateDataKey
        # is what it lists for objects that take the destination's default
        # encryption.
        Sid    = "EncryptReplicaObjects"
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = aws_kms_key.replica.arn
      },
    ]
  })
}

resource "aws_s3_bucket_replication_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  role   = aws_iam_role.replication.arn

  rule {
    id     = "replicate-state"
    status = "Enabled"

    filter {}

    # Keeps the replica an exact mirror. Without this, every lock file the
    # backend deletes on unlock stays current in the replica, and a backend
    # pointed there after a regional outage would find stale locks. Delete
    # markers hide objects without removing versions, so the replica's
    # history is still recoverable.
    delete_marker_replication {
      status = "Enabled"
    }

    # S3 skips SSE-KMS objects unless the rule opts in, and the state is
    # SSE-KMS (the backend's kms_key_id, or the bucket default).
    source_selection_criteria {
      sse_kms_encrypted_objects {
        status = "Enabled"
      }
    }

    destination {
      bucket        = aws_s3_bucket.replica.arn
      storage_class = "STANDARD"

      encryption_configuration {
        replica_kms_key_id = aws_kms_key.replica.arn
      }
    }
  }

  # S3 rejects a replication configuration unless versioning is already on at
  # both ends.
  depends_on = [
    aws_s3_bucket_versioning.state,
    aws_s3_bucket_versioning.replica,
  ]
}
