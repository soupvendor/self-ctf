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
      error_message = "Team subnets must not route directly to an internet gateway."
    }
  }
}

data "aws_vpc_endpoint" "selected" {
  for_each = var.endpoint_ids
  id       = each.value
  lifecycle {
    postcondition {
      condition = (
        self.vpc_id == var.vpc_id && self.state == "available" &&
        self.service_name == "com.amazonaws.${var.aws_region}.${each.key}" &&
        (each.key == "s3" ? (
          self.vpc_endpoint_type == "Gateway" &&
          length(setsubtract(toset([for table in data.aws_route_table.selected : table.id]), self.route_table_ids)) == 0
          ) : (
          self.vpc_endpoint_type == "Interface" && self.private_dns_enabled
        ))
      )
      error_message = "Endpoints must match the selected VPC/service, with private DNS or all team subnet routes for S3."
    }
  }
}

locals {
  endpoint_security_group_ids = toset(flatten([
    for service, endpoint in data.aws_vpc_endpoint.selected : tolist(endpoint.security_group_ids) if service != "s3"
  ]))
}

data "aws_security_group" "endpoint_clients" {
  id = var.endpoint_client_security_group_id
  lifecycle {
    postcondition {
      condition     = self.vpc_id == var.vpc_id
      error_message = "The foundation endpoint-client group must belong to this VPC."
    }
  }
}

data "aws_vpc_security_group_rules" "endpoint_clients" {
  filter {
    name   = "group-id"
    values = [data.aws_security_group.endpoint_clients.id]
  }
  lifecycle {
    postcondition {
      condition     = length(self.ids) > 0
      error_message = "The foundation endpoint-client group must have endpoint egress rules."
    }
  }
}

data "aws_vpc_security_group_rule" "endpoint_clients" {
  for_each               = toset(data.aws_vpc_security_group_rules.endpoint_clients.ids)
  security_group_rule_id = each.value
  lifecycle {
    postcondition {
      condition = (
        self.is_egress && self.ip_protocol == "tcp" && self.from_port == 443 && self.to_port == 443 &&
        (contains(local.endpoint_security_group_ids, self.referenced_security_group_id) ||
        self.prefix_list_id == data.aws_vpc_endpoint.selected["s3"].prefix_list_id)
      )
      error_message = "Every endpoint-client rule must be outbound TCP 443 to a selected endpoint group or S3 prefix list; no ingress or CIDR destinations."
    }
  }
}

resource "aws_security_group" "team" {
  for_each    = var.team_ids
  name_prefix = "${var.event_name}-${each.key}-team-"
  description = "Closed team backend; player authorization and HTTPS are a later stage."
  vpc_id      = data.aws_vpc.selected.id
  ingress     = []
  egress      = []
  tags        = { Team = each.key }
}
