# ─────────────────────────────────────────────────────────────────────────────
# Бонус 6: асинхронна генерація планів через чергу Amazon SQS.
#
#   клієнт → POST /plan-jobs → API: запис у plan_jobs + повідомлення в SQS → 202
#   worker (окремий ECS-сервіс) ← SQS: генерує план, пише в базу, видаляє повідомлення
#   клієнт → GET /plan-jobs/{id} → queued | processing | done (+ plan_id) | failed
#
# Обробник масштабується від довжини черги (ApproximateNumberOfMessagesVisible).
# ─────────────────────────────────────────────────────────────────────────────

# Сюди SQS переносить повідомлення, які не вдалося обробити 3 рази поспіль
# (наприклад, через помилку в коді) — щоб вони не крутились у черзі вічно.
resource "aws_sqs_queue" "jobs_dlq" {
  name                      = "${var.project_name}-plan-jobs-dlq"
  message_retention_seconds = 1209600 # 14 днів на розбір
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "jobs" {
  name = "${var.project_name}-plan-jobs"

  # Скільки повідомлення «невидиме» для інших після отримання обробником.
  # Генерація займає ~2–3 с на 0.25 vCPU; 60 с — із запасом на чергу в процесі.
  visibility_timeout_seconds = 60
  message_retention_seconds  = 86400 # завдання, яке ніхто не взяв за добу, вже неактуальне
  receive_wait_time_seconds  = 10    # long polling за замовчуванням
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_dlq.arn
    maxReceiveCount     = 3
  })
}

# ── Ролі задач (task role): права самого коду в контейнері ───────────────────
# (execution role з ecs.tf — це права ECS на запуск: pull образу, секрети, логи.)

resource "aws_iam_role" "app_task" {
  name               = "${var.project_name}-app-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# API може лише класти повідомлення в одну чергу.
resource "aws_iam_role_policy" "app_task_sqs" {
  name = "send-plan-jobs"
  role = aws_iam_role.app_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage", "sqs:GetQueueUrl"]
      Resource = aws_sqs_queue.jobs.arn
    }]
  })
}

resource "aws_iam_role" "worker_task" {
  name               = "${var.project_name}-worker-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# Обробник може лише читати й видаляти повідомлення з тієї самої черги.
resource "aws_iam_role_policy" "worker_task_sqs" {
  name = "consume-plan-jobs"
  role = aws_iam_role.worker_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:ChangeMessageVisibility",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
      ]
      Resource = aws_sqs_queue.jobs.arn
    }]
  })
}

# ── Обробник: той самий образ, інша команда ──────────────────────────────────

resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.project_name}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.worker_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "worker"
      image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
      essential = true
      command   = ["python", "worker.py"]

      # Після SIGTERM обробник дообробляє поточне повідомлення (до ~10 с long poll
      # + ~3 с генерації); 30 с — із запасом, далі ECS надсилає SIGKILL.
      stopTimeout = 30

      environment = [
        { name = "APP_VERSION", value = var.image_tag },
        { name = "SQS_QUEUE_URL", value = aws_sqs_queue.jobs.url },
        { name = "AWS_REGION", value = var.aws_region },
      ]
      secrets = [
        { name = "DATABASE_URL", valueFrom = aws_ssm_parameter.database_url.arn }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "worker"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "worker" {
  name            = "${var.project_name}-worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.worker_min
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.worker.id]
    assign_public_ip = false
  }

  # Образ оновлює CI/CD, кількість задач — автоскейлер.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [
    aws_route_table_association.app,
    aws_iam_role_policy_attachment.ecs_execution_managed,
    aws_iam_role_policy.ecs_execution_secrets,
  ]
}

# ── Масштабування обробника від довжини черги ────────────────────────────────

resource "aws_appautoscaling_target" "worker" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.worker.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.worker_min
  max_capacity       = var.worker_max
}

# Target tracking за кількістю видимих повідомлень у черзі: якщо в черзі більше
# worker_queue_target завдань — додати обробник, якщо черга порожня — прибрати.
resource "aws_appautoscaling_policy" "worker_queue" {
  name               = "${var.project_name}-worker-queue-depth"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.worker.service_namespace
  resource_id        = aws_appautoscaling_target.worker.resource_id
  scalable_dimension = aws_appautoscaling_target.worker.scalable_dimension

  target_tracking_scaling_policy_configuration {
    customized_metric_specification {
      namespace   = "AWS/SQS"
      metric_name = "ApproximateNumberOfMessagesVisible"
      statistic   = "Average"
      dimensions {
        name  = "QueueName"
        value = aws_sqs_queue.jobs.name
      }
    }

    target_value       = var.worker_queue_target
    scale_out_cooldown = 60
    scale_in_cooldown  = 120
  }
}
