variable "aws_region" {
  description = "Регіон AWS, у якому створюється вся інфраструктура."
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Префікс імен ресурсів. Має збігатися з PROJECT у .github/workflows/deploy.yml."
  type        = string
  default     = "smartbite"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project_name))
    error_message = "project_name: малі латинські літери, цифри й дефіс, 2-21 символ, починається з літери."
  }
}

variable "github_oidc_subject_prefix" {
  description = <<-EOT
    Префікс claim `sub` у OIDC-токені GitHub Actions для вашого репозиторію.
    Репозиторій, створений до 15.07.2026:  repo:OWNER/REPO
    Репозиторій, створений після 15.07.2026: repo:OWNER@OWNER_ID/REPO@REPO_ID
    Як дізнатись — див. README, розділ «Розгортання».
  EOT
  type        = string

  validation {
    condition     = can(regex("^repo:[^/:*?]+/[^/:*?]+$", var.github_oidc_subject_prefix))
    error_message = "Очікується repo:OWNER/REPO або repo:OWNER@ID/REPO@ID, без масок * і без суфікса :ref:..."
  }
}

variable "enable_github_oidc" {
  description = <<-EOT
    true  — GitHub Actions отримує доступ через OIDC і роль (рекомендовано).
    false — запасний варіант для акаунтів, де створення OIDC-провайдера
            заборонене політикою організації: IAM-користувач для CI з ключем доступу.
  EOT
  type        = bool
  default     = true
}

variable "budget_email" {
  description = "Email для сповіщень AWS Budgets."
  type        = string
}

variable "monthly_budget_usd" {
  description = "Місячний ліміт бюджету в USD."
  type        = number
  default     = 10
}

variable "vpc_cidr" {
  description = "Адресний простір VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "container_port" {
  description = "Порт, який слухає застосунок у контейнері."
  type        = number
  default     = 8000
}

variable "desired_count" {
  description = "Кількість екземплярів (tasks) застосунку."
  type        = number
  default     = 1
}

variable "image_tag" {
  description = "Тег образу в першій ревізії task definition. Далі образ оновлює CI/CD (тег = хеш коміту)."
  type        = string
  default     = "initial"
}

variable "db_instance_class" {
  description = "Клас інстансу RDS."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_engine_version" {
  description = "Мажорна версія PostgreSQL в RDS."
  type        = string
  default     = "17"
}

variable "db_backup_retention_days" {
  description = "Скільки днів зберігати автоматичні бекапи (0 = вимкнено, point-in-time recovery недоступний)."
  type        = number
  default     = 0
}
