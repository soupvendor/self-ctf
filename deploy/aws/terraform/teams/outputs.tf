output "cluster_name" {
  description = "ECS cluster used by team lifecycle operations."
  value       = aws_ecs_cluster.teams.name
}

output "teams" {
  description = "Operator identifiers only, not player endpoints; all ingress remains closed."
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
