mock_provider "aws" {
  override_during = plan
  mock_data "aws_vpc" {
    defaults = { enable_dns_support = true, enable_dns_hostnames = true }
  }
  mock_data "aws_subnet" {
    defaults = { vpc_id = "vpc-00000000000000001", availability_zone = "us-east-1a", map_public_ip_on_launch = false }
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
  mock_data "aws_ami" {
    defaults = { id = "ami-00000000000000001", architecture = "x86_64", root_device_type = "ebs", virtualization_type = "hvm" }
  }
  mock_data "aws_ec2_instance_type" {
    defaults = { hypervisor = "nitro", supported_architectures = ["x86_64"] }
  }
  mock_data "aws_ebs_snapshot" {
    defaults = { id = "snap-00000000000000001", state = "completed", encrypted = true, volume_size = 50, tags = { Event = "test-event", "aws:dlm:pre-script" = "SUCCESS" } }
  }
  mock_resource "aws_ebs_volume" {
    defaults = { id = "vol-00000000000000001", arn = "arn:aws:ec2:us-east-1:123456789012:volume/vol-00000000000000001" }
  }
  mock_resource "aws_instance" {
    defaults = { id = "i-00000000000000001", arn = "arn:aws:ec2:us-east-1:123456789012:instance/i-00000000000000001" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/test-role" }
  }
  mock_resource "aws_security_group" {
    defaults = { id = "sg-00000000000000001", ingress = [], egress = [] }
  }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/test/0000000000000001" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/test/0000000000000001" }
  }
  mock_resource "aws_ssm_document" {
    defaults = { arn = "arn:aws:ssm:us-east-1:123456789012:document/test-event-primary-backup" }
  }
  mock_resource "aws_dlm_lifecycle_policy" {
    defaults = {
      policy_details = {
        schedule = {
          create_rule = { scripts = { maximum_retry_count = 0 } }
        }
      }
    }
  }
}

