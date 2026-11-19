# ─────────────────────────────────────────────────────────────────────────────
# Панель моніторингу CloudWatch і сповіщення на email.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  ecs_dims = ["ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.app.name]
  alb_dim  = ["LoadBalancer", aws_lb.main.arn_suffix]
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = var.project_name

  dashboard_body = jsonencode({
    start          = "-PT1H"
    periodOverride = "inherit"
    widgets = [
      # 1. Кількість екземплярів: бажана (рішення автоскейлера) і фактична.
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "Екземпляри: бажана і фактична кількість"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Maximum"
          period = 60
          metrics = [
            concat(["ECS/ContainerInsights", "DesiredTaskCount"], local.ecs_dims, [{ label = "Desired" }]),
            concat(["ECS/ContainerInsights", "RunningTaskCount"], local.ecs_dims, [{ label = "Running" }]),
          ]
          yAxis = { left = { min = 0, max = var.autoscaling_max + 1 } }
          annotations = {
            horizontal = [{ label = "max", value = var.autoscaling_max }]
          }
        }
      },
      # 2. Завантаження процесора з порогами масштабування і тривоги.
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "CPU сервісу, %"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          metrics = [
            concat(["AWS/ECS", "CPUUtilization"], local.ecs_dims, [{ stat = "Average", label = "Average" }]),
            concat(["AWS/ECS", "CPUUtilization"], local.ecs_dims, [{ stat = "Maximum", label = "Maximum" }]),
          ]
          yAxis = { left = { min = 0, max = 100 } }
          annotations = {
            horizontal = [
              { label = "ціль масштабування", value = var.autoscaling_cpu_target },
              { label = "поріг тривоги", value = var.alert_cpu_threshold, color = "#d62728" },
            ]
          }
        }
      },
      # 3. Запити за хвилину (період 60 с, сума).
      {
        type = "metric", x = 0, y = 6, width = 8, height = 6
        properties = {
          title   = "Запити за хвилину"
          region  = var.aws_region
          view    = "timeSeries"
          stat    = "Sum"
          period  = 60
          metrics = [concat(["AWS/ApplicationELB", "RequestCount"], local.alb_dim, [{ label = "Requests/min" }])]
          yAxis   = { left = { min = 0 } }
        }
      },
      # 4. Латентність p95 (секунди — так її віддає ALB).
      {
        type = "metric", x = 8, y = 6, width = 8, height = 6
        properties = {
          title  = "Латентність p95, с"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          metrics = [
            concat(["AWS/ApplicationELB", "TargetResponseTime"], local.alb_dim, [{ stat = "p95", label = "p95" }]),
            concat(["AWS/ApplicationELB", "TargetResponseTime"], local.alb_dim, [{ stat = "p50", label = "p50" }]),
          ]
          yAxis = { left = { min = 0 } }
          annotations = {
            horizontal = [{ label = "500 мс", value = 0.5 }]
          }
        }
      },
      # 5. Відповіді 5xx: від застосунку і від самого балансувальника (502/503/504).
      {
        type = "metric", x = 16, y = 6, width = 8, height = 6
        properties = {
          title  = "Відповіді 5xx за хвилину"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          metrics = [
            concat(["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count"], local.alb_dim, [{ label = "Target 5xx" }]),
            concat(["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count"], local.alb_dim, [{ label = "ALB 5xx" }]),
          ]
          yAxis = { left = { min = 0 } }
        }
      },
      # 6. Навантаження на базу — для порівняння «без кешу / з кешем» (docs/CACHE.md).
      {
        type = "metric", x = 0, y = 12, width = 12, height = 6
        properties = {
          title  = "База даних: CPU % і читання IOPS"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.main.identifier, { stat = "Average", label = "DB CPU %" }],
            ["AWS/RDS", "ReadIOPS", "DBInstanceIdentifier", aws_db_instance.main.identifier, { stat = "Average", label = "ReadIOPS", yAxis = "right" }],
          ]
        }
      },
      # 7. Стан тривоги.
      {
        type = "alarm", x = 12, y = 12, width = 12, height = 6
        properties = {
          title  = "Тривоги"
          alarms = [aws_cloudwatch_metric_alarm.cpu_high.arn]
        }
      },
    ]
  })
}

# ── Сповіщення ───────────────────────────────────────────────────────────────

resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
}

# Після `apply` AWS надішле лист «Subscription Confirmation» — без підтвердження
# посилання в ньому листи тривоги не доставлятимуться.
resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = coalesce(var.alert_email, var.budget_email)
}

# CPU > 70% протягом 2 хвилин поспіль (2 періоди по 60 с).
# alarm_actions — лист при переході в ALARM, ok_actions — лист при поверненні в OK.
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name        = "${var.project_name}-cpu-high"
  alarm_description = "SmartBite: середній CPU сервісу > ${var.alert_cpu_threshold}% протягом 2 хв"

  namespace   = "AWS/ECS"
  metric_name = "CPUUtilization"
  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.app.name
  }
  statistic = "Average"

  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.alert_cpu_threshold

  # Немає даних (сервіс щойно створено) — не тривога.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}
