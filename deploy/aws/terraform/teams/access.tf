locals {
  endpoints = var.team_access == null ? {} : merge([
    for team in var.team_ids : {
      for service, port in { gitea = 3000, localstack = 4566 } : "${team}/${service}" => {
        team                       = team
        service                    = service
        port                       = port
        hostname                   = "${service == "gitea" ? "gitea" : "aws"}-${team}.${var.team_access.domain}"
      }
    }
  ]...)
}

data "aws_route53_zone" "supplied" {
  count   = var.team_access == null ? 0 : 1
  zone_id = var.team_access.hosted_zone_id
}

data "aws_route53_zone" "team" {
  count        = var.team_access == null ? 0 : 1
  name         = data.aws_route53_zone.supplied[0].name
  vpc_id       = var.vpc_id
  private_zone = true
  lifecycle {
    postcondition {
      condition = self.zone_id == var.team_access.hosted_zone_id && (
        var.team_access.domain == trimsuffix(self.name, ".") ||
        endswith(var.team_access.domain, ".${trimsuffix(self.name, ".")}")
      )
      error_message = "Use the matching private hosted zone associated with this VPC and containing the team domain."
    }
  }
}

resource "aws_security_group" "alb" {
  count       = var.team_access == null ? 0 : 1
  name_prefix = "${var.event_name}-team-alb-"
  description = "HTTPS from the company VPN to disposable team services."
  vpc_id      = data.aws_vpc.selected.id
}

resource "aws_vpc_security_group_ingress_rule" "vpn" {
  for_each          = var.team_access == null ? toset([]) : var.team_access.vpn_ipv4_cidrs
  security_group_id = aws_security_group.alb[0].id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "alb_to_team" {
  for_each                     = local.endpoints
  security_group_id            = aws_security_group.alb[0].id
  referenced_security_group_id = aws_security_group.team[each.value.team].id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
}

resource "aws_lb" "teams" {
  count                      = var.team_access == null ? 0 : 1
  name_prefix                = "ctft-"
  internal                   = true
  load_balancer_type         = "application"
  subnets                    = var.private_subnet_ids
  security_groups            = [aws_security_group.alb[0].id]
  drop_invalid_header_fields = true
  preserve_host_header       = true
  lifecycle {
    precondition {
      condition     = length(toset([for subnet in data.aws_subnet.selected : subnet.availability_zone])) == length(var.private_subnet_ids)
      error_message = "The ALB requires one subnet per availability zone."
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = var.team_access == null ? 0 : 1
  load_balancer_arn = aws_lb.teams[0].arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.team_access.certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Unknown team endpoint"
      status_code  = "404"
    }
  }
}

resource "aws_lb_target_group" "team" {
  for_each             = local.endpoints
  name_prefix          = "ctft-"
  target_type          = "ip"
  vpc_id               = data.aws_vpc.selected.id
  port                 = each.value.port
  protocol             = "HTTP"
  deregistration_delay = 10
  health_check {
    path                = each.value.service == "gitea" ? "/api/healthz" : "/_localstack/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
  tags = { Team = each.value.team }
}

resource "aws_lb_listener_rule" "team" {
  for_each     = local.endpoints
  listener_arn = aws_lb_listener.https[0].arn
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.team[each.key].arn
  }
  condition {
    host_header { values = [each.value.hostname] }
  }
  tags = { Team = each.value.team }
}

resource "aws_route53_record" "team" {
  for_each        = local.endpoints
  zone_id         = data.aws_route53_zone.team[0].zone_id
  name            = each.value.hostname
  type            = "A"
  allow_overwrite = false
  alias {
    name                   = aws_lb.teams[0].dns_name
    zone_id                = aws_lb.teams[0].zone_id
    evaluate_target_health = true
  }
}
