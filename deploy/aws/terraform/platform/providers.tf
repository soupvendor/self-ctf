provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]
  default_tags {
    tags = merge(var.tags, {
      Project = "self-ctf", Event = var.event_name, ManagedBy = "Terraform", Component = "platform"
    })
  }
}
