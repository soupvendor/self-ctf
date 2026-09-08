resource "aws_ecr_repository" "runtime" {
  for_each             = var.ecr_repository_names
  name                 = "${var.event_name}/${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  encryption_configuration {
    encryption_type = "AES256"
  }

  image_scanning_configuration {
    scan_on_push = true
  }
}
