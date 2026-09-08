locals {
  alarm_actions = var.alarm_sns_topic_arn == null ? [] : [var.alarm_sns_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "platform_unhealthy" {
  alarm_name          = "${local.platform_name}-unhealthy"
  alarm_description   = "CTFd has remained unhealthy beyond the expected short backup pause."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { LoadBalancer = aws_lb.platform.arn_suffix, TargetGroup = aws_lb_target_group.platform.arn_suffix }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "backup_failure" {
  for_each            = toset(["PreScriptFailed", "PostScriptFailed", "SnapshotsCreateFailed", "SnapshotsDeleteFailed"])
  alarm_name          = "${local.platform_name}-${each.value}"
  alarm_description   = "Investigate the DLM policy and SSM command; a failed post script can leave CTFd stopped."
  namespace           = "AWS/EBS"
  metric_name         = each.value
  dimensions          = { DLMPolicyId = aws_dlm_lifecycle_policy.platform.id }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}
