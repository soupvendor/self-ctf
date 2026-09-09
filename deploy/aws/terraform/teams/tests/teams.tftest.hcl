mock_provider "aws" {
  override_during = plan
  mock_data "aws_vpc" {
    defaults = { enable_dns_support = true, enable_dns_hostnames = true }
  }
  mock_data "aws_subnet" {
    defaults = { vpc_id = "vpc-00000000000000001", map_public_ip_on_launch = false }
  }
  mock_data "aws_route_tables" {
    defaults = { ids = ["rtb-00000000000000001"] }
  }
  mock_data "aws_route_table" {
    defaults = { id = "rtb-00000000000000001", routes = [] }
  }
  mock_data "aws_security_group" {
    defaults = { vpc_id = "vpc-00000000000000001" }
  }
  mock_data "aws_vpc_security_group_rules" {
    defaults = { ids = ["sgr-00000000000000001"] }
  }
  mock_data "aws_vpc_security_group_rule" {
    defaults = {
      is_egress                    = true, ip_protocol = "tcp", from_port = 443, to_port = 443
      referenced_security_group_id = "sg-00000000000000004", prefix_list_id = ""
    }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/test-role" }
  }
  mock_resource "aws_security_group" {
    defaults = { id = "sg-00000000000000011" }
  }
  mock_resource "aws_ecs_cluster" {
    defaults = { id = "arn:aws:ecs:us-east-1:123456789012:cluster/test-event-teams" }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:us-east-1:123456789012:task-definition/test-event-red:1" }
  }
}

