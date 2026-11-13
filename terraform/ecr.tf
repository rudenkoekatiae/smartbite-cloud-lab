# Приватний реєстр образів.

resource "aws_ecr_repository" "app" {
  name = var.project_name

  # Тег = хеш коміту, тому перезаписувати його заборонено:
  # один тег завжди означає один і той самий образ.
  image_tag_mutability = "IMMUTABLE"

  # Дозволяє `terraform destroy` видалити репозиторій разом з образами.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the 10 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
