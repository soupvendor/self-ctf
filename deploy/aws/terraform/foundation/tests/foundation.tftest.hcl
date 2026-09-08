mock_provider "aws" {
  override_during = plan

  mock_data "aws_vpc" {
    defaults = {
      enable_dns_support   = true
      enable_dns_hostnames = true
    }
  }

  mock_data "aws_subnet" {
    defaults = {
      vpc_id                  = "vpc-00000000000000001"
      availability_zone       = "us-east-1a"
      map_public_ip_on_launch = false
    }
  }

  mock_data "aws_route_tables" {
    defaults = { ids = ["rtb-00000000000000001"] }
  }

  mock_data "aws_route_table" {
    defaults = {
      id     = "rtb-00000000000000001"
      routes = [{ gateway_id = null, nat_gateway_id = "nat-00000000000000001" }]
    }
  }

  mock_resource "aws_security_group" {
    defaults = {
      id      = "sg-00000000000000001"
      ingress = []
      egress  = []
    }
  }

  mock_resource "aws_vpc_endpoint" {
    defaults = {
      id             = "vpce-00000000000000001"
      prefix_list_id = "pl-00000001"
    }
  }
}

variables {
  aws_region               = "us-east-1"
  aws_account_id           = "123456789012"
  event_name               = "test-event"
  vpc_id                   = "vpc-00000000000000001"
  private_subnet_ids       = ["subnet-00000000000000001", "subnet-00000000000000002"]
  create_missing_endpoints = true
}

override_data {
  target = data.aws_subnet.selected["subnet-00000000000000002"]
  values = {
    vpc_id                  = "vpc-00000000000000001"
    availability_zone       = "us-east-1b"
    map_public_ip_on_launch = false
  }
}

override_resource {
  target          = aws_security_group.endpoints
  override_during = plan
  values          = { id = "sg-00000000000000002" }
}

run "create_foundation" {
  command = plan

  assert {
    condition = (
      length(aws_vpc_endpoint.interface) == 4 &&
      alltrue([for endpoint in aws_vpc_endpoint.interface :
        endpoint.private_dns_enabled && endpoint.vpc_endpoint_type == "Interface" &&
        endpoint.subnet_ids == var.private_subnet_ids
      ]) &&
      aws_vpc_endpoint.s3[0].vpc_endpoint_type == "Gateway" &&
      aws_vpc_endpoint.s3[0].route_table_ids == toset(["rtb-00000000000000001"])
    )
    error_message = "Private image pulls, logging, and secret injection require four interfaces and S3 routes."
  }

  assert {
    condition = (
      length(aws_security_group.endpoint_clients.ingress) == 0 &&
      length(aws_security_group.endpoint_clients.egress) == 0 &&
      aws_vpc_security_group_ingress_rule.endpoint_https[0].referenced_security_group_id == aws_security_group.endpoint_clients.id &&
      aws_vpc_security_group_ingress_rule.endpoint_https[0].from_port == 443 &&
      aws_vpc_security_group_ingress_rule.endpoint_https[0].to_port == 443 &&
      aws_vpc_security_group_ingress_rule.endpoint_https[0].ip_protocol == "tcp" &&
      aws_vpc_security_group_egress_rule.created_endpoint_https[0].referenced_security_group_id == aws_security_group.endpoints[0].id &&
      aws_vpc_security_group_egress_rule.created_endpoint_https[0].from_port == 443 &&
      aws_vpc_security_group_egress_rule.created_endpoint_https[0].to_port == 443 &&
      aws_vpc_security_group_egress_rule.created_endpoint_https[0].ip_protocol == "tcp" &&
      aws_vpc_security_group_egress_rule.s3_https.prefix_list_id == aws_vpc_endpoint.s3[0].prefix_list_id &&
      aws_vpc_security_group_egress_rule.s3_https.from_port == 443 &&
      aws_vpc_security_group_egress_rule.s3_https.to_port == 443 &&
      aws_vpc_security_group_egress_rule.s3_https.ip_protocol == "tcp"
    )
    error_message = "Endpoint clients must have only targeted HTTPS egress and no player ingress."
  }

  assert {
    condition = (
      length(aws_ecr_repository.runtime) == 6 &&
      alltrue([for name, repository in aws_ecr_repository.runtime :
        repository.name == "test-event/${name}" &&
        repository.image_tag_mutability == "IMMUTABLE" &&
        !repository.force_delete &&
        one(repository.encryption_configuration).encryption_type == "AES256" &&
        one(repository.image_scanning_configuration).scan_on_push
      ]) &&
      length(output.ecr_repositories) == 6 &&
      length(output.endpoint_ids) == 5
    )
    error_message = "Runtime repositories must be event-scoped, encrypted, scanned, immutable, and protected from forced deletion."
  }
}

