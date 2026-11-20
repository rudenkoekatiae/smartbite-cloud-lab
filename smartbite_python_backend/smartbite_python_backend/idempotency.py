"""
SmartBite — ідемпотентність операцій запису за заголовком Idempotency-Key (бонус 7).

Перший запит із ключем виконується, його відповідь зберігається в Redis на 24 години.
Повторний запит із тим самим ключем отримує збережену відповідь без повторного
виконання (заголовок відповіді `Idempotent-Replayed: true`).

Стан ключа в Redis (`idem:<scope>:<key>`):
  {"state": "processing", "fp": ...}                  — перший запит ще виконується
  {"state": "done", "fp": ..., "status": 200, "body": ...} — готова відповідь

Захоплення ключа — атомарний `SET NX`: з двох одночасних однакових запитів
виконується лише один, другий отримує 409 і повторює пізніше.
`fp` — відбиток тіла запиту: той самий ключ з іншим тілом — помилка клієнта (422).
"""

import hashlib
import json
import logging
from typing import Any, Callable, Optional

import redis
from fastapi import HTTPException
from fastapi.responses import JSONResponse

import cache

log = logging.getLogger("smartbite.idempotency")

TTL_SECONDS = 24 * 60 * 60
PROCESSING_TTL_SECONDS = 60  # якщо процес упав посеред виконання — ключ звільниться сам


def _fingerprint(payload: dict) -> str:
    return hashlib.sha256(json.dumps(payload, sort_keys=True, default=str).encode()).hexdigest()


def run(
    scope: str,
    key: Optional[str],
    payload: dict,
    action: Callable[[], tuple[int, Any]],
) -> JSONResponse:
    """Виконати action() рівно один раз для пари (scope, key).

    action повертає (status_code, body). Без ключа або без Redis — просто виконує.
    """
    r = cache.client()
    if not key or r is None:
        status, body = action()
        return JSONResponse(body, status_code=status)

    if len(key) > 255:
        raise HTTPException(status_code=400, detail="Idempotency-Key is too long (max 255)")

    rkey = f"idem:{scope}:{key}"
    fp = _fingerprint(payload)

    try:
        acquired = r.set(rkey, json.dumps({"state": "processing", "fp": fp}), nx=True, ex=PROCESSING_TTL_SECONDS)
    except redis.RedisError as exc:
        # Redis недоступний: краще виконати запит, ніж відмовити (fail-open).
        # Ціна — у цей момент дублікат можливий; див. docs/IDEMPOTENCY.md.
        log.warning("idempotency store unavailable: %s", exc)
        status, body = action()
        return JSONResponse(body, status_code=status)

    if not acquired:
        stored = json.loads(r.get(rkey) or "{}")
        if stored.get("fp") != fp:
            raise HTTPException(
                status_code=422,
                detail="Idempotency-Key was already used with a different request body",
            )
        if stored.get("state") != "done":
            raise HTTPException(
                status_code=409,
                detail="A request with this Idempotency-Key is still being processed; retry later",
            )
        return JSONResponse(
            stored["body"],
            status_code=stored["status"],
            headers={"Idempotent-Replayed": "true"},
        )

    try:
        status, body = action()
    except Exception:
        # Запит не виконався (помилка валідації, збій бази) — звільняємо ключ,
        # щоб клієнт міг повторити з тим самим ключем.
        r.delete(rkey)
        raise

    r.set(
        rkey,
        json.dumps({"state": "done", "fp": fp, "status": status, "body": body}, default=str),
        ex=TTL_SECONDS,
    )
    return JSONResponse(body, status_code=status)
