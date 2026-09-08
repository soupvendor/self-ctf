terraform {
  required_version = "~> 1.16.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.63.0"
    }
  }
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}