run "custom_repository_names" {
  command = plan
  variables {
    ecr_repository_names = ["custom-runtime"]
  }

  assert {
    condition = (
      length(aws_ecr_repository.runtime) == 1 &&
      aws_ecr_repository.runtime["custom-runtime"].name == "test-event/custom-runtime"
    )
    error_message = "Operators must be able to select runtime repositories without editing the root module."
  }
}

run "use_implicit_main_route_table" {
  command = plan

  override_data {
    target = data.aws_route_tables.explicit
    values = { ids = [] }
  }

  override_data {
    target = data.aws_route_table.main
    values = { id = "rtb-00000000000000099" }
  }

  assert {
    condition = alltrue([
      for table in data.aws_route_table.selected :
      table.route_table_id == "rtb-00000000000000099"
    ])
    error_message = "Subnets without explicit associations must use the VPC's main route table."
  }
}

run "reuse_company_endpoints" {
  command = plan
  variables {
    create_missing_endpoints = false
    existing_endpoint_ids = {
      "ecr.api"        = "vpce-00000000000000001"
      "ecr.dkr"        = "vpce-00000000000000002"
      "logs"           = "vpce-00000000000000003"
      "secretsmanager" = "vpce-00000000000000004"
      "s3"             = "vpce-00000000000000005"
    }
  }

  override_data {
    target = data.aws_vpc_endpoint.existing["ecr.api"]
    values = {
      vpc_id              = "vpc-00000000000000001"
      service_name        = "com.amazonaws.us-east-1.ecr.api"
      state               = "available"
      vpc_endpoint_type   = "Interface"
      private_dns_enabled = true
      route_table_ids     = ["rtb-00000000000000001"]
      security_group_ids  = ["sg-00000000000000099"]
      prefix_list_id      = "pl-00000099"

    }
  }


  override_data {
    target = data.aws_vpc_endpoint.existing["ecr.dkr"]
    values = {
      vpc_id              = "vpc-00000000000000001"
      service_name        = "com.amazonaws.us-east-1.ecr.dkr"
      state               = "available"
      vpc_endpoint_type   = "Interface"
      private_dns_enabled = true
      route_table_ids     = ["rtb-00000000000000001"]
      security_group_ids  = ["sg-00000000000000099"]
      prefix_list_id      = "pl-00000099"

    }
  }


  override_data {
    target = data.aws_vpc_endpoint.existing["logs"]
    values = {
      vpc_id              = "vpc-00000000000000001"
      service_name        = "com.amazonaws.us-east-1.logs"
      state               = "available"
      vpc_endpoint_type   = "Interface"
      private_dns_enabled = true
      route_table_ids     = ["rtb-00000000000000001"]
      security_group_ids  = ["sg-00000000000000099"]
      prefix_list_id      = "pl-00000099"

    }
  }


  override_data {
    target = data.aws_vpc_endpoint.existing["secretsmanager"]
    values = {
      vpc_id              = "vpc-00000000000000001"
      service_name        = "com.amazonaws.us-east-1.secretsmanager"
      state               = "available"
      vpc_endpoint_type   = "Interface"
      private_dns_enabled = true
      route_table_ids     = ["rtb-00000000000000001"]
      security_group_ids  = ["sg-00000000000000099"]
      prefix_list_id      = "pl-00000099"

    }
  }


  override_data {
    target = data.aws_vpc_endpoint.existing["s3"]
    values = {
      vpc_id              = "vpc-00000000000000001"
      service_name        = "com.amazonaws.us-east-1.s3"
      state               = "available"
      vpc_endpoint_type   = "Gateway"
      private_dns_enabled = false
      route_table_ids     = ["rtb-00000000000000001"]
      security_group_ids  = []
      prefix_list_id      = "pl-00000099"

    }
  }

  assert {
    condition = (
      length(aws_vpc_endpoint.interface) == 0 &&
      length(aws_vpc_endpoint.s3) == 0 &&
      length(aws_security_group.endpoints) == 0 &&
      length(aws_vpc_security_group_ingress_rule.endpoint_https) == 0 &&
      length(aws_vpc_security_group_egress_rule.created_endpoint_https) == 0 &&
      length(aws_vpc_security_group_egress_rule.existing_endpoint_https) == 1 &&
      aws_vpc_security_group_egress_rule.existing_endpoint_https["sg-00000000000000099"].referenced_security_group_id == "sg-00000000000000099" &&
      aws_vpc_security_group_egress_rule.s3_https.prefix_list_id == "pl-00000099" &&
      output.existing_endpoint_security_group_ids == toset(["sg-00000000000000099"]) &&
      length(output.endpoint_ids) == 5
    )
    error_message = "Reusing company endpoints must not recreate them, change routes, or own their ingress rules."
  }
}

