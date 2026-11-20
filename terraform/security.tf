# ─────────────────────────────────────────────────────────────────────────────
# Security groups. Ланцюжок: інтернет → ALB → застосунок → база.
# Кожна ланка приймає з'єднання лише від попередньої, і правила посилаються
# на security group, а не на IP-діапазони.
# ─────────────────────────────────────────────────────────────────────────────

# ── Балансувальник: єдине, що приймає трафік з інтернету ─────────────────────

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb"
  description = "Public load balancer"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http_from_internet" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward requests and health checks to the app"
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  referenced_security_group_id = aws_security_group.app.id
}

# ── Застосунок: вхід тільки від балансувальника і тільки на порт застосунку ──

resource "aws_security_group" "app" {
  name        = "${var.project_name}-app"
  description = "Application containers (ECS tasks)"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-app" }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "App port from the load balancer only"
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "PostgreSQL to the database"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.db.id
}

resource "aws_vpc_security_group_egress_rule" "app_https_out" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS to AWS APIs (ECR, SSM, CloudWatch Logs) via NAT"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "app_to_redis" {
  security_group_id            = aws_security_group.app.id
  description                  = "Redis cache"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = aws_security_group.redis.id
}

# ── Обробник черги: вхідних правил немає; вихід — база і HTTPS (SQS, ECR, логи) ─

resource "aws_security_group" "worker" {
  name        = "${var.project_name}-worker"
  description = "Queue worker (ECS tasks)"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-worker" }
}

resource "aws_vpc_security_group_egress_rule" "worker_to_db" {
  security_group_id            = aws_security_group.worker.id
  description                  = "PostgreSQL to the database"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.db.id
}

resource "aws_vpc_security_group_egress_rule" "worker_https_out" {
  security_group_id = aws_security_group.worker.id
  description       = "HTTPS to SQS, ECR, SSM, CloudWatch Logs via NAT"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_worker" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from the queue worker"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.worker.id
}

# ── Redis: вхід тільки від застосунку; вихід лише HTTPS (pull образу, логи) ──

resource "aws_security_group" "redis" {
  name        = "${var.project_name}-redis"
  description = "Redis cache (ECS task)"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-redis" }
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_app" {
  security_group_id            = aws_security_group.redis.id
  description                  = "Redis from the app security group only"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_vpc_security_group_egress_rule" "redis_https_out" {
  security_group_id = aws_security_group.redis.id
  description       = "HTTPS to ECR Public and CloudWatch Logs via NAT"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# ── База: вхід тільки від security group застосунку, вихідних правил немає ───

resource "aws_security_group" "db" {
  name        = "${var.project_name}-db"
  description = "RDS PostgreSQL"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-db" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from the app security group only"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.app.id
}
