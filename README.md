# SmartBite

SmartBite — вебзастосунок для персонального планування харчування. За параметрами користувача (стать, вік, зріст, вага, ціль) він рахує денну норму калорій, а потім складає тижневий план харчування в межах заданого бюджету і список покупок до нього.

Цей репозиторій містить бекенд SmartBite (REST API на FastAPI), запакований у контейнер і розгорнутий в AWS: інфраструктура описана в Terraform, деплой автоматичний з GitHub Actions.

## Публічна адреса

**http://ЗАМІНИТИ-НА-АДРЕСУ-ALB** — значення `terraform output app_url` після розгортання.

| Що | Шлях |
|---|---|
| Health check | `/health` |
| Список ендпоінтів (Swagger UI) | `/docs` |
| Збережені плани (дані з бази) | `/make-server-fd5d4174/plans` |

## Архітектура

```
                        Інтернет
                           │ HTTP :80
              ┌────────────▼────────────┐
              │ Application Load Balancer│   публічні підмережі (2 зони)
              └────────────┬────────────┘   + NAT-шлюз
                           │ :8000, health check GET /health
              ┌────────────▼────────────┐
              │   ECS Fargate (FastAPI)  │   приватні підмережі app
              └────────────┬────────────┘   без публічної адреси
                           │ :5432
              ┌────────────▼────────────┐
              │    RDS PostgreSQL 17     │   приватні підмережі db
              └─────────────────────────┘   без маршруту в інтернет

GitHub Actions ──OIDC──► IAM-роль ──► ECR (образ :<хеш коміту>) ──► ECS service
```

- **Реєстр образів** — приватний репозиторій ECR, теги незмінні (тег = хеш коміту).
- **База даних** — RDS PostgreSQL у приватних підмережах без публічної адреси. Її security group приймає з'єднання лише від security group застосунку.
- **Застосунок** — ECS Fargate у приватних підмережах. Єдиний відкритий порт — 8000, і лише для балансувальника.
- **Балансувальник** — ALB, єдине, що видно з інтернету. Health check — `GET /health`.
- **Секрети** — пароль бази генерує Terraform. Рядок підключення лежить у SSM Parameter Store (SecureString), ECS передає його контейнеру як змінну середовища `DATABASE_URL`. У коді, образі й репозиторії його немає.
- **CI/CD** — GitHub Actions отримує тимчасові облікові дані через OIDC і роль з мінімальними правами. Ключів доступу в GitHub Secrets немає.

## REST API

Усі ендпоінти, крім `/` і `/health`, мають префікс `/make-server-fd5d4174` (сумісність із фронтендом).

| Метод | Шлях | Опис |
|---|---|---|
| GET | `/health` | Стан сервісу і версія (хеш коміту) |
| GET | `/health/db` | Перевірка з'єднання з базою |
| POST | `/calculate-calories` | Денна норма калорій (формула Міффліна — Сан-Жеора) |
| POST | `/generate-plan` | Згенерувати план харчування; **план зберігається в базі**, у відповіді є `plan_id` |
| GET | `/plans` | Список збережених планів |
| GET | `/plans/{id}` | Збережений план повністю |
| DELETE | `/plans/{id}` | Видалити план |
| GET | `/ingredients` | Граф інгредієнтів |

Таблиця `meal_plans`: `id`, `created_at`, параметри запиту (`week_budget_uah`, `daily_cal_target`, `meals_per_day`, `days`), підсумки (`total_cost_uah`, `total_cal`) і повний результат у `result` (JSONB). Таблиця створюється автоматично під час старту застосунку.

## Структура проєкту

```
.
├── smartbite_python_backend/smartbite_python_backend/
│   ├── main.py                 # FastAPI: роути, валідація
│   ├── database.py             # SQLAlchemy: підключення, модель MealPlan
│   ├── meal_engine.py          # алгоритм складання плану
│   ├── ingredient_graph.json   # інгредієнти та їх сумісність
│   ├── test_meal_engine.py     # юніт-тести (запускаються в CI)
│   ├── requirements.txt        # залежності із зафіксованими версіями
│   ├── Dockerfile
│   └── .dockerignore
├── compose.yaml                # локальний запуск: API + PostgreSQL
├── terraform/
│   ├── versions.tf             # версії Terraform і провайдерів
│   ├── variables.tf            # вхідні змінні
│   ├── budget.tf               # бюджет зі сповіщенням на email
│   ├── network.tf              # VPC, підмережі, маршрути, NAT
│   ├── security.tf             # security groups
│   ├── ecr.tf                  # реєстр образів
│   ├── database.tf             # RDS, пароль, рядок підключення в SSM
│   ├── alb.tf                  # балансувальник, target group, health check
│   ├── ecs.tf                  # кластер, task definition, сервіс, execution role
│   ├── github_oidc.tf          # OIDC provider і роль для GitHub Actions
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── .github/workflows/deploy.yml  # CI/CD
├── scripts/cleanup-task-definitions.sh
└── smartbite_frontend_updated/   # фронтенд (React + Vite), у хмару не розгортається
```

## Локальний запуск

Потрібен лише Docker.

```bash
docker compose up --build
```

