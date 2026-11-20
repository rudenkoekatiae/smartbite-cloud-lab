"""
Бонус 6: асинхронна обробка. SQS доставляє «щонайменше один раз», тому
повторна доставка того самого повідомлення не повинна створити другий план.
"""

from sqlalchemy import func, select

import jobs_queue
import worker
from conftest import PREFIX
from database import MealPlan, SessionLocal

BODY = {"week_budget_uah": 1500, "daily_cal_target": 2000, "seed": 7}


def plans_in_db() -> int:
    with SessionLocal() as s:
        return s.scalar(select(func.count()).select_from(MealPlan))


def test_job_lifecycle_and_duplicate_delivery(client, monkeypatch):
    sent = []
    monkeypatch.setattr(jobs_queue, "QUEUE_URL", "https://sqs.test/queue")
    monkeypatch.setattr(jobs_queue, "send", lambda job_id: sent.append(job_id))

    r = client.post(f"{PREFIX}/plan-jobs", json=BODY)
    assert r.status_code == 202
    job_id = r.json()["job_id"]
    assert client.get(f"{PREFIX}/plan-jobs/{job_id}").json()["status"] == "queued"

    before = plans_in_db()
    assert worker.process_job(sent[0]) == "done"
    assert worker.process_job(sent[0]) == "duplicate"  # повторна доставка
    assert plans_in_db() == before + 1

    job = client.get(f"{PREFIX}/plan-jobs/{job_id}").json()
    assert job["status"] == "done"
    assert client.get(job["plan_url"]).status_code == 200


def test_unknown_job_is_dropped():
    assert worker.process_job("0" * 32) == "missing"


def test_queue_not_configured_returns_503(client, monkeypatch):
    monkeypatch.setattr(jobs_queue, "QUEUE_URL", None)
    assert client.post(f"{PREFIX}/plan-jobs", json=BODY).status_code == 503
