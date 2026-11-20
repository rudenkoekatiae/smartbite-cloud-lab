"""
SmartBite — обробник черги генерації планів (бонус 6).

Запуск: python worker.py (той самий образ, що й API, інша команда).

Цикл: прочитати повідомлення з SQS → виконати завдання → видалити повідомлення.
SQS гарантує доставку «щонайменше один раз»: якщо обробник упав або не встиг
видалити повідомлення до кінця visibility timeout, його отримає повторно
(можливо, інший екземпляр). Тому обробка ідемпотентна:
  * завдання «захоплюється» умовним UPDATE — лише один обробник за раз;
  * план і статус done пишуться в одній транзакції;
  * повторне повідомлення для done-завдання просто видаляється.

SIGTERM (ECS зупиняє задачу при scale-in або деплої): дообробити поточне
повідомлення і вийти — graceful shutdown.
"""

import logging
import signal
import sys
from datetime import datetime, timedelta, timezone

from sqlalchemy import and_, or_, update

import jobs_queue
from database import PlanJob, SessionLocal, init_db, make_meal_plan
from meal_engine import solve_week

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", stream=sys.stdout)
log = logging.getLogger("smartbite.worker")

# Має бути меншим за visibility timeout черги (60 с): інакше повідомлення
# повернеться в чергу, поки завдання ще вважається «зайнятим».
CLAIM_TIMEOUT = timedelta(seconds=45)

_stopping = False


def _on_sigterm(signum, _frame):
    global _stopping
    log.info("signal %s: finishing current message and exiting", signum)
    _stopping = True


def process_job(job_id: str) -> str:
    """Виконати завдання. Повертає done | failed | duplicate | busy | missing."""
    now = datetime.now(timezone.utc)

    with SessionLocal() as session:
        # Атомарне захоплення: рядок оновиться лише якщо завдання ще в черзі
        # або попередній обробник «завис» довше за CLAIM_TIMEOUT.
        claimed = session.execute(
            update(PlanJob)
            .where(
                PlanJob.id == job_id,
                or_(
                    PlanJob.status == "queued",
                    and_(PlanJob.status == "processing", PlanJob.claimed_at < now - CLAIM_TIMEOUT),
                ),
            )
            .values(status="processing", claimed_at=now, attempts=PlanJob.attempts + 1)
        ).rowcount
        session.commit()

        if not claimed:
            job = session.get(PlanJob, job_id)
            if job is None:
                return "missing"
            if job.status in ("done", "failed"):
                return "duplicate"  # повторна доставка вже виконаного завдання
            return "busy"  # інший обробник саме виконує

        job = session.get(PlanJob, job_id)
        result = solve_week(**job.params)

        if result.get("status") != "ok":
            job.status = "failed"
            job.error = str(result.get("reason", "Unknown error"))[:500]
        else:
            plan = make_meal_plan(job.params, result)
            session.add(plan)
            session.flush()  # отримати plan.id
            job.plan_id = plan.id
            job.status = "done"
        job.finished_at = datetime.now(timezone.utc)
        session.commit()  # план і статус — одна транзакція
        return job.status


def main() -> None:
    if not jobs_queue.enabled():
        sys.exit("SQS_QUEUE_URL is not set")
    signal.signal(signal.SIGTERM, _on_sigterm)
    signal.signal(signal.SIGINT, _on_sigterm)
    init_db()
    log.info("worker started, queue %s", jobs_queue.QUEUE_URL)

    while not _stopping:
        for msg in jobs_queue.receive(max_messages=1, wait_seconds=10):
            job_id = jobs_queue.parse(msg)
            receives = msg.get("Attributes", {}).get("ApproximateReceiveCount", "1")
            if job_id is None:
                log.warning("malformed message, deleting: %s", msg.get("Body"))
                jobs_queue.delete(msg["ReceiptHandle"])
                continue
            try:
                outcome = process_job(job_id)
            except Exception:
                # Не видаляємо: після visibility timeout повідомлення повернеться,
                # після 3 невдалих спроб SQS перенесе його в dead-letter queue.
                log.exception("job %s failed (receive #%s), will be retried", job_id, receives)
                continue
            if outcome == "busy":
                continue  # хай повернеться пізніше
            jobs_queue.delete(msg["ReceiptHandle"])
            log.info("job %s: %s (receive #%s)", job_id, outcome, receives)

    log.info("worker stopped")


if __name__ == "__main__":
    main()
