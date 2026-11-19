# ─────────────────────────────────────────────────────────────────────────────
# Кеш: Redis окремим ECS-сервісом у приватній мережі (без витрат на ElastiCache).
#
# Один Redis на всі екземпляри застосунку: дані, закешовані одним екземпляром,
# бачать усі інші. Застосунок знаходить Redis за DNS-ім'ям у Cloud Map:
#   redis.<project>.local
# Redis — лише кеш: даних, які не можна втратити, у ньому немає, тому
# персистентність вимкнена, а при рестарті задачі кеш просто прогрівається знову.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  redis_host = "redis.${aws_service_discovery_private_dns_namespace.main.name}"
}

resource "aws_service_discovery_private_dns_namespace" "main" {
  name = "${var.project_name}.local"
  vpc  = aws_vpc.main.id
}

resource "aws_service_discovery_service" "redis" {
  name = "redis"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.main.id
    routing_policy = "MULTIVALUE"

    dns_records {
      type = "A"
      ttl  = 10
    }
  }

  health_check_custom_config {}
}

resource "aws_ecs_task_definition" "redis" {
  family                   = "${var.project_name}-redis"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name = "redis"
      # Офіційний образ через ECR Public — без лімітів Docker Hub.
      image     = "public.ecr.aws/docker/library/redis:7.4-alpine"
      essential = true
      command = [
        "redis-server",
        "--save", "", "--appendonly", "no", # без персистентності: це кеш
        "--maxmemory", "128mb",
        "--maxmemory-policy", "allkeys-lru", # при заповненні витісняти найдавніші
      ]
      portMappings = [{ containerPort = 6379, protocol = "tcp" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "redis"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "redis" {
  name            = "${var.project_name}-redis"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.redis.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.redis.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.redis.arn
  }

  # Redis не можна запускати у двох копіях одночасно (кожна мала б свій кеш).
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  depends_on = [
    aws_route_table_association.app,
    aws_iam_role_policy_attachment.ecs_execution_managed,
  ]
}
