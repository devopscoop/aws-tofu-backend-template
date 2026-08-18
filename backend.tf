# Phase 1 (bootstrap): leave this commented out. `tofu init && tofu apply`
# runs with local state and creates the bucket.
#
# Phase 2 (migrate): uncomment, fill in the bucket name and KMS key ARN
# from `tofu output state_bucket` and `tofu output state_kms_key_arn`,
# then run `tofu init -migrate-state`. See README.md for the full procedure.
#
# kms_key_id is not optional: with `encrypt = true` alone the backend
# requests SSE-S3 per object, which overrides the bucket's KMS default.

# terraform {
#   backend "s3" {
#     bucket       = "REPLACE-WITH-state_bucket-OUTPUT"
#     key          = "bootstrap/terraform.tfstate"
#     region       = "us-east-1"
#     use_lockfile = true
#     encrypt      = true
#     kms_key_id   = "REPLACE-WITH-state_kms_key_arn-OUTPUT"
#   }
# }
