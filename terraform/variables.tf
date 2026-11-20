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

# ── Лабораторна 2: масштабування, моніторинг, кеш ──────────────────────────

variable "autoscaling_min" {
  description = "Мінімальна кількість задач сервісу."
  type        = number
  default     = 1
}

variable "autoscaling_max" {
  description = "Максимальна кількість задач сервісу (за умовою лабораторної — не більше 4)."
  type        = number
  default     = 3

  validation {
    condition     = var.autoscaling_max >= 1 && var.autoscaling_max <= 4
    error_message = "autoscaling_max: від 1 до 4."
  }
}

variable "autoscaling_cpu_target" {
  description = "Цільове середнє завантаження CPU (%) для target tracking."
  type        = number
  default     = 60
}

variable "enable_scheduled_scaling" {
  description = "Бонус 8: мінімум 2 задачі вдень (08:00–22:00 Київ), 1 вночі."
  type        = bool
  default     = false
}

variable "alert_email" {
  description = "Email для сповіщень CloudWatch. Порожньо — використовується budget_email."
  type        = string
  default     = null
}

variable "alert_cpu_threshold" {
  description = "Поріг CPU (%) для тривоги."
  type        = number
  default     = 70
}

variable "cache_enabled" {
  description = "Глобально вмикає кеш у застосунку (cache-aside для списку планів)."
  type        = bool
  default     = true
}

variable "cache_ttl_seconds" {
  description = "Термін дії запису в кеші, секунди (30–60 за умовою)."
  type        = number
  default     = 30
}

# ── Бонус 6: черга і обробник ────────────────────────────────────────────────

variable "worker_min" {
  description = "Мінімальна кількість обробників черги."
  type        = number
  default     = 1
}

variable "worker_max" {
  description = "Максимальна кількість обробників черги (не більше 4)."
  type        = number
  default     = 3

  validation {
    condition     = var.worker_max >= 1 && var.worker_max <= 4
    error_message = "worker_max: від 1 до 4."
  }
}

variable "worker_queue_target" {
  description = "Цільова кількість видимих повідомлень у черзі для target tracking обробника."
  type        = number
  default     = 5
}
