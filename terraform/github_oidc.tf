# ─────────────────────────────────────────────────────────────────────────────
# Доступ GitHub Actions до AWS через OIDC — без збережених ключів доступу.
#
# GitHub видає кожному запуску workflow короткоживучий підписаний токен (JWT).
# AWS довіряє видавцю токенів (OIDC provider) і в обмін на токен дає тимчасові
# облікові дані ролі — але лише якщо токен відповідає умовам trust policy.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# Trust policy: ХТО може прийняти роль.
# Тільки workflow з конкретного репозиторію і тільки з гілки main.
data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${var.github_oidc_subject_prefix}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name                 = "${var.project_name}-github-actions"
  assume_role_policy   = data.aws_iam_policy_document.github_actions_assume.json
  max_session_duration = 3600
}

# Permissions policy: ЩО може роль. Рівно те, що потрібно для деплою:
# запушити образ у один репозиторій ECR і оновити один сервіс ECS.
data "aws_iam_policy_document" "github_actions_deploy" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # ця дія не підтримує обмеження за ресурсом
  }

  statement {
    sid = "EcrPushToOneRepository"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  statement {
    sid = "EcsTaskDefinitions"
    actions = [
      "ecs:DescribeTaskDefinition",
      "ecs:RegisterTaskDefinition",
    ]
    resources = ["*"] # ці дії не підтримують обмеження за ресурсом
  }

  statement {
    sid = "EcsUpdateOneService"
    actions = [
      "ecs:DescribeServices",
      "ecs:UpdateService",
    ]
    resources = [aws_ecs_service.app.id] # id сервісу — це його ARN
  }

  # Реєструючи task definition, CI «передає» ECS роль запуску. Дозволено передати
  # тільки цю одну роль і тільки сервісу ECS.
  statement {
    sid       = "PassExecutionRoleToEcs"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.ecs_execution.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "github_actions_deploy" {
  name   = "deploy"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_deploy.json
}
