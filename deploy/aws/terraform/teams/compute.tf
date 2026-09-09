locals {
  gitea_mounts = [
    { sourceVolume = "gitea-data", containerPath = "/var/lib/gitea", readOnly = false },
    { sourceVolume = "gitea-config", containerPath = "/etc/gitea", readOnly = false }
  ]
  containers = {
    gitea = {
      image        = var.images.gitea
      essential    = true
      memory       = 1024
      startTimeout = 120
      mountPoints  = local.gitea_mounts
      portMappings = [{ containerPort = 3000, protocol = "tcp" }]
      environment = [for name, value in {
        GITEA__database__DB_TYPE             = "sqlite3"
        GITEA__server__ROOT_URL              = "http://127.0.0.1:3000/"
        GITEA__security__INSTALL_LOCK        = "true"
        GITEA__service__DISABLE_REGISTRATION = "true"
      } : { name = name, value = value }]
      healthCheck = {
        command     = ["CMD", "curl", "-fsS", "http://127.0.0.1:3000/api/healthz"]
        interval    = 5
        timeout     = 5
        retries     = 10
        startPeriod = 10
      }
    }
    gitea-seed = {
      image        = var.images.gitea_seed
      essential    = false
      memory       = 512
      startTimeout = 120
      mountPoints  = local.gitea_mounts
      dependsOn    = [{ containerName = "gitea", condition = "HEALTHY" }]
      environment = [for name, value in {
        GITEA_INTERNAL_URL     = "http://127.0.0.1:3000"
        GITEA_ADMIN_NAME       = "gitea-admin"
        GITEA_ADMIN_EMAIL      = "gitea-admin@internal.local"
        CI_USER                = var.deploy_user
        LOCALSTACK_PORT        = var.team_access == null ? "4566" : "443"
        LOCALSTACK_SCHEME      = var.team_access == null ? "http" : "https"
        LOCALSTACK_HOST_PREFIX = var.team_access == null ? "" : "aws-"
        REPO_NAME              = "internal-deploy"
      } : { name = name, value = value }]
      secrets = [for field in [
        { name = "GITEA_ADMIN_PASSWORD", key = "GITEA_ADMIN_PASSWORD" },
        { name = "CI_PASS", key = "DEPLOY_PASSWORD" },
        { name = "FLAG_PIPELINE", key = "FLAG_PIPELINE" }
      ] : { name = field.name, valueFrom = "${var.challenge_secret_arn}:${field.key}::${var.challenge_secret_version_id}" }]
    }
    localstack = {
      image        = var.images.localstack
      essential    = true
      memory       = 2048
      dependsOn    = [{ containerName = "gitea-seed", condition = "SUCCESS" }]
      portMappings = [{ containerPort = 4566, protocol = "tcp" }]
      environment = [
        { name = "SERVICES", value = "secretsmanager,ssm,s3,sts,iam" },
        { name = "DEBUG", value = "0" }
      ]
      secrets = [{ name = "FLAG_CLOUD", valueFrom = "${var.challenge_secret_arn}:FLAG_CLOUD::${var.challenge_secret_version_id}" }]
      healthCheck = {
        command     = ["CMD-SHELL", "awslocal secretsmanager describe-secret --secret-id platform/break-glass/root-recovery >/dev/null 2>&1"]
        interval    = 10
        timeout     = 10
        retries     = 10
        startPeriod = 60
      }
    }
  }
}

resource "aws_ecs_cluster" "teams" {
  name = "${var.event_name}-teams"
  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_cloudwatch_log_group" "team" {
  for_each          = var.team_ids
  name              = "/self-ctf/${var.event_name}/teams/${each.key}"
  retention_in_days = var.log_retention_days
  tags              = { Team = each.key }
}

resource "aws_ecs_task_definition" "team" {
  for_each                 = var.team_ids
  family                   = "${var.event_name}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.task_size.cpu)
  memory                   = tostring(var.task_size.memory)
  execution_role_arn       = aws_iam_role.execution[each.key].arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  volume { name = "gitea-data" }
  volume { name = "gitea-config" }
  container_definitions = jsonencode([for name, container in local.containers : merge(container, {
    name        = name
    user        = "1000:1000"
    stopTimeout = 30
    environment = [for item in container.environment : {
      name = item.name
      value = item.name == "GITEA__server__ROOT_URL" && var.team_access != null ? (
        "https://gitea-${each.key}.${var.team_access.domain}/"
      ) : item.value
    }]
    linuxParameters = {
      initProcessEnabled = true
      capabilities       = { drop = ["ALL"] }
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.team[each.key].name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "team"
        mode                  = "non-blocking"
        max-buffer-size       = "4m"
      }
    }
  })])
  tags = { Team = each.key }
}

resource "aws_ecs_service" "team" {
  for_each                           = var.team_ids
  name                               = each.key
  cluster                            = aws_ecs_cluster.teams.id
  task_definition                    = aws_ecs_task_definition.team[each.key].arn
  desired_count                      = 1
  launch_type                        = "FARGATE"
  platform_version                   = "1.4.0"
  enable_execute_command             = false
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  availability_zone_rebalancing      = "DISABLED"
  wait_for_steady_state              = true
  propagate_tags                     = "TASK_DEFINITION"
  health_check_grace_period_seconds  = var.team_access == null ? 0 : 120
  dynamic "load_balancer" {
    for_each = { for key, endpoint in local.endpoints : key => endpoint if endpoint.team == each.key }
    content {
      target_group_arn = aws_lb_target_group.team[load_balancer.key].arn
      container_name   = load_balancer.value.service
      container_port   = load_balancer.value.port
    }
  }
  deployment_circuit_breaker {
    enable   = true
    rollback = false
  }
  network_configuration {
    subnets          = [for subnet in data.aws_subnet.selected : subnet.id]
    security_groups  = [aws_security_group.team[each.key].id, data.aws_security_group.endpoint_clients.id]
    assign_public_ip = false
  }
  depends_on = [aws_iam_role_policy.execution, data.aws_vpc_security_group_rule.endpoint_clients, aws_lb_listener_rule.team]
  tags       = { Team = each.key }
}
