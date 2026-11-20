"""
Бонус 7: ідемпотентність операцій запису за заголовком Idempotency-Key.

Головний тест: два однакові запити з тим самим ключем → один запис у базі
і дві однакові відповіді.
"""

import uuid

from sqlalchemy import func, select

import jobs_queue
from conftest import PREFIX
from database import MealPlan, PlanJob, SessionLocal

BODY = {"week_budget_uah": 1500, "daily_cal_target": 2000, "seed": 42}


def plans_in_db() -> int:
    with SessionLocal() as s:
        return s.scalar(select(func.count()).select_from(MealPlan))


def jobs_in_db() -> int:
    with SessionLocal() as s:
        return s.scalar(select(func.count()).select_from(PlanJob))


def test_same_key_twice_one_record_same_response(client, redis_fake):
    key = str(uuid.uuid4())
    before = plans_in_db()

    r1 = client.post(f"{PREFIX}/generate-plan", json=BODY, headers={"Idempotency-Key": key})
    r2 = client.post(f"{PREFIX}/generate-plan", json=BODY, headers={"Idempotency-Key": key})

    assert r1.status_code == r2.status_code == 200
    assert r1.json() == r2.json()                     # дві однакові відповіді
    assert plans_in_db() == before + 1                 # один запис у базі
    assert "Idempotent-Replayed" not in r1.headers
    assert r2.headers["Idempotent-Replayed"] == "true"
    assert 0 < redis_fake.ttl(f"idem:generate-plan:{key}") <= 24 * 3600  # зберігається 24 год


def test_without_key_each_request_creates_record(client):
    before = plans_in_db()
    r1 = client.post(f"{PREFIX}/generate-plan", json=BODY)
    r2 = client.post(f"{PREFIX}/generate-plan", json=BODY)
    assert r1.status_code == r2.status_code == 200
    assert r1.json()["plan_id"] != r2.json()["plan_id"]
    assert plans_in_db() == before + 2


def test_same_key_different_body_is_rejected(client):
    key = str(uuid.uuid4())
    r1 = client.post(f"{PREFIX}/generate-plan", json=BODY, headers={"Idempotency-Key": key})
    r2 = client.post(
        f"{PREFIX}/generate-plan",
        json={**BODY, "daily_cal_target": 2500},
        headers={"Idempotency-Key": key},
    )
    assert r1.status_code == 200
    assert r2.status_code == 422


def test_key_in_progress_returns_409(client, redis_fake):
    key = str(uuid.uuid4())
    # Імітуємо перший запит, який ще виконується на іншому екземплярі.
    import idempotency
    from main import PlanRequest
    fp = idempotency._fingerprint(PlanRequest(**BODY).model_dump())
    redis_fake.set(f"idem:generate-plan:{key}", f'{{"state": "processing", "fp": "{fp}"}}')
    r = client.post(f"{PREFIX}/generate-plan", json=BODY, headers={"Idempotency-Key": key})
    assert r.status_code == 409


def test_async_job_same_key_enqueued_once(client, monkeypatch):
    """Поєднання з бонусом 6: повтор POST /plan-jobs не ставить друге завдання в чергу."""
    sent = []
    monkeypatch.setattr(jobs_queue, "QUEUE_URL", "https://sqs.test/queue")
    monkeypatch.setattr(jobs_queue, "send", lambda job_id: sent.append(job_id))
    key = str(uuid.uuid4())
    before = jobs_in_db()

    r1 = client.post(f"{PREFIX}/plan-jobs", json=BODY, headers={"Idempotency-Key": key})
    r2 = client.post(f"{PREFIX}/plan-jobs", json=BODY, headers={"Idempotency-Key": key})

    assert r1.status_code == r2.status_code == 202
    assert r1.json() == r2.json()
    assert r1.headers["Location"] == r2.headers["Location"] == r1.json()["status_url"]
    assert len(sent) == 1
    assert jobs_in_db() == before + 1
