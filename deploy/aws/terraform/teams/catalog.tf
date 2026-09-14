locals {
  catalog = {
    secrets-all-the-way-down = {
      containers = local.containers
      volumes    = ["gitea-data", "gitea-config"]
      endpoints = {
        gitea      = { port = 3000, prefix = "gitea", health_path = "/api/healthz" }
        localstack = { port = 4566, prefix = "aws", health_path = "/_localstack/health" }
      }
      images = [var.images.gitea, var.images.gitea_seed, var.images.localstack]
    }
    nothing-is-ephemeral = {
      containers = {
        localstack = {
          image        = var.images.tfstate_localstack
          essential    = true
          memory       = 2048
          portMappings = [{ containerPort = 4566, protocol = "tcp" }]
          environment = [
            { name = "SERVICES", value = "s3,sts" },
            { name = "DEBUG", value = "0" }
          ]
          secrets = [for name in ["FLAG_STATE_CURRENT", "FLAG_STATE_PRIOR"] : {
            name      = name
            valueFrom = "${var.challenge_secrets["nothing-is-ephemeral"].arn}:${name}::${var.challenge_secrets["nothing-is-ephemeral"].version_id}"
          }]
          healthCheck = {
            command     = ["CMD-SHELL", "test -f /tmp/self-ctf-seeded && awslocal s3api list-object-versions --bucket data-platform-tfstate --prefix env/prod/terraform.tfstate --query 'length(Versions)' --output text | grep -qx 2"]
            interval    = 10
            timeout     = 10
            retries     = 10
            startPeriod = 60
          }
        }
      }
      volumes = []
      endpoints = {
        localstack = { port = 4566, prefix = "tfstate", health_path = "/_localstack/health" }
      }
      images = [var.images.tfstate_localstack]
    }
  }
  instances = {
    for id in var.instance_ids : id => {
      team      = split("/", id)[0]
      challenge = split("/", id)[1]
      name      = replace(id, "/", "-")
    }
  }
}
