locals {
  platform_name = "${var.event_name}-${var.platform_name}"
  registry      = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  repository_arns = toset([
    for image in values(var.images) :
    "arn:aws:ecr:${var.aws_region}:${var.aws_account_id}:repository/${trimprefix(split("@", image)[0], "${local.registry}/")}"
  ])
}

resource "aws_iam_role" "platform" {
  name = "${local.platform_name}-host"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_instance_profile" "platform" {
  name = "${local.platform_name}-host"
  role = aws_iam_role.platform.name
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.platform.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "platform" {
  role = aws_iam_role.platform.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
        Resource = local.repository_arns
      },
      {
        Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = var.platform_secret_arn
      }
      ], var.secret_kms_key_arn == null ? [] : [{
        Effect = "Allow", Action = ["kms:Decrypt"], Resource = var.secret_kms_key_arn
        Condition = { StringEquals = {
          "kms:ViaService"                  = "secretsmanager.${var.aws_region}.amazonaws.com"
          "kms:EncryptionContext:SecretARN" = var.platform_secret_arn
        } }
    }])
  })
}
