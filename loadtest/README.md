# Навантажувальний тест

Потрібен [k6](https://grafana.com/docs/k6/latest/set-up/install-k6/) (`winget install k6` / `brew install k6`).

Запуск із кореня репозиторію однією командою:

```bash
k6 run -e BASE_URL=$(terraform -chdir=terraform output -raw app_url) loadtest/smartbite.js
```

PowerShell:

```powershell
k6 run -e BASE_URL=$(terraform -chdir=terraform output -raw app_url) loadtest/smartbite.js
```

Параметри (`-e NAME=value`): `VUS` (N, за замовчуванням 8), `CACHE=on|off`,
`THINK` (пауза, с), `RAMP_UP`/`STEADY`/`RAMP_DOWN` (3m/5m/2m).

Підсумок друкується в консоль і зберігається в `loadtest/results/summary-cache-<on|off>-<час>.json`.

Після тесту — дочекатися, поки кількість задач повернеться до 1:

```bash
aws ecs describe-services --cluster smartbite --services smartbite \
  --query 'services[0].[desiredCount,runningCount]'
```

Опис і результати — [docs/LOADTEST.md](../docs/LOADTEST.md).
