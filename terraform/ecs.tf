# ─────────────────────────────────────────────────────────────────────────────
# Запуск контейнера: ECS Fargate.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = var.project_name
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = 7
}

# ── Execution role: нею користується сам ECS, щоб підготувати запуск контейнера ─
# (завантажити образ з ECR, прочитати секрет, писати логи). Ключів доступу немає:
# ECS бере тимчасові облікові дані, приймаючи цю роль.

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "${var.project_name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# Керована політика AWS: pull образів з ECR і запис у CloudWatch Logs.
resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Найменші привілеї: читати можна рівно один параметр — рядок підключення.
data "aws_iam_policy_document" "ecs_execution_secrets" {
  statement {
    actions   = ["ssm:GetParameters"]
    resources = [aws_ssm_parameter.database_url.arn]
  }
}

resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name   = "read-database-url"
  role   = aws_iam_role.ecs_execution.id
  policy = data.aws_iam_policy_document.ecs_execution_secrets.json
}

# ── Task definition: «рецепт» запуску контейнера ─────────────────────────────

resource "aws_ecs_task_definition" "app" {
  family                   = var.project_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256" # 0.25 vCPU
  memory                   = "512" # MiB
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64" # образ збирається на x86-раннері GitHub Actions
  }

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
      essential = true

      # Єдиний відкритий порт контейнера.
      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "APP_VERSION", value = var.image_tag }
      ]

      # Секрет не записаний у task definition: тут лише посилання (ARN).
      # Значення ECS читає з SSM у момент запуску і передає як змінну середовища.
      secrets = [
        { name = "DATABASE_URL", valueFrom = aws_ssm_parameter.database_url.arn }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "app"
        }
      }
    }
  ])
}

# ── Service: підтримує потрібну кількість запущених задач за балансувальником ─

resource "aws_ecs_service" "app" {
  name            = var.project_name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false # публічної адреси немає; вхід лише через ALB
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = var.container_port
  }

  health_check_grace_period_seconds = 60

  # Rolling update без простою: нова задача стартує поряд зі старою, і стара
  # зупиняється лише після того, як нова пройшла health check.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # Якщо нова версія не стартує, ECS сам повертає попередню.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Нові ревізії task definition (з новим образом) реєструє CI/CD.
  # Без цього рядка наступний `terraform apply` відкотив би сервіс на першу ревізію.
  lifecycle {
    ignore_changes = [task_definition]
  }

  # Сервісу потрібні готовий listener (інакше target group не прив'язана до ALB),
  # маршрут через NAT (pull образу) і права execution role.
  depends_on = [
    aws_lb_listener.http,
    aws_route_table_association.app,
    aws_iam_role_policy_attachment.ecs_execution_managed,
    aws_iam_role_policy.ecs_execution_secrets,
  ]
}
