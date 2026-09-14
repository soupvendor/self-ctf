locals {
  registry = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  repository_arns = { for challenge, bundle in local.catalog : challenge => sort(distinct([
    for image in bundle.images :
    "arn:aws:ecr:${var.aws_region}:${var.aws_account_id}:repository/${trimprefix(split("@", image)[0], "${local.registry}/")}"
  ])) }
}

resource "aws_iam_role" "execution" {
  for_each = local.instances
  name     = "${var.event_name}-${substr(sha256(each.key), 0, 16)}-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ecs-tasks.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.aws_account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:ecs:${var.aws_region}:${var.aws_account_id}:*" }
      }
    }]
  })
  tags = { Team = each.value.team, Challenge = each.value.challenge }
}

resource "aws_iam_role_policy" "execution" {
  for_each = local.instances
  role     = aws_iam_role.execution[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      { Sid = "RegistryToken", Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      {
        Sid      = "RuntimeImages"
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
        Resource = local.repository_arns[each.value.challenge]
      },
      {
        Sid = "ChallengeSecret", Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = var.challenge_secrets[each.value.challenge].arn
      },
      {
        Sid      = "TeamLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.team[each.key].arn}:log-stream:team/*"
      }
      ], var.challenge_secrets[each.value.challenge].kms_key_arn == null ? [] : [{
        Sid = "ChallengeKey", Effect = "Allow", Action = ["kms:Decrypt"], Resource = var.challenge_secrets[each.value.challenge].kms_key_arn
        Condition = { StringEquals = {
          "kms:ViaService"                  = "secretsmanager.${var.aws_region}.amazonaws.com"
          "kms:EncryptionContext:SecretARN" = var.challenge_secrets[each.value.challenge].arn
        } }
    }])
  })
}
