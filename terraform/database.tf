# ─────────────────────────────────────────────────────────────────────────────
# Керована база даних: RDS PostgreSQL у приватних підмережах.
# ─────────────────────────────────────────────────────────────────────────────

# Пароль генерує Terraform: його немає ні в коді, ні в tfvars. Він зберігається
# у state (який не комітиться) і в SSM Parameter Store у зашифрованому вигляді.
resource "random_password" "db" {
  length  = 32
  special = false # лише літери й цифри, щоб не екранувати пароль у рядку підключення
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db"
  subnet_ids = aws_subnet.db[*].id
}

resource "aws_db_instance" "main" {
  identifier = "${var.project_name}-db"

  engine                     = "postgres"
  engine_version             = var.db_engine_version
  auto_minor_version_upgrade = true
  instance_class             = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "smartbite"
  username = "smartbite"
  password = random_password.db.result
  port     = 5432

  # Мережева ізоляція: приватні підмережі, без публічної адреси,
  # доступ лише від security group застосунку.
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  # Навчальний стенд: одна зона, без бекапів — дешевше і `terraform destroy`
  # не залишає після себе снапшотів. Для продакшену: multi_az = true,
  # backup_retention_period >= 7, deletion_protection = true.
  multi_az                 = false
  backup_retention_period  = var.db_backup_retention_days
  delete_automated_backups = true
  skip_final_snapshot      = true
  deletion_protection      = false
  apply_immediately        = true
}

# Рядок підключення цілком — у SSM Parameter Store як SecureString (шифрується KMS).
# ECS підставляє його в контейнер як змінну середовища DATABASE_URL під час запуску.
resource "aws_ssm_parameter" "database_url" {
  name        = "/${var.project_name}/DATABASE_URL"
  description = "SQLAlchemy connection string for the app"
  type        = "SecureString"

  value = format(
    "postgresql+psycopg://%s:%s@%s:%d/%s",
    aws_db_instance.main.username,
    random_password.db.result,
    aws_db_instance.main.address,
    aws_db_instance.main.port,
    aws_db_instance.main.db_name,
  )
}
