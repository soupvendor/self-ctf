variable "platform_name" {
  description = "Unique platform within an event; use a different name and state key for a recovery rehearsal."
  type        = string
  default     = "primary"
  nullable    = false
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,11}$", var.platform_name))
    error_message = "Use 1–12 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

variable "aws_region" {
  description = "Commercial AWS region containing the foundation."
  type        = string
  nullable    = false
}

variable "aws_account_id" {
  description = "Expected deployment account."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "Supply a 12-digit AWS account ID."
  }
}

variable "event_name" {
  description = "The event name used by the foundation."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,31}$", var.event_name))
    error_message = "Use 3–32 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

variable "vpc_id" {
  description = "Existing foundation VPC."
  type        = string
  nullable    = false
}

variable "private_subnet_ids" {
  description = "Foundation subnets for the internal ALB, one per availability zone."
  type        = set(string)
  nullable    = false

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Supply at least two private subnets."
  }
}

variable "platform_subnet_id" {
  description = "One foundation subnet; the platform data volume stays in its availability zone."
  type        = string
  nullable    = false

  validation {
    condition     = contains(var.private_subnet_ids, var.platform_subnet_id)
    error_message = "The platform subnet must be one of private_subnet_ids."
  }
}

variable "endpoint_client_security_group_id" {
  description = "Endpoint-client security group from the foundation."
  type        = string
  nullable    = false
}

variable "ssm_endpoint_ids" {
  description = "Existing company SSM and ssmmessages interface endpoint IDs."
  type        = map(string)
  nullable    = false

  validation {
    condition     = toset(keys(var.ssm_endpoint_ids)) == toset(["ssm", "ssmmessages"]) && alltrue([for id in values(var.ssm_endpoint_ids) : can(regex("^vpce-[a-f0-9]+$", id))])
    error_message = "Supply exactly ssm and ssmmessages endpoint IDs."
  }
}

variable "ami_id" {
  description = "Pinned, clean x86_64 AMI with cloud-init, Docker/Compose, AWS CLI v2, SSM Agent, and NVMe device links."
  type        = string
  nullable    = false
}

variable "ami_owner_account_id" {
  description = "Trusted account that owns the supplied AMI."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]{12}$", var.ami_owner_account_id))
    error_message = "Supply the trusted AMI owner's 12-digit account ID."
  }
}

variable "instance_type" {
  description = "Nitro x86_64 instance type for the platform."
  type        = string
  default     = "t3.medium"
  nullable    = false
}

variable "protect_instance" {
  description = "EC2 termination protection. Disable explicitly before an intentional host replacement."
  type        = bool
  default     = true
  nullable    = false
}

variable "data_volume_size_gib" {
  description = "Persistent gp3 data size; must not be smaller than a restore snapshot."
  type        = number
  default     = 50
  nullable    = false

  validation {
    condition     = var.data_volume_size_gib >= 20 && floor(var.data_volume_size_gib) == var.data_volume_size_gib
    error_message = "Use an integer size of at least 20 GiB."
  }
}

variable "root_volume_size_gib" {
  description = "Disposable root disk size, at least as large as the supplied AMI's root snapshot."
  type        = number
  default     = 30
  nullable    = false
  validation {
    condition     = var.root_volume_size_gib >= 20 && floor(var.root_volume_size_gib) == var.root_volume_size_gib
    error_message = "Use an integer root volume size of at least 20 GiB."
  }
}

variable "restore_snapshot_id" {
  description = "Completed platform data snapshot for a new recovery state; never replaces a live protected volume."
  type        = string
  default     = null
  nullable    = true
}

variable "ebs_kms_key_arn" {
  description = "Optional company KMS key for root/data EBS encryption; otherwise the account EBS key."
  type        = string
  default     = null
  nullable    = true
  validation {
    condition     = var.ebs_kms_key_arn == null ? true : startswith(var.ebs_kms_key_arn, "arn:aws:kms:${var.aws_region}:${var.aws_account_id}:key/")
    error_message = "Supply an EBS KMS key ARN from the selected account and region."
  }
}

variable "platform_secret_arn" {
  description = "Existing Secrets Manager secret containing only CTFD_DB_PASSWORD and CTFD_SECRET_KEY as dotenv text."
  type        = string
  nullable    = false
  validation {
    condition     = startswith(var.platform_secret_arn, "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:")
    error_message = "The platform secret must belong to the selected AWS account and region."
  }
}

variable "secret_kms_key_arn" {
  description = "Customer-managed key encrypting the platform secret, if used."
  type        = string
  default     = null
  nullable    = true
}

variable "images" {
  description = "Platform ECR image URIs pinned by digest; mirror the versions in compose.yaml."
  type        = object({ ctfd = string, mariadb = string, redis = string })
  nullable    = false

  validation {
    condition     = alltrue([for uri in values(var.images) : can(regex("^${var.aws_account_id}\\.dkr\\.ecr\\.${var.aws_region}\\.amazonaws\\.com/[a-z0-9/_-]+@sha256:[a-f0-9]{64}$", uri))])
    error_message = "Images must be immutable ECR digests in the selected AWS account and region."
  }
}

variable "certificate_arn" {
  description = "Existing ACM certificate in this region covering the chosen CTFd hostname."
  type        = string
  nullable    = false
  validation {
    condition     = startswith(var.certificate_arn, "arn:aws:acm:${var.aws_region}:${var.aws_account_id}:certificate/")
    error_message = "Supply an ACM certificate from the selected account and region."
  }
}

variable "player_ipv4_cidrs" {
  description = "Company/VPN IPv4 CIDRs permitted to reach ALB HTTPS."
  type        = set(string)
  nullable    = false

  validation {
    condition     = length(var.player_ipv4_cidrs) > 0 && alltrue([for cidr in var.player_ipv4_cidrs : can(cidrnetmask(cidr)) && !endswith(cidr, "/0")])
    error_message = "Supply explicit IPv4 client CIDRs; unrestricted /0 access is not allowed."
  }
}

variable "admin_ipv4_cidrs" {
  description = "Operator/VPN IPv4 CIDRs permitted during initial setup and maintenance."
  type        = set(string)
  nullable    = false
  validation {
    condition     = length(var.admin_ipv4_cidrs) > 0 && alltrue([for cidr in var.admin_ipv4_cidrs : can(cidrnetmask(cidr)) && !endswith(cidr, "/0")])
    error_message = "Supply explicit operator IPv4 CIDRs; unrestricted /0 access is not allowed."
  }
}

variable "enable_player_access" {
  description = "Open ALB access to player CIDRs only after the operator completes CTFd setup."
  type        = bool
  default     = false
  nullable    = false
}

variable "backup_retention_count" {
  description = "Number of hourly application-consistent data snapshots to retain."
  type        = number
  default     = 168
  nullable    = false

  validation {
    condition     = var.backup_retention_count >= 1 && var.backup_retention_count <= 1000 && floor(var.backup_retention_count) == var.backup_retention_count
    error_message = "Retain an integer between 1 and 1000 snapshots."
  }
}

variable "backup_enabled" {
  description = "Enable hourly backups; disable during deliberate maintenance or recovery rehearsals."
  type        = bool
  default     = true
  nullable    = false
}

variable "alarm_sns_topic_arn" {
  description = "Optional existing SNS topic for platform health and backup failure alarms."
  type        = string
  default     = null
  nullable    = true
}

variable "tags" {
  description = "Additional tags; platform identity tags are reserved."
  type        = map(string)
  default     = {}
  nullable    = false
}