run "reuse_one_create_missing" {
  command = plan
  variables {
    existing_endpoint_ids = { logs = "vpce-00000000000000003" }
  }

  override_data {
    target = data.aws_vpc_endpoint.existing["logs"]
    values = {
      vpc_id              = "vpc-00000000000000001"
      service_name        = "com.amazonaws.us-east-1.logs"
      state               = "available"
      vpc_endpoint_type   = "Interface"
      private_dns_enabled = true
      route_table_ids     = ["rtb-00000000000000001"]
      security_group_ids  = ["sg-00000000000000099"]
      prefix_list_id      = "pl-00000099"

    }
  }

  assert {
    condition = (
      length(aws_vpc_endpoint.interface) == 3 &&
      !contains(keys(aws_vpc_endpoint.interface), "logs") &&
      length(aws_vpc_endpoint.s3) == 1 &&
      length(aws_vpc_security_group_egress_rule.existing_endpoint_https) == 1
    )
    error_message = "Partial reuse must create only the missing endpoints."
  }
}

run "require_endpoint_creation_opt_in" {
  command = plan
  variables { create_missing_endpoints = false }
  expect_failures = [aws_security_group.endpoint_clients]
}

run "reject_invalid_account" {
  command = plan
  variables { aws_account_id = "1234" }
  expect_failures = [var.aws_account_id]
}

run "reject_invalid_event" {
  command = plan
  variables { event_name = "Invalid Event" }
  expect_failures = [var.event_name]
}

run "reject_single_subnet" {
  command = plan
  variables { private_subnet_ids = ["subnet-00000000000000002"] }
  expect_failures = [var.private_subnet_ids]
}

run "reject_unknown_service" {
  command = plan
  variables { existing_endpoint_ids = { typo = "vpce-00000000000000001" } }
  expect_failures = [var.existing_endpoint_ids]
}

run "reject_invalid_repository" {
  command = plan
  variables { ecr_repository_names = ["INVALID"] }
  expect_failures = [var.ecr_repository_names]
}

run "reject_missing_dns" {
  command = plan
  override_data {
    target = data.aws_vpc.selected
    values = { enable_dns_support = false, enable_dns_hostnames = true }
  }
  expect_failures = [data.aws_vpc.selected]
}

run "reject_public_subnet" {
  command = plan
  override_data {
    target = data.aws_subnet.selected["subnet-00000000000000001"]
    values = { vpc_id = "vpc-00000000000000001", map_public_ip_on_launch = true, availability_zone = "us-east-1a" }
  }
  expect_failures = [data.aws_subnet.selected["subnet-00000000000000001"]]
}

run "reject_wrong_vpc" {
  command = plan
  override_data {
    target = data.aws_subnet.selected["subnet-00000000000000001"]
    values = { vpc_id = "vpc-00000000000000099", map_public_ip_on_launch = false, availability_zone = "us-east-1a" }
  }
  expect_failures = [data.aws_subnet.selected["subnet-00000000000000001"]]
}

run "reject_duplicate_az" {
  command = plan
  override_data {
    target = data.aws_subnet.selected["subnet-00000000000000001"]
    values = { vpc_id = "vpc-00000000000000001", map_public_ip_on_launch = false, availability_zone = "us-east-1b" }
  }
  expect_failures = [aws_security_group.endpoint_clients]
}

run "reject_internet_gateway" {
  command = plan
  override_data {
    target = data.aws_route_table.selected["subnet-00000000000000001"]
    values = { routes = [{ gateway_id = "igw-00000000000000001" }] }
  }
  expect_failures = [data.aws_route_table.selected["subnet-00000000000000001"]]
}

