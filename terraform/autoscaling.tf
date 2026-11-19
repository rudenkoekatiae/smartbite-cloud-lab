# ─────────────────────────────────────────────────────────────────────────────
# Автоматичне горизонтальне масштабування ECS-сервісу (Application Auto Scaling).
# Обґрунтування параметрів — docs/AUTOSCALING.md.
# ─────────────────────────────────────────────────────────────────────────────

# Що масштабуємо і в яких межах: DesiredCount сервісу, від min до max задач.
resource "aws_appautoscaling_target" "app" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.autoscaling_min
  max_capacity       = var.autoscaling_max
}

# Target tracking: AWS сам створює два CloudWatch-alarm-и (High і Low) і підбирає
# кількість задач так, щоб середнє завантаження CPU трималося біля target_value.
resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.project_name}-cpu-target"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.app.service_namespace
  resource_id        = aws_appautoscaling_target.app.resource_id
  scalable_dimension = aws_appautoscaling_target.app.scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value = var.autoscaling_cpu_target

    # Після додавання задачі наступне додавання — не раніше ніж через 60 с:
    # нова задача має встигнути стартувати й почати знімати навантаження.
    scale_out_cooldown = 60
    # Після вилучення — 180 с до наступного вилучення: знімаємо по одній, обережно.
    scale_in_cooldown = 180

    disable_scale_in = false
  }
}

# ── Бонус 8: масштабування за розкладом (вимкнено за замовчуванням) ──────────
# Удень мінімум 2 задачі, вночі — 1. Час — київський.

resource "aws_appautoscaling_scheduled_action" "day" {
  count = var.enable_scheduled_scaling ? 1 : 0

  name               = "${var.project_name}-day"
  service_namespace  = aws_appautoscaling_target.app.service_namespace
  resource_id        = aws_appautoscaling_target.app.resource_id
  scalable_dimension = aws_appautoscaling_target.app.scalable_dimension
  schedule           = "cron(0 8 * * ? *)"
  timezone           = "Europe/Kyiv"

  scalable_target_action {
    min_capacity = 2
    max_capacity = var.autoscaling_max
  }
}

resource "aws_appautoscaling_scheduled_action" "night" {
  count = var.enable_scheduled_scaling ? 1 : 0

  name               = "${var.project_name}-night"
  service_namespace  = aws_appautoscaling_target.app.service_namespace
  resource_id        = aws_appautoscaling_target.app.resource_id
  scalable_dimension = aws_appautoscaling_target.app.scalable_dimension
  schedule           = "cron(0 22 * * ? *)"
  timezone           = "Europe/Kyiv"

  scalable_target_action {
    min_capacity = 1
    max_capacity = var.autoscaling_max
  }

  # Дві дії над одним target не можна змінювати паралельно.
  depends_on = [aws_appautoscaling_scheduled_action.day]
}
