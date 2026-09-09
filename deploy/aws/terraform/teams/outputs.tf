output "cluster_name" {
  description = "ECS cluster used by team lifecycle operations."
  value       = aws_ecs_cluster.teams.name
}

output "teams" {
  description = "Operator identifiers; player endpoints are in team_endpoints when access is enabled."
  value = {
    for id in var.team_ids : id => {
      service_name        = aws_ecs_service.team[id].name
      task_definition_arn = aws_ecs_task_definition.team[id].arn
      security_group_id   = aws_security_group.team[id].id
      execution_role_arn  = aws_iam_role.execution[id].arn
      log_group_name      = aws_cloudwatch_log_group.team[id].name
    }
  }
}

output "team_endpoints" {
  description = "Assigned team hostname and HTTPS URLs; shared VPN access uses an honor system."
  value = var.team_access == null ? {} : {
    for id in var.team_ids : id => {
      team_hostname = "${id}.${var.team_access.domain}"
      gitea_url     = "https://gitea-${id}.${var.team_access.domain}"
      aws_url       = "https://aws-${id}.${var.team_access.domain}"
    }
  }
}

output "deployment" {
  description = "Identity guard for operator commands."
  value       = { account_id = var.aws_account_id, region = var.aws_region, event_name = var.event_name }
}
