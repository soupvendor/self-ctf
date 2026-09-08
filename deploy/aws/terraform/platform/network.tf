data "aws_vpc" "selected" {
  id = var.vpc_id
  lifecycle {
    postcondition {
      condition     = self.enable_dns_support && self.enable_dns_hostnames
      error_message = "VPC DNS support and hostnames must be enabled."
    }
  }
}

data "aws_subnet" "selected" {
  for_each = var.private_subnet_ids
  id       = each.value
  lifecycle {
    postcondition {
      condition     = self.vpc_id == var.vpc_id && !self.map_public_ip_on_launch
      error_message = "Use private subnets in the selected VPC."
    }
  }
}

data "aws_route_tables" "explicit" {
  for_each = var.private_subnet_ids
  vpc_id   = var.vpc_id
  filter {
    name   = "association.subnet-id"
    values = [each.value]
  }
}

data "aws_route_table" "main" {
  vpc_id = var.vpc_id
  filter {
    name   = "association.main"
    values = ["true"]
  }
}

data "aws_route_table" "selected" {
  for_each       = var.private_subnet_ids
  route_table_id = length(data.aws_route_tables.explicit[each.key].ids) == 0 ? data.aws_route_table.main.id : one(data.aws_route_tables.explicit[each.key].ids)
  lifecycle {
    postcondition {
      condition     = alltrue([for route in self.routes : !startswith(route.gateway_id == null ? "" : route.gateway_id, "igw-")])
      error_message = "Platform and ALB subnets must not route directly to an internet gateway."
    }
  }
}

data "aws_security_group" "endpoint_clients" {
  id = var.endpoint_client_security_group_id
  lifecycle {
    postcondition {
      condition     = self.vpc_id == var.vpc_id
      error_message = "The foundation endpoint client group must belong to this VPC."
    }
  }
}

data "aws_vpc_endpoint" "ssm" {
  for_each = var.ssm_endpoint_ids
  id       = each.value
  lifecycle {
    postcondition {
      condition = (
        self.vpc_id == var.vpc_id && self.state == "available" &&
        self.service_name == "com.amazonaws.${var.aws_region}.${each.key}" &&
        self.vpc_endpoint_type == "Interface" && self.private_dns_enabled
      )
      error_message = "SSM endpoints must be available with private DNS in the selected VPC and region."
    }
  }
}

locals {
  ssm_security_groups = toset(flatten([for endpoint in data.aws_vpc_endpoint.ssm : tolist(endpoint.security_group_ids)]))
}

resource "aws_security_group" "host" {
  name_prefix = "${var.event_name}-platform-"
  description = "CTFd from the ALB; HTTPS to company SSM endpoints."
  vpc_id      = data.aws_vpc.selected.id
}

resource "aws_security_group" "alb" {
  name_prefix = "${var.event_name}-platform-alb-"
  description = "Company HTTPS clients only."
  vpc_id      = data.aws_vpc.selected.id
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  for_each          = setunion(var.admin_ipv4_cidrs, var.enable_player_access ? var.player_ipv4_cidrs : toset([]))
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "alb_to_host" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.host.id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
}

resource "aws_vpc_security_group_ingress_rule" "ctfd" {
  security_group_id            = aws_security_group.host.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
}

resource "aws_vpc_security_group_egress_rule" "ssm" {
  for_each                     = local.ssm_security_groups
  security_group_id            = aws_security_group.host.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_lb" "platform" {
  name_prefix                = "ctfd-"
  internal                   = true
  load_balancer_type         = "application"
  subnets                    = var.private_subnet_ids
  security_groups            = [aws_security_group.alb.id]
  enable_deletion_protection = var.protect_instance
  drop_invalid_header_fields = true
  lifecycle {
    precondition {
      condition     = length(toset([for subnet in data.aws_subnet.selected : subnet.availability_zone])) == length(var.private_subnet_ids)
      error_message = "The ALB requires exactly one subnet per availability zone."
    }
  }
}

resource "aws_lb_target_group" "platform" {
  name_prefix          = "ctfd-"
  port                 = 8000
  protocol             = "HTTP"
  vpc_id               = data.aws_vpc.selected.id
  target_type          = "instance"
  deregistration_delay = 30
  health_check {
    path                = "/healthcheck"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.platform.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.platform.arn
  }
}

resource "aws_lb_target_group_attachment" "platform" {
  target_group_arn = aws_lb_target_group.platform.arn
  target_id        = aws_instance.platform.id
  port             = 8000
}
