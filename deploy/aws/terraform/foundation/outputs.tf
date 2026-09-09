output "vpc_id" {
  description = "Existing VPC for the platform and team stacks."
  value       = data.aws_vpc.selected.id
}

output "deployment" {
  description = "Identity guard for operator commands."
  value       = { account_id = var.aws_account_id, region = var.aws_region, event_name = var.event_name }
}

output "private_subnet_ids" {
  description = "Validated private subnets for future compute modules."
  value       = [for subnet in data.aws_subnet.selected : subnet.id]
}

output "endpoint_client_security_group_id" {
  description = "Attach alongside a workload-specific ingress group; does not grant player access."
  value       = aws_security_group.endpoint_clients.id
}

output "existing_endpoint_security_group_ids" {
  description = "Company-managed endpoint groups must permit HTTPS from the CTF endpoint client group."
  value       = local.existing_interface_security_groups
}

output "endpoint_ids" {
  description = "Created and reused endpoint IDs keyed by AWS service."
  value = merge(
    { for service, endpoint in aws_vpc_endpoint.interface : service => endpoint.id },
    { for endpoint in aws_vpc_endpoint.s3 : "s3" => endpoint.id },
    { for service, endpoint in data.aws_vpc_endpoint.existing : service => endpoint.id }
  )
}

output "ecr_repositories" {
  description = "Publish flag-free runtime images here, then pass immutable digests to compute modules."
  value = {
    for name, repository in aws_ecr_repository.runtime :
    name => { arn = repository.arn, url = repository.repository_url }
  }
}
