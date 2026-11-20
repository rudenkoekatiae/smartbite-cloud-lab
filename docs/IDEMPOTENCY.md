# Ідемпотентність операцій запису (бонус 7)

Код: [idempotency.py](../smartbite_python_backend/smartbite_python_backend/idempotency.py).
Тест: [test_idempotency.py](../smartbite_python_backend/smartbite_python_backend/test_idempotency.py).

## Яку проблему це розв'язує

`POST /generate-plan` не ідемпотентний: кожен виклик створює **новий** план у базі.
Мережа ненадійна. Клієнт надіслав запит, сервер створив план, але відповідь загубилась
(таймаут, обрив мобільного зв'язку, рестарт балансувальника). Клієнт не знає,
чи запит виконався, і повторює його. Отримуємо два однакові плани.

Для SmartBite це «лише» дубль у списку. Для оплати, замовлення чи списання бонусів
це подвійне списання грошей.

Рішення: клієнт генерує унікальний ключ на одну **логічну** операцію і надсилає
його в заголовку `Idempotency-Key`. Усі повтори цієї операції йдуть із тим самим ключем.

## Як працює

Ендпоінти `POST /generate-plan` і `POST /plan-jobs` приймають заголовок `Idempotency-Key`.

| Ситуація | Відповідь |
|---|---|
| Ключа немає | звичайне виконання |
| Перший запит із ключем | виконання. Відповідь (статус + тіло) зберігається в Redis `idem:<ендпоінт>:<ключ>` на **24 год** |
| Повтор із тим самим ключем і тілом | **збережена відповідь** без виконання, заголовок `Idempotent-Replayed: true` |
| Повтор, поки перший ще виконується | **409 Conflict**: «ще обробляється, повторіть пізніше» |
| Той самий ключ, **інше** тіло | **422**: ключ не можна використати для іншої операції |
| Перший запит завершився помилкою (400, збій бази) | ключ звільняється, повтор з ним виконається заново |

Деталі реалізації:
* **Атомарність.** Ключ захоплюється командою `SET key value NX EX 60`. З двох
  одночасних однакових запитів (наприклад, на різних екземплярах API) лише один
  отримує ключ. Тому сховище — спільний Redis, а не пам'ять процесу.
* **Відбиток тіла** (SHA-256 нормалізованого JSON): захищає від помилки клієнта,
  який використав той самий ключ для іншого запиту.
* **Захист від завислого ключа.** Стан `processing` живе 60 с. Якщо екземпляр упав
  посеред виконання, ключ звільниться сам.
* **Fail-open.** Якщо Redis недоступний, запит виконується без захисту від дублів.
  Для SmartBite дубль плану менше зло, ніж відмова. Для платежів правильно навпаки:
  відповісти 503.

## Тест: два однакові запити — один запис, дві однакові відповіді

```bash
cd smartbite_python_backend/smartbite_python_backend
pip install -r requirements.txt -r requirements-dev.txt
python -m pytest -v test_idempotency.py
```

```
test_same_key_twice_one_record_same_response   PASSED   ← два запити: 1 запис у базі, r1.json() == r2.json()
test_without_key_each_request_creates_record   PASSED   ← без ключа: 2 запити = 2 записи
test_same_key_different_body_is_rejected       PASSED   ← той самий ключ з іншим тілом → 422
test_key_in_progress_returns_409               PASSED   ← повтор під час виконання → 409
test_async_job_same_key_enqueued_once          PASSED   ← POST /plan-jobs: одне завдання в черзі
```

Тести виконуються в CI перед кожним деплоєм. Для них потрібні SQLite і `fakeredis`,
справжні база й Redis не потрібні.

Перевірка на розгорнутому сервісі:

```bash
URL=$(terraform -chdir=terraform output -raw app_url)/make-server-fd5d4174
KEY=$(uuidgen)
BODY='{"week_budget_uah":1500,"daily_cal_target":2000}'
curl -s -i -X POST $URL/generate-plan -H "Content-Type: application/json" -H "Idempotency-Key: $KEY" -d "$BODY" | grep -E "HTTP|plan_id|Idempotent"
curl -s -i -X POST $URL/generate-plan -H "Content-Type: application/json" -H "Idempotency-Key: $KEY" -d "$BODY" | grep -E "HTTP|plan_id|Idempotent"
# той самий plan_id, у другій відповіді Idempotent-Replayed: true
```

Навантажувальний сценарій надсилає унікальний `Idempotency-Key` з кожним записом,
як це робив би реальний клієнт.

## Як поєднується з чергою (бонус 6)

Ідемпотентність потрібна на **обох кінцях** черги:

1. **Клієнт → API** (`Idempotency-Key`). Повтор `POST /plan-jobs` після таймауту
   повертає **те саме** `job_id` (та сама відповідь 202). Друге завдання в черзі
   не з'являється (тест `test_async_job_same_key_enqueued_once`).
2. **Черга → обробник** (at-least-once). SQS може доставити одне повідомлення
   двічі. Обробник захищається сам, без Redis: завдання захоплюється умовним
   `UPDATE … WHERE status='queued'`, а план і статус `done` пишуться в одній
   транзакції. Повторне повідомлення для `done`-завдання просто видаляється
   (тест `test_job_lifecycle_and_duplicate_delivery`). Детальніше —
   [QUEUE.md](QUEUE.md).

Разом це дає **ефект «рівно один раз»** поверх доставки «щонайменше один раз»:
скільки б разів клієнт не повторив запит і скільки б разів SQS не доставив
повідомлення, у базі буде один план.
