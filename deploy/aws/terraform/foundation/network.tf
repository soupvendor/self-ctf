data "aws_vpc" "selected" {
  id = var.vpc_id

  lifecycle {
    postcondition {
      condition     = self.enable_dns_support && self.enable_dns_hostnames
      error_message = "The existing VPC must enable DNS support and DNS hostnames for private endpoints."
    }
  }
}

data "aws_subnet" "selected" {
  for_each = var.private_subnet_ids
  id       = each.value

  lifecycle {
    postcondition {
      condition     = self.vpc_id == var.vpc_id && !self.map_public_ip_on_launch
      error_message = "Every subnet must belong to the selected VPC and disable automatic public IPv4 addresses."
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
  for_each = var.private_subnet_ids
  # AWS uses the VPC main route table when a subnet has no explicit association.
  route_table_id = length(data.aws_route_tables.explicit[each.key].ids) == 0 ? (
    data.aws_route_table.main.id
  ) : one(data.aws_route_tables.explicit[each.key].ids)

  lifecycle {
    postcondition {
      condition = alltrue([
        for route in self.routes : !startswith(route.gateway_id == null ? "" : route.gateway_id, "igw-")
      ])
      error_message = "Selected subnets must not route directly to an internet gateway."
    }
  }
}

locals {
  interface_services = toset(["ecr.api", "ecr.dkr", "logs", "secretsmanager"])
  created_interfaces = setsubtract(local.interface_services, toset(keys(var.existing_endpoint_ids)))
  route_table_ids    = toset([for table in data.aws_route_table.selected : table.id])
}

resource "aws_security_group" "endpoint_clients" {
  name_prefix = "${var.event_name}-endpoint-clients-"
  description = "Outbound access to AWS endpoints only; no player ingress or team-to-team access."
  vpc_id      = data.aws_vpc.selected.id

  lifecycle {
    precondition {
      condition     = var.create_missing_endpoints || length(var.existing_endpoint_ids) == 5
      error_message = "Supply all five existing endpoint IDs, or explicitly enable create_missing_endpoints."
    }

    precondition {
      condition = length(toset([
        for subnet in data.aws_subnet.selected : subnet.availability_zone
      ])) == length(var.private_subnet_ids)
      error_message = "Supply exactly one subnet per availability zone."
    }
  }
}

resource "aws_security_group" "endpoints" {
  count       = length(local.created_interfaces) > 0 ? 1 : 0
  name_prefix = "${var.event_name}-endpoints-"
  description = "HTTPS from CTF endpoint clients."
  vpc_id      = data.aws_vpc.selected.id
}

resource "aws_vpc_security_group_ingress_rule" "endpoint_https" {
  count                        = length(local.created_interfaces) > 0 ? 1 : 0
  security_group_id            = aws_security_group.endpoints[0].id
  referenced_security_group_id = aws_security_group.endpoint_clients.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = local.created_interfaces
  vpc_id              = data.aws_vpc.selected.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.endpoints[0].id]

  tags = { Name = "${var.event_name}-${replace(each.key, ".", "-")}" }
}

resource "aws_vpc_endpoint" "s3" {
  count             = contains(keys(var.existing_endpoint_ids), "s3") ? 0 : 1
  vpc_id            = data.aws_vpc.selected.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.route_table_ids

  # Shared subnet routes must preserve existing workloads' S3 access; IAM still applies.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Principal = "*", Action = "s3:*", Resource = "*"
    }]
  })

  tags = { Name = "${var.event_name}-s3" }
}

data "aws_vpc_endpoint" "existing" {
  for_each = var.existing_endpoint_ids
  id       = each.value

  lifecycle {
    postcondition {
      condition = (
        self.vpc_id == var.vpc_id &&
        self.service_name == "com.amazonaws.${var.aws_region}.${each.key}" &&
        self.state == "available" &&
        (each.key == "s3" ? (
          self.vpc_endpoint_type == "Gateway" &&
          length(setsubtract(local.route_table_ids, self.route_table_ids)) == 0
          ) : (
          self.vpc_endpoint_type == "Interface" && self.private_dns_enabled
        ))
      )
      error_message = "Reused endpoints must be available in this VPC for the named service, with private DNS (Interface) or all selected route tables (S3 Gateway)."
    }
  }
}

locals {
  existing_interface_security_groups = toset(flatten([
    for service, endpoint in data.aws_vpc_endpoint.existing :
    tolist(endpoint.security_group_ids) if service != "s3"
  ]))
}

resource "aws_vpc_security_group_egress_rule" "created_endpoint_https" {
  count                        = length(local.created_interfaces) > 0 ? 1 : 0
  security_group_id            = aws_security_group.endpoint_clients.id
  referenced_security_group_id = aws_security_group.endpoints[0].id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_egress_rule" "existing_endpoint_https" {
  for_each                     = local.existing_interface_security_groups
  security_group_id            = aws_security_group.endpoint_clients.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_egress_rule" "s3_https" {
  security_group_id = aws_security_group.endpoint_clients.id
  prefix_list_id = contains(keys(var.existing_endpoint_ids), "s3") ? (
    data.aws_vpc_endpoint.existing["s3"].prefix_list_id
  ) : aws_vpc_endpoint.s3[0].prefix_list_id
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
}
