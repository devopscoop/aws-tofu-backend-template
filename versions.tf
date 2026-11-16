terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"

      # The replica bucket and its KMS key live in a second region. Callers
      # that use this directory as a module delete the provider blocks below
      # and pass both in: providers = { aws = aws, aws.replica = aws.replica }
      configuration_aliases = [aws.replica]
    }
  }
}

provider "aws" {
  region = var.region
}

provider "aws" {
  alias  = "replica"
  region = var.replica_region
}
