data "aws_ami" "platform" {
  owners = [var.ami_owner_account_id]
  filter {
    name   = "image-id"
    values = [var.ami_id]
  }
  lifecycle {
    postcondition {
      condition     = self.architecture == "x86_64" && self.root_device_type == "ebs" && self.virtualization_type == "hvm"
      error_message = "Use the supplied x86_64 HVM EBS-backed platform AMI."
    }
  }
}

data "aws_ec2_instance_type" "platform" {
  instance_type = var.instance_type
  lifecycle {
    postcondition {
      condition     = self.hypervisor == "nitro" && contains(self.supported_architectures, "x86_64")
      error_message = "The platform AMI and stable EBS device path require Nitro x86_64."
    }
  }
}

data "aws_ebs_snapshot" "restore" {
  count  = var.restore_snapshot_id == null ? 0 : 1
  owners = [var.aws_account_id]
  filter {
    name   = "snapshot-id"
    values = [var.restore_snapshot_id]
  }
  lifecycle {
    postcondition {
      condition = (
        self.state == "completed" && self.encrypted && self.volume_size <= var.data_volume_size_gib &&
        lookup(self.tags, "Event", "") == var.event_name &&
        lookup(self.tags, "aws:dlm:pre-script", "") == "SUCCESS"
      )
      error_message = "Restore a completed, encrypted snapshot with a successful pre-script for this event into a sufficiently large disk."
    }
  }
}

resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.selected[var.platform_subnet_id].availability_zone
  type              = "gp3"
  size              = var.data_volume_size_gib
  encrypted         = true
  kms_key_id        = var.ebs_kms_key_arn
  snapshot_id       = var.restore_snapshot_id == null ? null : data.aws_ebs_snapshot.restore[0].id
  tags              = { Name = "${local.platform_name}-data" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_instance" "platform" {
  ami                         = data.aws_ami.platform.id
  instance_type               = data.aws_ec2_instance_type.platform.instance_type
  subnet_id                   = var.platform_subnet_id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.host.id, data.aws_security_group.endpoint_clients.id]
  iam_instance_profile        = aws_iam_instance_profile.platform.name
  disable_api_termination     = var.protect_instance
  user_data_base64            = base64gzip(local.cloud_config)
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_protocol_ipv6          = "disabled"
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gib
    encrypted             = true
    kms_key_id            = var.ebs_kms_key_arn
    delete_on_termination = true
  }

  tags = {
    Name          = local.platform_name
    SelfCtfBackup = local.platform_name
  }

  lifecycle {
    precondition {
      condition     = length(base64gzip(local.cloud_config)) <= 21840
      error_message = "Compressed cloud-init exceeds EC2's 16 KiB user-data limit."
    }
  }

  depends_on = [aws_iam_role_policy.platform, aws_iam_role_policy_attachment.ssm]
}

resource "aws_volume_attachment" "data" {
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.data.id
  instance_id                    = aws_instance.platform.id
  force_detach                   = false
  stop_instance_before_detaching = true
}