run "reject_wrong_endpoint_vpc" {
  command = plan
  variables { existing_endpoint_ids = { "logs" = "vpce-00000000000000001" } }

  override_data {
    target = data.aws_vpc_endpoint.existing["logs"]
    values = {
      vpc_id              = "vpc-00000000000000099"
      service_name        = "com.amazonaws.us-east-1.logs"
      state               = "available"
      vpc_endpoint_type   = "Interface"
      private_dns_enabled = true
      route_table_ids     = ["rtb-00000000000000001"]
      security_group_ids  = ["sg-00000000000000099"]
      prefix_list_id      = "pl-00000099"

    }
  }

  expect_failures = [data.aws_vpc_endpoint.existing["logs"]]
}

run "reject_wrong_endpoint_service" {
  command = plan
  variables { existing_endpoint_ids = { "logs" = "vpce-00000000000000001" } }

  override_data {
    target = data.aws_vpc_endpoint.existing["logs"]
    values = {
      vpc_id              = "vpc-00000000000000001"
      service_name        = "com.amazonaws.us-east-1.ec2"
      state               = "available"
      vpc_endpoint_type   = "Interface"
      private_dns_enabled = true
      route_table_ids     = ["rtb-00000000000000001"]
      security_group_ids  = ["sg-00000000000000099"]
      prefix_list_id      = "pl-00000099"

    }
  }

  expect_failures = [data.aws_vpc_endpoint.existing["logs"]]
}

run "reject_endpoint_without_private_dns" {
  command = plan
  variables { existing_endpoint_ids = { "logs" = "vpce-00000000000000001" } }

  override_data {
    target = data.aws_vpc_endpoint.existing["logs"]
    values = {
      vpc_id              = "vpc-00000000000000001"
      service_name        = "com.amazonaws.us-east-1.logs"
      state               = "available"
      vpc_endpoint_type   = "Interface"
      private_dns_enabled = false
      route_table_ids     = ["rtb-00000000000000001"]
      security_group_ids  = ["sg-00000000000000099"]
      prefix_list_id      = "pl-00000099"

    }
  }

  expect_failures = [data.aws_vpc_endpoint.existing["logs"]]
}

run "reject_unavailable_endpoint" {
  command = plan
  variables { existing_endpoint_ids = { "logs" = "vpce-00000000000000001" } }

  override_data {
    target = data.aws_vpc_endpoint.existing["logs"]
    values = {
      vpc_id              = "vpc-00000000000000001"
      service_name        = "com.amazonaws.us-east-1.logs"
      state               = "pending"
      vpc_endpoint_type   = "Interface"
      private_dns_enabled = true
      route_table_ids     = ["rtb-00000000000000001"]
      security_group_ids  = ["sg-00000000000000099"]
      prefix_list_id      = "pl-00000099"

    }
  }

  expect_failures = [data.aws_vpc_endpoint.existing["logs"]]
}

run "reject_s3_missing_routes" {
  command = plan
  variables { existing_endpoint_ids = { "s3" = "vpce-00000000000000001" } }

  override_data {
    target = data.aws_vpc_endpoint.existing["s3"]
    values = {
      vpc_id              = "vpc-00000000000000001"
      service_name        = "com.amazonaws.us-east-1.s3"
      state               = "available"
      vpc_endpoint_type   = "Gateway"
      private_dns_enabled = false
      route_table_ids     = []
      security_group_ids  = []
      prefix_list_id      = "pl-00000099"

    }
  }

  expect_failures = [data.aws_vpc_endpoint.existing["s3"]]
}

run "reject_s3_interface" {
  command = plan
  variables { existing_endpoint_ids = { "s3" = "vpce-00000000000000001" } }

  override_data {
    target = data.aws_vpc_endpoint.existing["s3"]
    values = {
      vpc_id              = "vpc-00000000000000001"
      service_name        = "com.amazonaws.us-east-1.s3"
      state               = "available"
      vpc_endpoint_type   = "Interface"
      private_dns_enabled = false
      route_table_ids     = ["rtb-00000000000000001"]
      security_group_ids  = []
      prefix_list_id      = "pl-00000099"

    }
  }

  expect_failures = [data.aws_vpc_endpoint.existing["s3"]]
}
