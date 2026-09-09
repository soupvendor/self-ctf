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
  description = "The event name used by the foundation; one teams state per event."
  type        = string
  nullable    = false
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,31}$", var.event_name))
    error_message = "Use 3–32 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

variable "team_ids" {
  description = "Stable operator-assigned team IDs, not player-controlled display names; removing an ID destroys its stack."
  type        = set(string)
  nullable    = false
  validation {
    condition     = alltrue([for id in var.team_ids : can(regex("^[a-z][a-z0-9-]{0,15}$", id))])
    error_message = "Team IDs must be 1–16 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

variable "team_access" {
  description = "Optional company-VPN HTTPS entry point. Team ownership is honor-system, not authenticated."
  type = object({
    domain          = string
    hosted_zone_id  = string
    certificate_arn = string
    vpn_ipv4_cidrs  = set(string)
  })
  default  = null
  nullable = true
  validation {
    condition = var.team_access == null ? true : (
      can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", var.team_access.domain)) &&
      length(var.team_access.domain) <= 200 &&
      startswith(var.team_access.certificate_arn, "arn:aws:acm:${var.aws_region}:${var.aws_account_id}:certificate/") &&
      length(var.team_access.vpn_ipv4_cidrs) > 0 &&
      alltrue([for cidr in var.team_access.vpn_ipv4_cidrs : can(cidrnetmask(cidr)) && !endswith(cidr, "/0")]) &&
      length(var.team_ids) <= 30
    )
    error_message = "Use a DNS domain, an ACM certificate in this account/region, explicit IPv4 VPN CIDRs (no /0), and at most 30 teams (two ALB egress rules per team)."
  }
}

variable "vpc_id" {
  description = "Existing foundation VPC."
  type        = string
  nullable    = false
}

variable "private_subnet_ids" {
  description = "Existing foundation subnets where Fargate may place tasks."
  type        = set(string)
  nullable    = false
  validation {
    condition     = length(var.private_subnet_ids) >= 2 && length(var.private_subnet_ids) <= 16
    error_message = "Supply 2–16 private subnets."
  }
}

variable "endpoint_client_security_group_id" {
  description = "Foundation endpoint-client group, with no ingress and only endpoint HTTPS egress."
  type        = string
  nullable    = false
}

variable "endpoint_ids" {
  description = "Foundation endpoint_ids output; read-only validation, never manages company endpoints."
  type        = map(string)
  nullable    = false
  validation {
    condition = (
      toset(keys(var.endpoint_ids)) == toset(["ecr.api", "ecr.dkr", "logs", "secretsmanager", "s3"]) &&
      alltrue([for id in values(var.endpoint_ids) : can(regex("^vpce-[a-f0-9]+$", id))])
    )
    error_message = "Supply exactly ecr.api, ecr.dkr, logs, secretsmanager, and s3 endpoint IDs."
  }
}

variable "challenge_secret_arn" {
  description = "Existing challenge-only JSON secret; never the platform secret or a copy of .env."
  type        = string
  nullable    = false
  validation {
    condition     = can(regex("^arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{6}$", var.challenge_secret_arn))
    error_message = "Supply a complete, unqualified Secrets Manager ARN from the selected account and region."
  }
}

variable "challenge_secret_version_id" {
  description = "Immutable version shared by all teams; retain this version for the entire event."
  type        = string
  nullable    = false
  validation {
    condition     = can(regex("^[A-Za-z0-9-]{32,64}$", var.challenge_secret_version_id))
    error_message = "Supply the 32–64 character secret version ID, not a moving version stage."
  }
}

variable "secret_kms_key_arn" {
  description = "Customer-managed key encrypting the challenge secret, if used."
  type        = string
  default     = null
  nullable    = true
  validation {
    condition     = var.secret_kms_key_arn == null ? true : can(regex("^arn:aws:kms:${var.aws_region}:${var.aws_account_id}:key/[a-zA-Z0-9-]+$", var.secret_kms_key_arn))
    error_message = "Supply a KMS key ARN from the selected account and region."
  }
}

variable "images" {
  description = "Linux amd64 runtime images mirrored to ECR and pinned by digest; never the player artifact."
  type        = object({ gitea = string, gitea_seed = string, localstack = string })
  nullable    = false
  validation {
    condition     = alltrue([for uri in values(var.images) : can(regex("^${var.aws_account_id}\\.dkr\\.ecr\\.${var.aws_region}\\.amazonaws\\.com/[a-z0-9/_-]+@sha256:[a-f0-9]{64}$", uri))])
    error_message = "Images must be immutable ECR digests in the selected AWS account and region."
  }
}

variable "deploy_user" {
  description = "Shared DEPLOY_USER from the event's artifact; not an access-control identity."
  type        = string
  nullable    = false
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,38}$", var.deploy_user)) && var.deploy_user != "gitea-admin"
    error_message = "Use a lowercase Gitea username distinct from gitea-admin."
  }
}

variable "task_size" {
  description = "Per-team Fargate CPU units and MiB; container hard limits total 3584 MiB."
  type        = object({ cpu = number, memory = number })
  default     = { cpu = 1024, memory = 4096 }
  nullable    = false
  validation {
    condition = (
      contains([1024, 2048, 4096], var.task_size.cpu) &&
      var.task_size.memory >= 4096 && var.task_size.memory % 1024 == 0 &&
      var.task_size.memory <= lookup({ "1024" = 8192, "2048" = 16384, "4096" = 30720 }, tostring(var.task_size.cpu), 0) &&
      (var.task_size.cpu != 4096 || var.task_size.memory >= 8192)
    )
    error_message = "Use a supported Fargate size: 1 vCPU/4–8 GiB, 2 vCPU/4–16 GiB, or 4 vCPU/8–30 GiB, in 1 GiB steps."
  }
}

variable "log_retention_days" {
  description = "Finite retention for potentially sensitive team logs; destroyed with the team."
  type        = number
  default     = 7
  nullable    = false
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90], var.log_retention_days)
    error_message = "Use 1, 3, 5, 7, 14, 30, 60, or 90 days."
  }
}

variable "tags" {
  description = "Additional tags; event, component, and team identity tags are reserved."
  type        = map(string)
  default     = {}
  nullable    = false
}
