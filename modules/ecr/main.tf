locals {
  repos = ["${var.prefix}-frontend", "${var.prefix}-backend"]
}

resource "aws_ecr_repository" "this" {
  for_each = toset(local.repos)

  name                 = each.key
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last ${var.image_retention_count} images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.image_retention_count
      }
      action = { type = "expire" }
    }]
  })
}

# Cross-region replication — secondary EKS can pull images during DR failover.
resource "aws_ecr_replication_configuration" "secondary" {
  count = var.secondary_region != "" ? 1 : 0

  replication_configuration {
    rule {
      destination {
        region      = var.secondary_region
        registry_id = aws_ecr_repository.this["${var.prefix}-frontend"].registry_id
      }
      repository_filter {
        filter      = var.prefix
        filter_type = "PREFIX_MATCH"
      }
    }
  }

  depends_on = [aws_ecr_repository.this]
}
