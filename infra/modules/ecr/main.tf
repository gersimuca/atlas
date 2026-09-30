resource "aws_ecr_repository" "this" {
  for_each = toset(var.repository_names)

  name                 = "${var.project_name}/${each.key}"
  image_tag_mutability = "IMMUTABLE" # once pushed, a tag (e.g. a git SHA) can never be silently overwritten

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  tags = merge(var.tags, { Name = "${var.project_name}-${each.key}" })
}

# Keep the last 15 tagged images and expire anything untagged after 3
# days (build cache leftovers), so the registry doesn't grow forever.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 3 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 3
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last 15 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 15
        }
        action = { type = "expire" }
      },
    ]
  })
}