variables {
  aws_region                        = "us-east-1"
  aws_account_id                    = "123456789012"
  event_name                        = "test-event"
  team_ids                          = ["red", "blue"]
  vpc_id                            = "vpc-00000000000000001"
  private_subnet_ids                = ["subnet-00000000000000001", "subnet-00000000000000002"]
  endpoint_client_security_group_id = "sg-00000000000000003"
  endpoint_ids = {
    "ecr.api"      = "vpce-00000000000000001"
    "ecr.dkr"      = "vpce-00000000000000002"
    logs           = "vpce-00000000000000003"
    secretsmanager = "vpce-00000000000000004"
    s3             = "vpce-00000000000000005"
  }
  challenge_secret_arn        = "arn:aws:secretsmanager:us-east-1:123456789012:secret:ctf/challenge-000001"
  challenge_secret_version_id = "00000000-0000-0000-0000-000000000001"
  deploy_user                 = "deploy-bot"
  images = {
    gitea      = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test-event/gitea@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    gitea_seed = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test-event/gitea-seed@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    localstack = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test-event/localstack-seeded@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
}

override_data {
  target = data.aws_vpc_endpoint.selected["ecr.api"]
  values = {
    vpc_id            = "vpc-00000000000000001", state = "available", service_name = "com.amazonaws.us-east-1.ecr.api"
    vpc_endpoint_type = "Interface", private_dns_enabled = true, security_group_ids = ["sg-00000000000000004"]
  }
}
override_data {
  target = data.aws_vpc_endpoint.selected["ecr.dkr"]
  values = {
    vpc_id            = "vpc-00000000000000001", state = "available", service_name = "com.amazonaws.us-east-1.ecr.dkr"
    vpc_endpoint_type = "Interface", private_dns_enabled = true, security_group_ids = ["sg-00000000000000004"]
  }
}
override_data {
  target = data.aws_vpc_endpoint.selected["logs"]
  values = {
    vpc_id            = "vpc-00000000000000001", state = "available", service_name = "com.amazonaws.us-east-1.logs"
    vpc_endpoint_type = "Interface", private_dns_enabled = true, security_group_ids = ["sg-00000000000000004"]
  }
}
override_data {
  target = data.aws_vpc_endpoint.selected["secretsmanager"]
  values = {
    vpc_id            = "vpc-00000000000000001", state = "available", service_name = "com.amazonaws.us-east-1.secretsmanager"
    vpc_endpoint_type = "Interface", private_dns_enabled = true, security_group_ids = ["sg-00000000000000004"]
  }
}
override_data {
  target = data.aws_vpc_endpoint.selected["s3"]
  values = {
    vpc_id            = "vpc-00000000000000001", state = "available", service_name = "com.amazonaws.us-east-1.s3"
    vpc_endpoint_type = "Gateway", route_table_ids = ["rtb-00000000000000001"], prefix_list_id = "pl-00000000000000001"
  }
}
override_resource {
  override_during = plan
  target          = aws_cloudwatch_log_group.team["red"]
  values          = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:/self-ctf/test-event/teams/red" }
}
override_resource {
  override_during = plan
  target          = aws_cloudwatch_log_group.team["blue"]
  values          = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:/self-ctf/test-event/teams/blue" }
}
override_resource {
  override_during = plan
  target          = aws_security_group.team["blue"]
  values          = { id = "sg-00000000000000012" }
}

run "disposable_singleton_teams" {
  command = plan
  assert {
    condition = (
      toset(keys(aws_ecs_service.team)) == var.team_ids &&
      toset(keys(aws_ecs_task_definition.team)) == var.team_ids &&
      alltrue([for id, service in aws_ecs_service.team :
        service.name == id && service.desired_count == 1 && service.launch_type == "FARGATE" &&
        service.platform_version == "1.4.0" && !service.enable_execute_command &&
        service.wait_for_steady_state && service.deployment_minimum_healthy_percent == 0 &&
        service.deployment_maximum_percent == 100 && service.availability_zone_rebalancing == "DISABLED" &&
        one(service.deployment_circuit_breaker).enable && !one(service.deployment_circuit_breaker).rollback &&
        !one(service.network_configuration).assign_public_ip &&
        one(service.network_configuration).security_groups == toset([aws_security_group.team[id].id, var.endpoint_client_security_group_id])
      ])
    )
    error_message = "Each team needs one private, stop-before-start Fargate service with failure detection and no ECS Exec."
  }
  assert {
    condition = alltrue([for id, task in aws_ecs_task_definition.team :
      task.family == "test-event-${id}" && task.network_mode == "awsvpc" && task.task_role_arn == null &&
      task.cpu == "1024" && task.memory == "4096" &&
      one(task.runtime_platform).cpu_architecture == "X86_64" &&
      one(task.runtime_platform).operating_system_family == "LINUX" &&
      toset([for volume in task.volume : volume.name]) == toset(["gitea-data", "gitea-config"]) &&
      alltrue([for volume in task.volume :
        volume.host_path == null && length(volume.efs_volume_configuration) == 0 &&
        length(volume.docker_volume_configuration) == 0
      ])
    ])
    error_message = "Teams must have no application AWS role or persistent/shared/host storage."
  }
  assert {
    condition = alltrue([for task in aws_ecs_task_definition.team :
      alltrue([for container in jsondecode(task.container_definitions) :
        container.user == "1000:1000" && container.memory > 0 &&
        container.linuxParameters.capabilities.drop == ["ALL"] &&
        container.linuxParameters.initProcessEnabled &&
        !contains(keys(container), "privileged") && !contains(keys(container), "dockerSecurityOptions") &&
        container.logConfiguration.options.mode == "non-blocking" &&
        container.logConfiguration.options["max-buffer-size"] == "4m"
      ])
    ])
    error_message = "Every container must be non-root, capability-free, resource-limited, and Fargate-compatible."
  }
}

run "seed_gates_readiness" {
  command = plan
  assert {
    condition = (
      local.containers.gitea.essential && !local.containers.gitea-seed.essential && local.containers.localstack.essential &&
      one(local.containers.gitea-seed.dependsOn).containerName == "gitea" &&
      one(local.containers.gitea-seed.dependsOn).condition == "HEALTHY" &&
      one(local.containers.localstack.dependsOn).containerName == "gitea-seed" &&
      one(local.containers.localstack.dependsOn).condition == "SUCCESS" &&
      local.containers.gitea.startTimeout == 120 && local.containers.gitea-seed.startTimeout == 120 &&
      local.containers.gitea.mountPoints == local.containers.gitea-seed.mountPoints &&
      toset([for mount in local.gitea_mounts : mount.containerPath]) == toset(["/var/lib/gitea", "/etc/gitea"]) &&
      one([for item in local.containers.gitea-seed.environment : item.value if item.name == "GITEA_INTERNAL_URL"]) == "http://127.0.0.1:3000" &&
      strcontains(local.containers.localstack.healthCheck.command[1], "secretsmanager describe-secret --secret-id platform/break-glass/root-recovery") &&
      local.containers.gitea.healthCheck.retries <= 10 && local.containers.localstack.healthCheck.retries <= 10
    )
    error_message = "Essential service readiness must depend on verified seeding, using Fargate loopback and supported dependency/health timeouts."
  }
}

run "shared_pinned_secret_minimal_injection" {
  command = plan
  assert {
    condition = (
      !contains(keys(local.containers.gitea), "secrets") &&
      toset([for secret in local.containers.gitea-seed.secrets : secret.name]) == toset(["GITEA_ADMIN_PASSWORD", "CI_PASS", "FLAG_PIPELINE"]) &&
      one(local.containers.localstack.secrets).name == "FLAG_CLOUD" &&
      alltrue([for secret in concat(local.containers.gitea-seed.secrets, local.containers.localstack.secrets) :
        startswith(secret.valueFrom, "${var.challenge_secret_arn}:") &&
        endswith(secret.valueFrom, "::${var.challenge_secret_version_id}")
      ]) &&
      one([for secret in local.containers.gitea-seed.secrets : secret.valueFrom if secret.name == "CI_PASS"]) == "${var.challenge_secret_arn}:DEPLOY_PASSWORD::${var.challenge_secret_version_id}" &&
      alltrue([for task in aws_ecs_task_definition.team :
        !strcontains(task.container_definitions, "CTFD_") && !strcontains(task.container_definitions, "FLAG_LAYERS") &&
        !strcontains(task.container_definitions, "AWS_ACCESS_KEY_ID") &&
        alltrue([for container in jsondecode(task.container_definitions) :
          alltrue([for item in container.environment : !can(regex("FLAG_|PASSWORD|CI_PASS", item.name))])
        ])
      ])
    )
    error_message = "Only needed challenge fields may be injected; all teams must use the exact same immutable secret version, without payloads in Terraform."
  }
}

run "least_privilege_execution" {
  command = plan
  assert {
    condition = alltrue([for id, policy in aws_iam_role_policy.execution :
      length(jsondecode(policy.policy).Statement) == 4 &&
      jsondecode(policy.policy).Statement[0].Action == ["ecr:GetAuthorizationToken"] &&
      jsondecode(policy.policy).Statement[0].Resource == "*" &&
      toset(jsondecode(policy.policy).Statement[1].Resource) == toset([
        "arn:aws:ecr:us-east-1:123456789012:repository/test-event/gitea",
        "arn:aws:ecr:us-east-1:123456789012:repository/test-event/gitea-seed",
        "arn:aws:ecr:us-east-1:123456789012:repository/test-event/localstack-seeded"
      ]) &&
      jsondecode(policy.policy).Statement[2].Resource == var.challenge_secret_arn &&
      jsondecode(policy.policy).Statement[2].Action == ["secretsmanager:GetSecretValue"] &&
      jsondecode(policy.policy).Statement[3].Resource == "arn:aws:logs:us-east-1:123456789012:log-group:/self-ctf/test-event/teams/${id}:log-stream:team/*" &&
      toset(jsondecode(policy.policy).Statement[3].Action) == toset(["logs:CreateLogStream", "logs:PutLogEvents"])
    ])
    error_message = "Execution roles may pull only runtime images, read one challenge secret, and write their own team's logs."
  }
  assert {
    condition = alltrue([for role in aws_iam_role.execution :
      one(jsondecode(role.assume_role_policy).Statement).Principal.Service == "ecs-tasks.amazonaws.com" &&
      one(jsondecode(role.assume_role_policy).Statement).Condition.StringEquals["aws:SourceAccount"] == var.aws_account_id &&
      one(jsondecode(role.assume_role_policy).Statement).Condition.ArnLike["aws:SourceArn"] == "arn:aws:ecs:us-east-1:123456789012:*"
    ])
    error_message = "Only ECS tasks in this account/region may assume execution roles."
  }
}

run "closed_backend" {
  command = plan
  assert {
    condition = (
      length(aws_security_group.team) == 2 &&
      aws_security_group.team["red"].id != aws_security_group.team["blue"].id &&
      alltrue([for group in aws_security_group.team : length(group.ingress) == 0 && length(group.egress) == 0]) &&
      alltrue([for group in aws_cloudwatch_log_group.team : group.retention_in_days == 7]) &&
      toset(keys(output.teams)) == var.team_ids &&
      alltrue([for team in values(output.teams) : !contains(keys(team), "endpoint")])
    )
    error_message = "This backend-only stage must not expose a player endpoint or silently allow the shared VPN CIDR."
  }
}

run "custom_key" {
  command = plan
  variables { secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001" }
  assert {
    condition = alltrue([for policy in aws_iam_role_policy.execution :
      jsondecode(policy.policy).Statement[4].Resource == var.secret_kms_key_arn &&
      jsondecode(policy.policy).Statement[4].Condition.StringEquals["kms:ViaService"] == "secretsmanager.us-east-1.amazonaws.com" &&
      jsondecode(policy.policy).Statement[4].Condition.StringEquals["kms:EncryptionContext:SecretARN"] == var.challenge_secret_arn
    ])
    error_message = "Decrypt must be restricted to the challenge's key and encryption context."
  }
}

run "empty_roster" {
  command = plan
  variables { team_ids = [] }
  assert {
    condition = (
      length(aws_ecs_service.team) == 0 && length(aws_ecs_task_definition.team) == 0 &&
      length(aws_iam_role.execution) == 0 && length(aws_security_group.team) == 0 && length(aws_cloudwatch_log_group.team) == 0
    )
    error_message = "An empty roster must remove only the disposable team resources."
  }
}

run "larger_task" {
  command = plan
  variables { task_size = { cpu = 2048, memory = 8192 } }
  assert {
    condition     = alltrue([for task in aws_ecs_task_definition.team : task.cpu == "2048" && task.memory == "8192"])
    error_message = "Operator task size must reach the definition."
  }
}

run "main_route_table" {
  command = plan
  override_data {
    target = data.aws_route_tables.explicit["subnet-00000000000000001"]
    values = { ids = [] }
  }
  assert {
    condition     = data.aws_route_table.selected["subnet-00000000000000001"].route_table_id == data.aws_route_table.main.id
    error_message = "Unassociated subnets must validate the main route table."
  }
}

run "reject_invalid_team_id" {
  command = plan
  variables { team_ids = ["../red"] }
  expect_failures = [var.team_ids]
}
run "reject_moving_secret_stage" {
  command = plan
  variables { challenge_secret_version_id = "AWSCURRENT" }
  expect_failures = [var.challenge_secret_version_id]
}
run "reject_qualified_secret_arn" {
  command = plan
  variables { challenge_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:ctf/challenge-000001:FLAG_CLOUD::" }
  expect_failures = [var.challenge_secret_arn]
}
run "reject_small_task" {
  command = plan
  variables { task_size = { cpu = 1024, memory = 2048 } }
  expect_failures = [var.task_size]
}
run "reject_invalid_fargate_size" {
  command = plan
  variables { task_size = { cpu = 4096, memory = 4096 } }
  expect_failures = [var.task_size]
}
run "reject_infinite_logs" {
  command = plan
  variables { log_retention_days = 0 }
  expect_failures = [var.log_retention_days]
}
run "reject_admin_deploy_user" {
  command = plan
  variables { deploy_user = "gitea-admin" }
  expect_failures = [var.deploy_user]
}
run "reject_public_subnet" {
  command = plan
  override_data {
    target = data.aws_subnet.selected["subnet-00000000000000001"]
    values = { vpc_id = "vpc-00000000000000001", map_public_ip_on_launch = true }
  }
  expect_failures = [data.aws_subnet.selected["subnet-00000000000000001"]]
}
run "reject_wrong_vpc" {
  command = plan
  override_data {
    target = data.aws_subnet.selected["subnet-00000000000000001"]
    values = { vpc_id = "vpc-00000000000000099", map_public_ip_on_launch = false }
  }
  expect_failures = [data.aws_subnet.selected["subnet-00000000000000001"]]
}
run "reject_public_route" {
  command = plan
  override_data {
    target = data.aws_route_table.selected["subnet-00000000000000001"]
    values = { routes = [{ gateway_id = "igw-00000000000000001" }] }
  }
  expect_failures = [data.aws_route_table.selected["subnet-00000000000000001"]]
}
run "reject_client_ingress" {
  command = plan
  override_data {
    target = data.aws_vpc_security_group_rule.endpoint_clients["sgr-00000000000000001"]
    values = {
      is_egress                    = false, ip_protocol = "tcp", from_port = 3000, to_port = 3000, cidr_ipv4 = "10.0.0.0/8"
      referenced_security_group_id = "", prefix_list_id = ""
    }
  }
  expect_failures = [data.aws_vpc_security_group_rule.endpoint_clients["sgr-00000000000000001"]]
}
run "reject_broad_egress" {
  command = plan
  override_data {
    target = data.aws_vpc_security_group_rule.endpoint_clients["sgr-00000000000000001"]
    values = {
      is_egress                    = true, ip_protocol = "-1", from_port = 0, to_port = 0, cidr_ipv4 = "0.0.0.0/0"
      referenced_security_group_id = "", prefix_list_id = ""
    }
  }
  expect_failures = [data.aws_vpc_security_group_rule.endpoint_clients["sgr-00000000000000001"]]
}
run "reject_non_endpoint_group" {
  command = plan
  override_data {
    target = data.aws_vpc_security_group_rule.endpoint_clients["sgr-00000000000000001"]
    values = {
      is_egress                    = true, ip_protocol = "tcp", from_port = 443, to_port = 443
      referenced_security_group_id = "sg-00000000000000099", prefix_list_id = ""
    }
  }
  expect_failures = [data.aws_vpc_security_group_rule.endpoint_clients["sgr-00000000000000001"]]
}
run "reject_missing_s3_routes" {
  command = plan
  override_data {
    target = data.aws_vpc_endpoint.selected["s3"]
    values = {
      vpc_id            = "vpc-00000000000000001", state = "available", service_name = "com.amazonaws.us-east-1.s3"
      vpc_endpoint_type = "Gateway", route_table_ids = [], prefix_list_id = "pl-00000000000000001"
    }
  }
  expect_failures = [data.aws_vpc_endpoint.selected["s3"]]
}

run "s3_egress" {
  command = plan
  override_data {
    target = data.aws_vpc_security_group_rule.endpoint_clients["sgr-00000000000000001"]
    values = {
      is_egress                    = true, ip_protocol = "tcp", from_port = 443, to_port = 443
      referenced_security_group_id = "", prefix_list_id = "pl-00000000000000001"
    }
  }
  assert {
    condition     = length(aws_ecs_service.team) == 2
    error_message = "HTTPS egress to the selected S3 endpoint prefix list must be accepted."
  }
}
run "reject_https_cidr_egress" {
  command = plan
  override_data {
    target = data.aws_vpc_security_group_rule.endpoint_clients["sgr-00000000000000001"]
    values = {
      is_egress                    = true, ip_protocol = "tcp", from_port = 443, to_port = 443, cidr_ipv4 = "10.0.0.0/8"
      referenced_security_group_id = "", prefix_list_id = ""
    }
  }
  expect_failures = [data.aws_vpc_security_group_rule.endpoint_clients["sgr-00000000000000001"]]
}
run "reject_wrong_client_vpc" {
  command = plan
  override_data {
    target = data.aws_security_group.endpoint_clients
    values = { vpc_id = "vpc-00000000000000099" }
  }
  expect_failures = [data.aws_security_group.endpoint_clients]
}
run "reject_mutable_image" {
  command = plan
  variables {
    images = {
      gitea      = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test-event/gitea:latest"
      gitea_seed = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test-event/gitea-seed@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      localstack = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test-event/localstack-seeded@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }
  expect_failures = [var.images]
}
run "reject_missing_private_dns" {
  command = plan
  override_data {
    target = data.aws_vpc_endpoint.selected["ecr.api"]
    values = {
      vpc_id            = "vpc-00000000000000001", state = "available", service_name = "com.amazonaws.us-east-1.ecr.api"
      vpc_endpoint_type = "Interface", private_dns_enabled = false, security_group_ids = ["sg-00000000000000004"]
    }
  }
  expect_failures = [data.aws_vpc_endpoint.selected["ecr.api"]]
}
