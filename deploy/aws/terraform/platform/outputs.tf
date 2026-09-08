output "instance_id" {
  description = "Platform host; manage through SSM, not SSH."
  value       = aws_instance.platform.id
}
output "data_volume_id" {
  description = "Protected stateful data volume. Never remove it to reset a team."
  value       = aws_ebs_volume.data.id
}
output "alb_dns_name" {
  description = "Create your certificate-covered private DNS alias to this target."
  value       = aws_lb.platform.dns_name
}
output "alb_zone_id" {
  description = "Hosted zone ID for the ALB alias target."
  value       = aws_lb.platform.zone_id
}
output "host_security_group_id" {
  description = "Company SSM endpoint security groups must accept HTTPS from this group."
  value       = aws_security_group.host.id
}
output "ssm_endpoint_security_group_ids" {
  description = "Reused company endpoint groups; their ingress is not modified here."
  value       = local.ssm_security_groups
}
output "backup_policy_id" {
  description = "Hourly application-consistent snapshot policy."
  value       = aws_dlm_lifecycle_policy.platform.id
}
output "backup_document_name" {
  description = "SSM pre/post document; use dry-run to check prerequisites."
  value       = aws_ssm_document.backup.name
}
output "backup_role_arn" {
  description = "Company EBS key policies must permit this role to use the supplied key."
  value       = aws_iam_role.backup.arn
}
