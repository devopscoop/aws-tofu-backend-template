output "state_bucket" {
  description = "Name of the state bucket."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_region" {
  description = "Region of the state bucket."
  value       = var.region
}

output "state_kms_key_arn" {
  description = "ARN of the customer-managed KMS key that encrypts the state. Principals running plan/apply need kms:Decrypt and kms:GenerateDataKey on it."
  value       = aws_kms_key.state.arn
}

output "backend_config" {
  description = "Backend block for the repo's main configuration. Paste into its terraform {} block; adjust `key` if the repo has multiple root modules."
  value       = <<-EOT
    backend "s3" {
      bucket       = "${aws_s3_bucket.state.id}"
      key          = "terraform.tfstate"
      region       = "${var.region}"
      use_lockfile = true
      encrypt      = true
      kms_key_id   = "${aws_kms_key.state.arn}"
    }
  EOT
}

output "replica_bucket" {
  description = "Name of the cross-region replica of the state bucket. Point the backend here (with replica_bucket_region and replica_kms_key_arn) if the primary region is lost."
  value       = aws_s3_bucket.replica.id
}

output "replica_bucket_region" {
  description = "Region of the replica bucket."
  value       = aws_s3_bucket.replica.region
}

output "replica_kms_key_arn" {
  description = "ARN of the customer-managed KMS key that encrypts the replica."
  value       = aws_kms_key.replica.arn
}
