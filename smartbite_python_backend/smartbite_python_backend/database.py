"""
SmartBite — шар роботи з базою даних (PostgreSQL через SQLAlchemy).

Рядок підключення береться ТІЛЬКИ зі змінної середовища DATABASE_URL:
  - локально її задає compose.yaml;
  - у хмарі ECS підставляє її з SSM Parameter Store (SecureString).
У коді, образі та репозиторії пароля немає.
"""

import os
import time
from datetime import datetime
from typing import Any, Iterator, Optional

from sqlalchemy import DateTime, Float, Integer, JSON, String, create_engine, func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column, sessionmaker

DATABASE_URL = os.getenv("DATABASE_URL")
if not DATABASE_URL:
    raise RuntimeError(
        "DATABASE_URL is not set. Example: "
        "postgresql+psycopg://user:password@host:5432/dbname"
    )

# pool_pre_ping перевіряє з'єднання перед використанням: якщо база
# перезапустилась, застосунок прозоро відкриє нове з'єднання.
engine = create_engine(DATABASE_URL, pool_pre_ping=True, pool_size=5, max_overflow=5)
SessionLocal = sessionmaker(bind=engine, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


class MealPlan(Base):
    """Збережений план харчування: параметри запиту, підсумки і повний результат."""

    __tablename__ = "meal_plans"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), index=True
    )
    week_budget_uah: Mapped[float] = mapped_column(Float)
    daily_cal_target: Mapped[float] = mapped_column(Float)
    meals_per_day: Mapped[int] = mapped_column(Integer)
    days: Mapped[int] = mapped_column(Integer)
    total_cost_uah: Mapped[float] = mapped_column(Float)
    total_cal: Mapped[float] = mapped_column(Float)
    # JSONB у PostgreSQL; звичайний JSON в інших СУБД
    result: Mapped[dict[str, Any]] = mapped_column(JSON().with_variant(JSONB, "postgresql"))


def make_meal_plan(params: dict[str, Any], result: dict[str, Any]) -> "MealPlan":
    """Запис плану з параметрів запиту і результату solve_week (спільне для API і worker)."""
    return MealPlan(
        week_budget_uah=params["week_budget_uah"],
        daily_cal_target=params["daily_cal_target"],
        meals_per_day=params["meals_per_day"],
        days=params["days"],
        total_cost_uah=result["weekly_totals"]["cost_est"],
        total_cal=result["weekly_totals"]["cal"],
        result=result,
    )


class PlanJob(Base):
    """Асинхронне завдання на генерацію плану (бонус 6).

    Життєвий цикл: queued → processing → done | failed.
    API створює запис і кладе job_id у чергу SQS; обробник (worker.py) виконує.
    """

    __tablename__ = "plan_jobs"

    id: Mapped[str] = mapped_column(String(32), primary_key=True)  # uuid4().hex
    status: Mapped[str] = mapped_column(String(16), default="queued", index=True)
    params: Mapped[dict[str, Any]] = mapped_column(JSON().with_variant(JSONB, "postgresql"))
    plan_id: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    error: Mapped[Optional[str]] = mapped_column(String(500), nullable=True)
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    # Коли обробник «взяв» завдання. Якщо він упав, через CLAIM_TIMEOUT інший може взяти знову.
    claimed_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    finished_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)


def init_db(attempts: int = 10, delay_s: float = 3.0) -> None:
    """Створює таблиці, якщо їх ще немає. Чекає, поки база стане доступною."""
    for attempt in range(1, attempts + 1):
        try:
            Base.metadata.create_all(engine)
            return
        except OperationalError:
            if attempt == attempts:
                raise
            print(f"Database is not ready (attempt {attempt}/{attempts}), retrying...", flush=True)
            time.sleep(delay_s)


def get_session() -> Iterator[Session]:
    """FastAPI-залежність: одна сесія на запит, закривається після відповіді."""
    with SessionLocal() as session:
        yield session
