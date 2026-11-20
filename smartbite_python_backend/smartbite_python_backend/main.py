"""
SmartBite API v2
FastAPI backend with input validation.
"""

import json
import os
import uuid
from contextlib import asynccontextmanager
from fastapi import Depends, FastAPI, Header, HTTPException, Response
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, field_validator, model_validator
from sqlalchemy import select, text
from sqlalchemy.orm import Session
from typing import Optional

import cache
import idempotency
import jobs_queue
from database import MealPlan, PlanJob, get_session, init_db, make_meal_plan
from meal_engine import calc_daily_calories, solve_week, INGREDIENT_GRAPH
PREFIX = os.getenv("API_PREFIX", "/make-server-fd5d4174")
ALLOWED_ORIGINS = os.getenv("ALLOWED_ORIGINS", "*").split(",")
# Хеш коміту, з якого зібрано образ; підставляється під час деплою (CI/CD).
APP_VERSION = os.getenv("APP_VERSION", "dev")


@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()  # створює таблиці при старті, якщо їх ще немає
    yield


app = FastAPI(title="SmartBite API v2", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

class CaloriesRequest(BaseModel):
    sex: str
    age: int
    height_cm: float
    weight_kg: float
    goal: str

    @field_validator("sex")
    @classmethod
    def validate_sex(cls, v: str) -> str:
        if v.lower() not in ("m", "f"):
            raise ValueError("sex must be 'm' or 'f'")
        return v.lower()

    @field_validator("age")
    @classmethod
    def validate_age(cls, v: int) -> int:
        if not (10 <= v <= 120):
            raise ValueError("age must be between 10 and 120")
        return v

    @field_validator("height_cm")
    @classmethod
    def validate_height(cls, v: float) -> float:
        if not (100.0 <= v <= 250.0):
            raise ValueError("height_cm must be between 100 and 250")
        return v

    @field_validator("weight_kg")
    @classmethod
    def validate_weight(cls, v: float) -> float:
        if not (30.0 <= v <= 300.0):
            raise ValueError("weight_kg must be between 30 and 300")
        return v

    @field_validator("goal")
    @classmethod
    def validate_goal(cls, v: str) -> str:
        allowed = ("cut", "bulk", "maintain", "lose", "gain", "loss")
        if v.lower().strip() not in allowed:
            raise ValueError(f"goal must be one of: {allowed}")
        return v


class PlanRequest(BaseModel):
    week_budget_uah: float
    daily_cal_target: float
    meals_per_day: int = 3
    skip_meal: Optional[str] = None
    days: int = 7
    cal_tolerance: float = 150.0
    seed: Optional[int] = None

    @field_validator("week_budget_uah")
    @classmethod
    def validate_budget(cls, v: float) -> float:
        if v < 50:
            raise ValueError("week_budget_uah must be at least 50 UAH")
        if v > 50_000:
            raise ValueError("week_budget_uah seems unrealistically high (max 50000)")
        return v

    @field_validator("daily_cal_target")
    @classmethod
    def validate_calories(cls, v: float) -> float:
        if not (500 <= v <= 8000):
            raise ValueError("daily_cal_target must be between 500 and 8000 kcal")
        return v

    @field_validator("meals_per_day")
    @classmethod
    def validate_meals(cls, v: int) -> int:
        if v not in (2, 3, 4, 5):
            raise ValueError("meals_per_day must be 2, 3, 4 or 5")
        return v

    @field_validator("days")
    @classmethod
    def validate_days(cls, v: int) -> int:
        if not (1 <= v <= 14):
            raise ValueError("days must be between 1 and 14")
        return v

    @field_validator("skip_meal")
    @classmethod
    def validate_skip_meal(cls, v: Optional[str]) -> Optional[str]:
        if v is not None and v not in ("breakfast", "lunch", "dinner"):
            raise ValueError("skip_meal must be 'breakfast', 'lunch' or 'dinner'")
        return v


@app.get("/")
def root():
    return {
        "service": "SmartBite API",
        "version": APP_VERSION,
        "docs": "/docs",
        "api_prefix": PREFIX,
    }


# /health без префікса — для health check балансувальника: не звертається до бази,
# щоб короткий збій бази не призводив до перезапуску всіх екземплярів застосунку.
@app.get("/health")
@app.get(f"{PREFIX}/health")
def health():
    return {"status": "ok", "version": APP_VERSION}


@app.get(f"{PREFIX}/health/db")
def health_db(session: Session = Depends(get_session)):
    """Перевіряє, що застосунок бачить базу даних."""
    session.execute(text("SELECT 1"))
    return {"status": "ok", "database": "reachable"}


@app.post(f"{PREFIX}/calculate-calories")
def calculate_calories(body: CaloriesRequest):
    daily_calories = calc_daily_calories(
        body.sex, body.age, body.height_cm, body.weight_kg, body.goal
    )
    return {
        "daily_calories": daily_calories,
        "sex": body.sex,
        "age": body.age,
        "height_cm": body.height_cm,
        "weight_kg": body.weight_kg,
        "goal": body.goal,
    }


def _plan_summary(plan: MealPlan) -> dict:
    return {
        "id": plan.id,
        "created_at": plan.created_at.isoformat(),
        "week_budget_uah": plan.week_budget_uah,
        "daily_cal_target": plan.daily_cal_target,
        "meals_per_day": plan.meals_per_day,
        "days": plan.days,
        "total_cost_uah": plan.total_cost_uah,
        "total_cal": plan.total_cal,
    }


@app.post(f"{PREFIX}/generate-plan")
def generate_plan(
    body: PlanRequest,
    session: Session = Depends(get_session),
    idempotency_key: Optional[str] = Header(default=None),
):
    """Синхронна генерація: клієнт чекає, поки план буде готовий (200).

    Заголовок Idempotency-Key: повтор із тим самим ключем повертає збережену
    відповідь і не створює другий план (idempotency.py, бонус 7).
    """
    params = body.model_dump()

    def action():
        result = solve_week(**params)
        if result.get("status") != "ok":
            raise HTTPException(status_code=400, detail=result.get("reason", "Unknown error"))
        # Кожен згенерований план зберігається в базі даних.
        plan = make_meal_plan(params, result)
        session.add(plan)
        session.commit()
        return 200, {**result, "plan_id": plan.id}

    return idempotency.run("generate-plan", idempotency_key, params, action)


def _job_view(job: PlanJob) -> dict:
    view = {
        "job_id": job.id,
        "status": job.status,
        "status_url": f"{PREFIX}/plan-jobs/{job.id}",
        "plan_id": job.plan_id,
        "error": job.error,
    }
    if job.plan_id is not None:
        view["plan_url"] = f"{PREFIX}/plans/{job.plan_id}"
    return view


@app.post(f"{PREFIX}/plan-jobs", status_code=202)
def create_plan_job(
    body: PlanRequest,
    session: Session = Depends(get_session),
    idempotency_key: Optional[str] = Header(default=None),
):
    """Асинхронна генерація (бонус 6): завдання в чергу SQS, відповідь одразу — 202.

    Результат клієнт дізнається опитуванням GET /plan-jobs/{job_id}
    (адреса — у заголовку Location і полі status_url).
    """
    if not jobs_queue.enabled():
        raise HTTPException(status_code=503, detail="Job queue is not configured")
    params = body.model_dump()

    def action():
        job = PlanJob(id=uuid.uuid4().hex, status="queued", params=params)
        session.add(job)
        session.commit()  # спершу запис у базі: обробник не отримає «невідоме» завдання
        try:
            jobs_queue.send(job.id)
        except Exception as exc:
            job.status, job.error = "failed", f"enqueue failed: {exc}"[:500]
            session.commit()
            raise HTTPException(status_code=503, detail="Could not enqueue the job")
        return 202, _job_view(job)

    response = idempotency.run("plan-jobs", idempotency_key, params, action)
    response.headers["Location"] = json.loads(response.body)["status_url"]
    return response


@app.get(f"{PREFIX}/plan-jobs/{{job_id}}")
def get_plan_job(job_id: str, session: Session = Depends(get_session)):
    job = session.get(PlanJob, job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Job not found")
    return _job_view(job)


@app.get(f"{PREFIX}/plans")
def list_plans(
    response: Response,
    limit: int = 50,
    offset: int = 0,
    session: Session = Depends(get_session),
    x_cache_bypass: Optional[str] = Header(default=None),
):
    """Список збережених планів (без повного вмісту), найновіші першими.

    Найнавантаженіша операція читання, тому — cache-aside:
      1) шукаємо в Redis; є і TTL не сплив → повертаємо (X-Cache: HIT);
      2) інакше читаємо з бази, кладемо в Redis на CACHE_TTL_SECONDS (X-Cache: MISS).
    Заголовок `X-Cache-Bypass: 1` — прогін «без кешу» без передеплою (docs/CACHE.md).
    """
    limit = max(1, min(limit, 200))
    offset = max(0, offset)
    use_cache = cache.CACHE_ENABLED and x_cache_bypass != "1"
    key = f"plans:list:{limit}:{offset}"

    if use_cache:
        cached = cache.get_json(key)
        if cached is not None:
            cache.record("hit")
            response.headers["X-Cache"] = "HIT"
            return cached

    plans = session.scalars(
        select(MealPlan).order_by(MealPlan.id.desc()).limit(limit).offset(offset)
    ).all()
    body = {"plans": [_plan_summary(p) for p in plans]}

    if use_cache:
        cache.set_json(key, body)
        cache.record("miss")
        response.headers["X-Cache"] = "MISS"
    else:
        response.headers["X-Cache"] = "BYPASS"
    return body


@app.get(f"{PREFIX}/cache/stats")
def cache_stats():
    """Частка влучань у кеш, спільна для всіх екземплярів."""
    return cache.stats()


@app.delete(f"{PREFIX}/cache/stats", status_code=204)
def cache_stats_reset():
    cache.reset_stats()
    return Response(status_code=204)


@app.get(f"{PREFIX}/plans/{{plan_id}}")
def get_plan(plan_id: int, session: Session = Depends(get_session)):
    """Збережений план повністю."""
    plan = session.get(MealPlan, plan_id)
    if plan is None:
        raise HTTPException(status_code=404, detail="Plan not found")
    return {**_plan_summary(plan), "result": plan.result}


@app.delete(f"{PREFIX}/plans/{{plan_id}}", status_code=204)
def delete_plan(plan_id: int, session: Session = Depends(get_session)):
    plan = session.get(MealPlan, plan_id)
    if plan is None:
        raise HTTPException(status_code=404, detail="Plan not found")
    session.delete(plan)
    session.commit()
    return Response(status_code=204)


@app.get(f"{PREFIX}/ingredients")
def get_ingredients():
    """Returns the ingredient graph (replaces separate recipes + products endpoints)."""
    return {"ingredients": INGREDIENT_GRAPH}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)