variables {
  aws_region                        = "us-east-1"
  aws_account_id                    = "123456789012"
  event_name                        = "test-event"
  vpc_id                            = "vpc-00000000000000001"
  private_subnet_ids                = ["subnet-00000000000000001", "subnet-00000000000000002"]
  platform_subnet_id                = "subnet-00000000000000001"
  endpoint_client_security_group_id = "sg-00000000000000003"
  ssm_endpoint_ids                  = { ssm = "vpce-00000000000000001", ssmmessages = "vpce-00000000000000002" }
  ami_id                            = "ami-00000000000000001"
  ami_owner_account_id              = "123456789012"
  platform_secret_arn               = "arn:aws:secretsmanager:us-east-1:123456789012:secret:ctf/platform-000001"
  images = {
    ctfd    = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test-event/ctfd@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    mariadb = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test-event/mariadb@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    redis   = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test-event/redis@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
  certificate_arn   = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000001"
  player_ipv4_cidrs = ["10.20.0.0/16"]
  admin_ipv4_cidrs  = ["10.10.10.10/32"]
}

override_data {
  target = data.aws_subnet.selected["subnet-00000000000000002"]
  values = { vpc_id = "vpc-00000000000000001", availability_zone = "us-east-1b", map_public_ip_on_launch = false }
}

override_resource {
  target          = aws_security_group.alb
  override_during = plan
  values          = { id = "sg-00000000000000002" }
}

override_data {
  target = data.aws_vpc_endpoint.ssm["ssm"]
  values = {
    vpc_id              = "vpc-00000000000000001"
    state               = "available"
    service_name        = "com.amazonaws.us-east-1.ssm"
    vpc_endpoint_type   = "Interface"
    private_dns_enabled = true
    security_group_ids  = ["sg-00000000000000004"]
  }
}

override_data {
  target = data.aws_vpc_endpoint.ssm["ssmmessages"]
  values = {
    vpc_id              = "vpc-00000000000000001"
    state               = "available"
    service_name        = "com.amazonaws.us-east-1.ssmmessages"
    vpc_endpoint_type   = "Interface"
    private_dns_enabled = true
    security_group_ids  = ["sg-00000000000000004"]
  }
}

run "secured_platform" {
  command = plan
  assert {
    condition = (
      !aws_instance.platform.associate_public_ip_address &&
      aws_instance.platform.disable_api_termination &&
      aws_instance.platform.user_data_replace_on_change &&
      one(aws_instance.platform.metadata_options).http_tokens == "required" &&
      one(aws_instance.platform.metadata_options).http_put_response_hop_limit == 1 &&
      one(aws_instance.platform.root_block_device).encrypted &&
      aws_ebs_volume.data.encrypted &&
      aws_ebs_volume.data.type == "gp3" &&
      aws_ebs_volume.data.availability_zone == "us-east-1a" &&
      !aws_volume_attachment.data.force_detach &&
      aws_volume_attachment.data.stop_instance_before_detaching
    )
    error_message = "Platform storage and credentials must stay private and protected."
  }
  assert {
    condition = (
      aws_lb.platform.internal &&
      aws_lb.platform.enable_deletion_protection &&
      aws_lb.platform.drop_invalid_header_fields &&
      aws_lb_listener.https.protocol == "HTTPS" &&
      aws_lb_listener.https.port == 443 &&
      aws_lb_listener.https.certificate_arn == var.certificate_arn &&
      toset(keys(aws_vpc_security_group_ingress_rule.https)) == var.admin_ipv4_cidrs &&
      aws_vpc_security_group_ingress_rule.ctfd.referenced_security_group_id == aws_security_group.alb.id &&
      aws_vpc_security_group_ingress_rule.ctfd.from_port == 8000 &&
      aws_vpc_security_group_ingress_rule.ctfd.to_port == 8000 &&
      aws_vpc_security_group_egress_rule.alb_to_host.referenced_security_group_id == aws_security_group.host.id &&
      length(aws_security_group.host.ingress) == 0 &&
      length(aws_security_group.host.egress) == 0 &&
      one(values(aws_vpc_security_group_egress_rule.ssm)).to_port == 443 &&
      one(values(aws_vpc_security_group_egress_rule.ssm)).referenced_security_group_id == "sg-00000000000000004"
    )
    error_message = "Only operators may reach initial setup; EC2 must accept application traffic only from the ALB."
  }
  assert {
    condition = (
      jsondecode(aws_iam_role_policy.platform.policy).Statement[2].Resource == var.platform_secret_arn &&
      length(jsondecode(aws_iam_role_policy.platform.policy).Statement[1].Resource) == 3 &&
      !contains(jsondecode(aws_iam_role_policy.platform.policy).Statement[1].Resource, "*") &&
      length(jsondecode(aws_iam_role_policy.platform.policy).Statement) == 3
    )
    error_message = "The runtime policy must read one platform secret and only the three supplied image repositories."
  }
  assert {
    condition = (
      strcontains(local.unit_files["docker.service.d/self-ctf.conf"], "RequiresMountsFor=/srv/self-ctf") &&
      strcontains(local.unit_files["self-ctf.service"], "RequiresMountsFor=/srv/self-ctf") &&
      strcontains(local.unit_files["self-ctf-storage.service"], "Before=srv-self\\x2dctf.mount") &&
      contains(keys(local.unit_files), "srv-self\\x2dctf.mount") &&
      local.device_path == "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol00000000000000001" &&
      local.host_environment.INITIALIZE_NEW_VOLUME == "true" &&
      length(base64gzip(local.cloud_config)) <= 21840
    )
    error_message = "Docker startup must require the exact data disk, and EC2 user data must fit its limit."
  }
}

run "consistent_backups" {
  command = plan
  assert {
    condition = (
      aws_dlm_lifecycle_policy.platform.state == "ENABLED" &&
      one(aws_dlm_lifecycle_policy.platform.policy_details).resource_types == tolist(["INSTANCE"]) &&
      one(one(aws_dlm_lifecycle_policy.platform.policy_details).parameters).exclude_boot_volume &&
      one(one(one(aws_dlm_lifecycle_policy.platform.policy_details).schedule).create_rule).interval == 1 &&
      !one(one(one(one(aws_dlm_lifecycle_policy.platform.policy_details).schedule).create_rule).scripts).execute_operation_on_script_failure &&
      one(one(one(one(aws_dlm_lifecycle_policy.platform.policy_details).schedule).create_rule).scripts).maximum_retry_count == 0 &&
      toset(one(one(one(one(aws_dlm_lifecycle_policy.platform.policy_details).schedule).create_rule).scripts).stages) == toset(["PRE", "POST"]) &&
      one(one(one(aws_dlm_lifecycle_policy.platform.policy_details).schedule).retain_rule).count == 168 &&
      jsondecode(aws_iam_role_policy.backup.policy).Statement[3].Condition.StringEquals["ec2:ResourceTag/SelfCtfBackup"] == "test-event-primary" &&
      jsondecode(aws_iam_role_policy.backup.policy).Statement[6].Resource == "arn:aws:events:us-east-1:123456789012:rule/AwsDataLifecycleRule.managed-cwe.*" &&
      length(aws_iam_role_policy.backup_kms) == 0 &&
      length(aws_cloudwatch_metric_alarm.backup_failure) == 4
    )
    error_message = "Backups must quiesce both sides of hourly data-only snapshots, never silently downgrade consistency, and monitor failures."
  }
}

run "custom_ebs_key" {
  command = plan
  variables { ebs_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001" }
  assert {
    condition = (
      aws_ebs_volume.data.kms_key_id == var.ebs_kms_key_arn &&
      one(aws_instance.platform.root_block_device).kms_key_id == var.ebs_kms_key_arn &&
      alltrue([for statement in jsondecode(aws_iam_role_policy.backup_kms[0].policy).Statement :
        statement.Resource == var.ebs_kms_key_arn &&
        statement.Condition.StringEquals["kms:ViaService"] == "ec2.us-east-1.amazonaws.com" &&
        statement.Condition.StringEquals["kms:CallerAccount"] == var.aws_account_id
      ]) &&
      jsondecode(aws_iam_role_policy.backup_kms[0].policy).Statement[1].Condition.Bool["kms:GrantIsForAWSResource"]
    )
    error_message = "Backup key use must be constrained to this EBS key, account, and EC2 service; grants must be AWS-managed."
  }
}

run "open_players_explicitly" {
  command = plan
  variables { enable_player_access = true }
  assert {
    condition     = toset(keys(aws_vpc_security_group_ingress_rule.https)) == setunion(var.player_ipv4_cidrs, var.admin_ipv4_cidrs)
    error_message = "Enabling player access must add only the configured player networks."
  }
}

run "restore_separate_platform" {
  command = plan
  variables {
    restore_snapshot_id = "snap-00000000000000001"
    platform_name       = "recovery"
    backup_enabled      = false
  }
  assert {
    condition = (
      aws_ebs_volume.data.snapshot_id == "snap-00000000000000001" &&
      local.host_environment.INITIALIZE_NEW_VOLUME == "false" &&
      one(aws_dlm_lifecycle_policy.platform.policy_details).target_tags.SelfCtfBackup == "test-event-recovery" &&
      aws_dlm_lifecycle_policy.platform.state == "DISABLED" &&
      aws_iam_role.platform.name == "test-event-recovery-host"
    )
    error_message = "A recovery must use its snapshot without formatting or sharing the original backup selector."
  }
}

run "custom_secret_key" {
  command = plan
  variables { secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001" }
  assert {
    condition = (
      jsondecode(aws_iam_role_policy.platform.policy).Statement[3].Resource == var.secret_kms_key_arn &&
      jsondecode(aws_iam_role_policy.platform.policy).Statement[3].Condition.StringEquals["kms:EncryptionContext:SecretARN"] == var.platform_secret_arn
    )
    error_message = "Customer-key decrypt permission must be constrained to the platform secret."
  }
}

run "reject_unrestricted_players" {
  command = plan
  variables { player_ipv4_cidrs = ["0.0.0.0/0"] }
  expect_failures = [var.player_ipv4_cidrs]
}

run "reject_unrestricted_admin" {
  command = plan
  variables { admin_ipv4_cidrs = ["0.0.0.0/0"] }
  expect_failures = [var.admin_ipv4_cidrs]
}

run "reject_wrong_platform_subnet" {
  command = plan
  variables { platform_subnet_id = "subnet-00000000000000099" }
  expect_failures = [var.platform_subnet_id]
}

run "reject_bad_retention" {
  command = plan
  variables { backup_retention_count = 0 }
  expect_failures = [var.backup_retention_count]
}

run "reject_small_volume" {
  command = plan
  variables { data_volume_size_gib = 10 }
  expect_failures = [var.data_volume_size_gib]
}

run "reject_public_subnet" {
  command = plan
  override_data {
    target = data.aws_subnet.selected["subnet-00000000000000001"]
    values = { vpc_id = "vpc-00000000000000001", availability_zone = "us-east-1a", map_public_ip_on_launch = true }
  }
  expect_failures = [data.aws_subnet.selected["subnet-00000000000000001"]]
}

run "reject_wrong_vpc" {
  command = plan
  override_data {
    target = data.aws_security_group.endpoint_clients
    values = { vpc_id = "vpc-00000000000000099" }
  }
  expect_failures = [data.aws_security_group.endpoint_clients]
}

run "reject_old_hypervisor" {
  command = plan
  override_data {
    target = data.aws_ec2_instance_type.platform
    values = { hypervisor = "xen", supported_architectures = ["x86_64"] }
  }
  expect_failures = [data.aws_ec2_instance_type.platform]
}

run "reject_wrong_ami_arch" {
  command = plan
  override_data {
    target = data.aws_ami.platform
    values = { architecture = "arm64", root_device_type = "ebs", virtualization_type = "hvm" }
  }
  expect_failures = [data.aws_ami.platform]
}

run "reject_public_route" {
  command = plan
  override_data {
    target = data.aws_route_table.selected["subnet-00000000000000001"]
    values = { routes = [{ gateway_id = "igw-00000000000000001" }] }
  }
  expect_failures = [data.aws_route_table.selected["subnet-00000000000000001"]]
}

run "reject_wrong_snapshot" {
  command = plan
  variables { restore_snapshot_id = "snap-00000000000000001" }
  override_data {
    target = data.aws_ebs_snapshot.restore[0]
    values = { state = "completed", encrypted = true, volume_size = 50, tags = { Event = "different-event", "aws:dlm:pre-script" = "SUCCESS" } }
  }
  expect_failures = [data.aws_ebs_snapshot.restore[0]]
}

run "reject_incomplete_snapshot" {
  command = plan
  variables { restore_snapshot_id = "snap-00000000000000001" }
  override_data {
    target = data.aws_ebs_snapshot.restore[0]
    values = { state = "pending", encrypted = true, volume_size = 50, tags = { Event = "test-event", "aws:dlm:pre-script" = "SUCCESS" } }
  }
  expect_failures = [data.aws_ebs_snapshot.restore[0]]
}

run "reject_undersized_restore" {
  command = plan
  variables { restore_snapshot_id = "snap-00000000000000001" }
  override_data {
    target = data.aws_ebs_snapshot.restore[0]
    values = { state = "completed", encrypted = true, volume_size = 100, tags = { Event = "test-event", "aws:dlm:pre-script" = "SUCCESS" } }
  }
  expect_failures = [data.aws_ebs_snapshot.restore[0]]
}

run "reject_snapshot_without_successful_quiesce" {
  command = plan
  variables { restore_snapshot_id = "snap-00000000000000001" }
  override_data {
    target = data.aws_ebs_snapshot.restore[0]
    values = { state = "completed", encrypted = true, volume_size = 50, tags = { Event = "test-event", "aws:dlm:pre-script" = "FAILED" } }
  }
  expect_failures = [data.aws_ebs_snapshot.restore[0]]
}