API: http://localhost:8000, документація: http://localhost:8000/docs.

```bash
# згенерувати план (він збережеться в базі)
curl -X POST http://localhost:8000/make-server-fd5d4174/generate-plan \
  -H 'Content-Type: application/json' \
  -d '{"week_budget_uah": 1500, "daily_cal_target": 2000}'

# список збережених планів
curl http://localhost:8000/make-server-fd5d4174/plans
```

Дані бази лежать у volume `db-data` і переживають `docker compose down`. Повністю видалити разом із даними: `docker compose down -v`.

## Розгортання в AWS

Потрібні: [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.9, [AWS CLI](https://aws.amazon.com/cli/) v2, [GitHub CLI](https://cli.github.com/) (необов'язково).

### 1. Акаунт AWS

1. На root-акаунті ввімкнути MFA.
2. Створити окремого IAM-користувача для роботи (політика `AdministratorAccess`, бо Terraform створює мережу, IAM-ролі, базу тощо) і далі працювати тільки від нього.
3. Створити користувачу access key і налаштувати CLI: `aws configure` (регіон `eu-central-1`).

Перевірка: `aws sts get-caller-identity` показує IAM-користувача, а не root.

### 2. Змінні Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

У `terraform.tfvars` заповнити `budget_email` і `github_oidc_subject_prefix`. Префікс залежить від того, коли створено репозиторій на GitHub:

```bash
# створено після 15.07.2026 — формат з числовими ID
gh api repos/OWNER/REPO --jq '"repo:\(.owner.login)@\(.owner.id)/\(.name)@\(.id)"'

# створено до 15.07.2026 — класичний формат
gh api repos/OWNER/REPO --jq '"repo:\(.full_name)"'
```

Те саме значення показано в налаштуваннях репозиторію: Settings → Actions → OIDC.

### 3. Створення інфраструктури

```bash
terraform init
terraform validate

# спершу бюджет зі сповіщенням
terraform apply -target=aws_budgets_budget.monthly

# потім усе інше (близько 10–15 хвилин, найдовше створюється база)
terraform apply
```

Після цього сервіс ECS уже існує, але образу в реєстрі ще немає — його збере і викладе перший запуск CI/CD.

### 4. Змінні репозиторію GitHub

Workflow потрібні дві змінні (не секрети): Settings → Secrets and variables → Actions → Variables.

```bash
gh variable set AWS_ROLE_ARN --body "$(terraform output -raw github_actions_role_arn)"
gh variable set AWS_REGION   --body "$(terraform output -raw aws_region)"
```

### 5. Перший деплой

```bash
git push origin main
```

Якщо код уже був запушений раніше — запустити workflow вручну: Actions → CI/CD → Run workflow.

### 6. Перевірка

```bash
URL=$(terraform output -raw app_url)

curl $URL/health                         # {"status":"ok","version":"<хеш коміту>"}
curl $URL/make-server-fd5d4174/health/db # застосунок бачить базу

curl -X POST $URL/make-server-fd5d4174/generate-plan \
  -H 'Content-Type: application/json' \
  -d '{"week_budget_uah": 1500, "daily_cal_target": 2000}'

curl $URL/make-server-fd5d4174/plans     # дані, прочитані з RDS
```

## CI/CD

`.github/workflows/deploy.yml`, запускається на кожен push у `main`:

1. **Tests** — юніт-тести алгоритму (`pytest`). Якщо тести не пройшли, деплою не буде.
2. **Build and deploy**:
   - отримує тимчасові облікові дані AWS через OIDC;
   - збирає образ і публікує в ECR з тегом, що дорівнює хешу коміту;
   - реєструє нову ревізію task definition з цим образом;
   - оновлює сервіс ECS і чекає, поки нова задача пройде health check балансувальника.

Версію, що зараз працює, видно в `GET /health` — поле `version` дорівнює хешу коміту.

**Відкат на попередню версію:** `git revert <коміт>` і push, або вручну вказати сервісу попередню ревізію:

```bash
aws ecs update-service --cluster smartbite --service smartbite --task-definition smartbite:<номер ревізії>
```

## Видалення ресурсів

```bash
cd terraform
terraform destroy
../scripts/cleanup-task-definitions.sh
```

Скрипт потрібен, бо кожен деплой з GitHub Actions реєструє нову ревізію task definition, а Terraform знає лише про першу. Ревізії безкоштовні, але без скрипта вони залишаться в акаунті.

Поки інфраструктура розгорнута, вона коштує приблизно 3 USD на добу (NAT-шлюз, балансувальник, Fargate, RDS, публічні IPv4-адреси) — частину покриває Free Tier.

## Свідомі спрощення

- **HTTP без HTTPS.** Для сертифіката потрібен власний домен.
- **Один NAT-шлюз, один екземпляр застосунку, база в одній зоні без бекапів.** Це навчальний стенд; у `terraform/database.tf` і `variables.tf` вказано, що змінити для продакшену.
- **Terraform state зберігається локально** і не комітиться (містить пароль бази).

## Команда

SmartBite розроблено як командний навчальний проєкт: Kateryna Rudenko, Sofia Volvach, Kateryna Zinchuk, Melaniia Poliuga.
