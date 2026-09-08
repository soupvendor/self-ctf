locals {
  device_path = "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${replace(aws_ebs_volume.data.id, "-", "")}"
  device_unit = "${replace(replace(trimprefix(local.device_path, "/"), "-", "\\x2d"), "/", "-")}.device"

  host_environment = {
    AWS_REGION            = var.aws_region
    AWS_DEFAULT_REGION    = var.aws_region
    AWS_RETRY_MODE        = "standard"
    PLATFORM_SECRET_ARN   = var.platform_secret_arn
    ECR_REGISTRY          = local.registry
    CTFD_IMAGE            = var.images.ctfd
    DOCKER_CONFIG         = "/run/self-ctf/docker"
    SELF_CTF_RUN_DIR      = "/run/self-ctf"
    SELF_CTF_PROJECT_NAME = "self-ctf-platform"
    SELF_CTF_CONFIG_DIR   = "/etc/self-ctf"
    SELF_CTF_LIB_DIR      = "/usr/local/lib/self-ctf"
    PLATFORM_DATA_DIR     = "/srv/self-ctf"
    DATA_DEVICE           = local.device_path
    INITIALIZE_NEW_VOLUME = tostring(var.restore_snapshot_id == null)
  }
  compose_environment = {
    CTFD_IMAGE        = var.images.ctfd
    MARIADB_IMAGE     = var.images.mariadb
    REDIS_IMAGE       = var.images.redis
    PLATFORM_DATA_DIR = "/srv/self-ctf"
    CTFD_CONFIG_FILE  = "/run/self-ctf/ctfd.ini"
    CTFD_PORT         = "8000"
  }

  unit_files = {
    "self-ctf-storage.service"       = <<-UNIT
      [Unit]
      Description=Validate or initialize the CTF data volume
      Requires=${local.device_unit}
      After=${local.device_unit}
      Before=srv-self\x2dctf.mount

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      EnvironmentFile=/etc/self-ctf/host.env
      ExecStart=/usr/local/lib/self-ctf/storage.sh
      TimeoutStartSec=180
    UNIT
    "srv-self\\x2dctf.mount"         = <<-UNIT
      [Unit]
      Description=Persistent CTF platform data
      Requires=self-ctf-storage.service
      After=self-ctf-storage.service
      Before=docker.service

      [Mount]
      What=${local.device_path}
      Where=/srv/self-ctf
      Type=ext4
      Options=defaults,nodev,nosuid
      TimeoutSec=180

      [Install]
      WantedBy=multi-user.target
    UNIT
    "docker.service.d/self-ctf.conf" = <<-UNIT
      [Unit]
      RequiresMountsFor=/srv/self-ctf
    UNIT
    "self-ctf.service"               = <<-UNIT
      [Unit]
      Description=Stateful CTFd platform
      Requires=docker.service
      RequiresMountsFor=/srv/self-ctf
      After=docker.service network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      EnvironmentFile=/etc/self-ctf/host.env
      RuntimeDirectory=self-ctf
      RuntimeDirectoryMode=0700
      ExecStart=/usr/local/lib/self-ctf/start.sh
      ExecStop=/usr/local/lib/self-ctf/stop.sh
      TimeoutStartSec=300
      TimeoutStopSec=90

      [Install]
      WantedBy=multi-user.target
    UNIT
  }

  cloud_config = "#cloud-config\n${yamlencode({
    write_files = concat([
      {
        path     = "/etc/self-ctf/compose.yaml", permissions = "0644"
        encoding = "b64", content = filebase64("${path.module}/../../../../compose.yaml")
      },
      {
        path     = "/etc/self-ctf/compose.aws.yaml", permissions = "0644"
        encoding = "b64", content = filebase64("${path.module}/../../platform/compose.aws.yaml")
      },
      {
        path    = "/etc/self-ctf/host.env", permissions = "0600"
        content = join("\n", [for key, value in local.host_environment : "${key}=${jsonencode(value)}"])
      },
      {
        path    = "/etc/self-ctf/images.env", permissions = "0644"
        content = join("\n", [for key, value in local.compose_environment : "${key}=${value}"])
      }
      ], [
      for name in ["storage.sh", "start.sh", "stop.sh", "compose.sh", "backup.sh", "configure_ctfd.py"] : {
        path     = "/usr/local/lib/self-ctf/${name}", permissions = endswith(name, ".sh") ? "0755" : "0644"
        encoding = "b64", content = filebase64("${path.module}/../../platform/${name}")
      }
      ], [
      for name, content in local.unit_files : {
        path = "/etc/systemd/system/${name}", permissions = "0644", content = content
      }
    ])
    runcmd = [
      ["systemctl", "stop", "docker.service", "docker.socket"],
      ["systemctl", "daemon-reload"],
      ["systemctl", "enable", "--now", "self-ctf.service"]
    ]
  })}"
}
