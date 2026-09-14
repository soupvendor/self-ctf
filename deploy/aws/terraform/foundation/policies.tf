variable "runtime_secret_arns" {
  description = "Exact deployment secret ARNs allowed through a newly created Secrets Manager endpoint. Secret values never enter Terraform."
  type        = set(string)
  default     = []
  nullable    = false
  validation {
    condition = alltrue([
      for arn in var.runtime_secret_arns : can(regex("^arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{6}$", arn))
    ])
    error_message = "Use exact Secrets Manager ARNs in the deployment account and region; wildcards are forbidden."
  }
}

locals {
  endpoint_condition = {
    ArnLike = {
      "aws:PrincipalArn" = [
        "arn:aws:iam::${var.aws_account_id}:role/${var.event_name}-*-host",
        "arn:aws:iam::${var.aws_account_id}:role/${var.event_name}-????????????????-execution"
      ]
    }
    StringEquals = {
      "aws:SourceVpc"        = var.vpc_id
      "aws:PrincipalAccount" = var.aws_account_id
    }
  }
  pull_statement = {
    Effect    = "Allow", Principal = "*"
    Action    = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
    Resource  = [for name in sort(tolist(var.ecr_repository_names)) : "arn:aws:ecr:${var.aws_region}:${var.aws_account_id}:repository/${var.event_name}/${name}"]
    Condition = local.endpoint_condition
  }
  ecr_endpoint_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [local.pull_statement, {
      Effect    = "Allow", Principal = "*", Action = ["ecr:GetAuthorizationToken"], Resource = "*"
      Condition = local.endpoint_condition
    }]
  })
  interface_endpoint_policies = {
    "ecr.api" = local.ecr_endpoint_policy
    "ecr.dkr" = local.ecr_endpoint_policy
    logs = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect    = "Allow", Principal = "*", Action = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource  = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/self-ctf/${var.event_name}/teams/*:log-stream:*"
        Condition = local.endpoint_condition
      }]
    })
    secretsmanager = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect    = "Allow", Principal = "*", Action = ["secretsmanager:GetSecretValue"]
        Resource  = sort(tolist(var.runtime_secret_arns))
        Condition = local.endpoint_condition
      }]
    })
  }
  # ECR layer downloads use AWS-signed URLs, so their principal is not the task execution role.
  s3_endpoint_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow", Principal = "*", Action = ["s3:GetObject"]
      Resource  = "arn:aws:s3:::prod-${var.aws_region}-starport-layer-bucket/*"
      Condition = { StringEquals = { "aws:SourceVpc" = var.vpc_id } }
    }]
  })
}
