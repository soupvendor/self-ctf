variable "aws_region" {
  description = "AWS region containing the existing VPC."
  type        = string
  nullable    = false
}

variable "aws_account_id" {
  description = "Expected AWS account; prevents applying with credentials for another account."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must contain exactly 12 digits."
  }
}

variable "event_name" {
  description = "Stable name used to namespace resources for this event."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,31}$", var.event_name))
    error_message = "event_name must be 3–32 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

variable "vpc_id" {
  description = "Existing VPC with DNS support and DNS hostnames enabled."
  type        = string
  nullable    = false
}

variable "private_subnet_ids" {
  description = "Existing private subnets, one per availability zone, for endpoints and future tasks."
  type        = set(string)
  nullable    = false

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Supply at least two private subnets in distinct availability zones."
  }
}

variable "existing_endpoint_ids" {
  description = "Company-managed endpoints to reuse, keyed by service. Missing services require create_missing_endpoints."
  type        = map(string)
  default     = {}
  nullable    = false

  validation {
    condition = alltrue([
      for service, id in var.existing_endpoint_ids :
      contains(["ecr.api", "ecr.dkr", "logs", "secretsmanager", "s3"], service) &&
      can(regex("^vpce-[a-f0-9]+$", id))
    ])
    error_message = "Endpoint keys must be ecr.api, ecr.dkr, logs, secretsmanager, or s3 with vpce-* IDs."
  }
}

variable "create_missing_endpoints" {
  description = "Opt in to creating omitted endpoints, including S3 routes in the selected subnet route tables."
  type        = bool
  default     = false
  nullable    = false
}

variable "ecr_repository_names" {
  description = "Runtime image repositories to create under the event namespace. Never publish player artifacts here."
  type        = set(string)
  default     = ["ctfd", "mariadb", "redis", "gitea", "gitea-seed", "localstack-seeded"]
  nullable    = false

  validation {
    condition = length(var.ecr_repository_names) > 0 && alltrue([
      for name in var.ecr_repository_names : can(regex("^[a-z][a-z0-9-]{0,63}$", name))
    ])
    error_message = "Supply at least one repository name: 1–64 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

variable "tags" {
  description = "Additional resource tags; project identity tags are reserved."
  type        = map(string)
  default     = {}
  nullable    = false
}
