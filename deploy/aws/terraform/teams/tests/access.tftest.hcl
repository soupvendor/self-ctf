mock_provider "aws" {
  mock_data "aws_route53_zone" { defaults = { private_zone = true, name = "ctf.example.com.", zone_id = "Z000000000001" } }
  mock_resource "aws_lb" { defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/test/0000000000000001", dns_name = "internal-test.us-east-1.elb.amazonaws.com", zone_id = "Z000000000001" } }
  mock_resource "aws_lb_listener" { defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/test/0000000000000001/0000000000000001" } }
  mock_resource "aws_lb_target_group" { defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/test/0000000000000001" } }
  override_during = plan
  mock_data "aws_vpc" {
    defaults = { enable_dns_support = true, enable_dns_hostnames = true }
  }
  mock_data "aws_subnet" {
    defaults = { vpc_id = "vpc-00000000000000001", map_public_ip_on_launch = false, availability_zone = "us-east-1a" }
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
  team_access = {
    domain          = "ctf.example.com"
    hosted_zone_id  = "Z000000000001"
    certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000001"
    vpn_ipv4_cidrs  = ["10.20.30.0/24"]
  }
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

override_data {
  target = data.aws_subnet.selected["subnet-00000000000000002"]
  values = { vpc_id = "vpc-00000000000000001", map_public_ip_on_launch = false, availability_zone = "us-east-1b" }
}

run "vpn_https_routing" {
  command = plan
  assert {
    condition = (
      aws_lb.teams[0].internal && aws_lb.teams[0].preserve_host_header &&
      aws_lb_listener.https[0].port == 443 && aws_lb_listener.https[0].protocol == "HTTPS" &&
      aws_lb_listener.https[0].certificate_arn == var.team_access.certificate_arn &&
      one(one(aws_lb_listener.https[0].default_action).fixed_response).status_code == "404" &&
      toset(keys(aws_vpc_security_group_ingress_rule.vpn)) == var.team_access.vpn_ipv4_cidrs &&
      alltrue([for rule in aws_vpc_security_group_ingress_rule.vpn : rule.from_port == 443 && rule.to_port == 443]) &&
      length(aws_lb_target_group.team) == 4 && length(aws_lb_listener_rule.team) == 4 &&
      length(aws_vpc_security_group_egress_rule.alb_to_team) == 4 &&
      alltrue([for key, group in aws_lb_target_group.team :
        group.target_type == "ip" && group.protocol == "HTTP" && group.port == local.endpoints[key].port
      ]) &&
      alltrue([for key, rule in aws_lb_listener_rule.team :
        one(one(rule.condition).host_header).values == toset([local.endpoints[key].hostname])
      ])
    )
    error_message = "Only VPN HTTPS may reach exact team host routes; unknown hosts must get 404."
  }
  assert {
    condition = (
      alltrue([for group in aws_security_group.team :
        length(group.egress) == 0 && length(group.ingress) == 2 &&
        alltrue([for rule in group.ingress :
          toset(rule.security_groups) == toset([aws_security_group.alb[0].id]) &&
          length(rule.cidr_blocks) == 0 && contains([3000, 4566], rule.from_port) && rule.from_port == rule.to_port
        ])
      ]) &&
      alltrue([for service in aws_ecs_service.team : length(service.load_balancer) == 2]) &&
      alltrue([for key, record in aws_route53_record.team : record.name == local.endpoints[key].hostname && !record.allow_overwrite]) &&
      output.team_endpoints.red.team_hostname == "red.ctf.example.com" &&
      output.team_endpoints.red.gitea_url == "https://gitea-red.ctf.example.com" &&
      output.team_endpoints.blue.aws_url == "https://aws-blue.ctf.example.com"
    )
    error_message = "Each backend must accept only its ALB ports and publish distinct, non-overwriting private DNS records."
  }
  assert {
    condition = alltrue([for id, task in aws_ecs_task_definition.team :
      one([for container in jsondecode(task.container_definitions) :
        one([for item in container.environment : item.value if item.name == "GITEA__server__ROOT_URL"])
        if container.name == "gitea"
      ]) == "https://gitea-${id}.ctf.example.com/" &&
      one([for item in local.containers.gitea-seed.environment : item.value if item.name == "LOCALSTACK_PORT"]) == "443" &&
      one([for item in local.containers.gitea-seed.environment : item.value if item.name == "LOCALSTACK_SCHEME"]) == "https" &&
      one([for item in local.containers.gitea-seed.environment : item.value if item.name == "LOCALSTACK_HOST_PREFIX"]) == "aws-"
    ])
    error_message = "Runtime root URLs and planted handoffs must agree with the HTTPS endpoint contract."
  }
}

run "empty_roster_with_access" {
  command = plan
  variables { team_ids = [] }
  assert {
    condition     = length(aws_lb.teams) == 1 && length(aws_lb_target_group.team) == 0 && length(aws_route53_record.team) == 0
    error_message = "Removing the last team must preserve the event entry point but remove team routes."
  }
}

run "reject_public_zone" {
  command = plan
  variables {
    team_access = {
      domain          = "ctf.example.com"
      hosted_zone_id  = "ZPUBLIC000001"
      certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000001"
      vpn_ipv4_cidrs  = ["10.20.30.0/24"]
    }
  }
  expect_failures = [data.aws_route53_zone.team[0]]
}

run "reject_wrong_zone" {
  command = plan
  override_data {
    target = data.aws_route53_zone.supplied[0]
    values = { private_zone = true, name = "other.example.com." }
  }
  expect_failures = [data.aws_route53_zone.team[0]]
}

run "reject_unrestricted_vpn" {
  command = plan
  variables {
    team_access = {
      domain          = "ctf.example.com"
      hosted_zone_id  = "Z000000000001"
      certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000001"
      vpn_ipv4_cidrs  = ["0.0.0.0/0"]
    }
  }
  expect_failures = [var.team_access]
}
