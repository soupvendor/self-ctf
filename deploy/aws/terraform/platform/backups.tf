resource "aws_ssm_document" "backup" {
  name            = "${local.platform_name}-backup"
  document_type   = "Command"
  document_format = "JSON"
  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Stop the platform cleanly before its data snapshot; resume only the matching backup."
    parameters = {
      executionId = {
        type           = "String", default = "None"
        allowedPattern = "^(None|[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12})$"
      }
      command = {
        type = "String", default = "dry-run", allowedValues = ["pre-script", "post-script", "dry-run"]
      }
    }
    mainSteps = [{
      action = "aws:runShellScript", name = "platformBackup"
      inputs = {
        timeoutSeconds = "120"
        runCommand     = ["SELF_CTF_BACKUP_DIR=/run PLATFORM_DATA_DIR=/srv/self-ctf /usr/local/lib/self-ctf/backup.sh '{{ command }}' '{{ executionId }}'"]
      }
    }]
  })
}

resource "aws_iam_role" "backup" {
  name = "${local.platform_name}-backup"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "dlm.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.aws_account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:dlm:${var.aws_region}:${var.aws_account_id}:policy/*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "backup" {
  role = aws_iam_role.backup.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ec2:DescribeInstances", "ec2:DescribeVolumes", "ec2:DescribeSnapshots", "ec2:DescribeTags", "ec2:DescribeAvailabilityZones",
        "ssm:DescribeInstanceInformation", "ssm:ListCommands", "ssm:ListCommandInvocations", "ssm:GetCommandInvocation"]
        Resource = "*"
      },
      {
        Effect   = "Allow", Action = ["ec2:CreateSnapshot", "ec2:CreateSnapshots"]
        Resource = [aws_instance.platform.arn, aws_ebs_volume.data.arn, "arn:aws:ec2:${var.aws_region}::snapshot/*"]
      },
      {
        Effect   = "Allow", Action = ["ec2:CreateTags"]
        Resource = "arn:aws:ec2:${var.aws_region}::snapshot/*"
      },
      {
        Effect    = "Allow", Action = ["ec2:DeleteSnapshot"]
        Resource  = "arn:aws:ec2:${var.aws_region}::snapshot/*"
        Condition = { StringEquals = { "ec2:ResourceTag/SelfCtfBackup" = local.platform_name } }
      },
      {
        Effect   = "Allow", Action = ["ssm:SendCommand"]
        Resource = [aws_instance.platform.arn, aws_ssm_document.backup.arn]
      },
      {
        Effect   = "Allow", Action = ["ssm:GetDocument", "ssm:DescribeDocument"]
        Resource = aws_ssm_document.backup.arn
      },
      {
        Effect = "Allow"
        Action = ["events:PutRule", "events:DeleteRule", "events:DescribeRule", "events:EnableRule",
        "events:DisableRule", "events:ListTargetsByRule", "events:PutTargets", "events:RemoveTargets"]
        Resource = "arn:aws:events:${var.aws_region}:${var.aws_account_id}:rule/AwsDataLifecycleRule.managed-cwe.*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "backup_kms" {
  count = var.ebs_kms_key_arn == null ? 0 : 1
  role  = aws_iam_role.backup.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKeyWithoutPlaintext", "kms:ReEncrypt*"]
        Resource = var.ebs_kms_key_arn
        Condition = {
          StringEquals = { "kms:ViaService" = "ec2.${var.aws_region}.amazonaws.com", "kms:CallerAccount" = var.aws_account_id }
        }
      },
      {
        Effect   = "Allow", Action = ["kms:CreateGrant"]
        Resource = var.ebs_kms_key_arn
        Condition = {
          Bool         = { "kms:GrantIsForAWSResource" = true }
          StringEquals = { "kms:ViaService" = "ec2.${var.aws_region}.amazonaws.com", "kms:CallerAccount" = var.aws_account_id }
        }
      }
    ]
  })
}

resource "aws_dlm_lifecycle_policy" "platform" {
  description        = "${local.platform_name} hourly application-consistent CTF data backups"
  execution_role_arn = aws_iam_role.backup.arn
  state              = var.backup_enabled ? "ENABLED" : "DISABLED"
  policy_details {
    policy_type    = "EBS_SNAPSHOT_MANAGEMENT"
    resource_types = ["INSTANCE"]
    target_tags    = { SelfCtfBackup = local.platform_name }
    parameters {
      exclude_boot_volume = true
    }
    schedule {
      name        = "hourly-consistent"
      copy_tags   = true
      tags_to_add = { SelfCtfBackup = local.platform_name }
      create_rule {
        interval      = 1
        interval_unit = "HOURS"
        times         = ["00:00"]
        scripts {
          stages                              = ["PRE", "POST"]
          execution_handler_service           = "AWS_SYSTEMS_MANAGER"
          execution_handler                   = aws_ssm_document.backup.name
          execute_operation_on_script_failure = false
          execution_timeout                   = 120
          # AWS defaults to zero retries; provider 6.63 rejects an explicit zero.
        }
      }
      retain_rule {
        count = var.backup_retention_count
      }
    }
  }
  depends_on = [aws_iam_role_policy.backup, aws_iam_role_policy.backup_kms, aws_volume_attachment.data]
}
