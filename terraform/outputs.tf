output "app_url" {
  description = "Публічна адреса застосунку (DNS-ім'я балансувальника)."
  value       = "http://${aws_lb.main.dns_name}"
}

output "github_actions_role_arn" {
  description = "Значення для змінної репозиторію AWS_ROLE_ARN (лише коли enable_github_oidc = true)."
  value       = one(aws_iam_role.github_actions[*].arn)
}

output "ci_access_key_id" {
  description = "Значення для секрету репозиторію AWS_ACCESS_KEY_ID (лише коли enable_github_oidc = false)."
  value       = one(aws_iam_access_key.github_actions[*].id)
}

output "ci_secret_access_key" {
  description = "Значення для секрету репозиторію AWS_SECRET_ACCESS_KEY (лише коли enable_github_oidc = false)."
  value       = one(aws_iam_access_key.github_actions[*].secret)
  sensitive   = true
}

output "aws_region" {
  description = "Значення для змінної репозиторію AWS_REGION."
  value       = var.aws_region
}

output "ecr_repository_url" {
  description = "Адреса приватного реєстру образів."
  value       = aws_ecr_repository.app.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}

output "db_endpoint" {
  description = "Приватна адреса бази (доступна лише зсередини VPC)."
  value       = aws_db_instance.main.address
}

output "log_group" {
  description = "Логи застосунку в CloudWatch."
  value       = aws_cloudwatch_log_group.app.name
}
