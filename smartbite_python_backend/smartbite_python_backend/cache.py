"""
SmartBite — кеш операцій читання (cache-aside) у спільному Redis.

Налаштування зі змінних середовища:
  REDIS_URL          redis://host:6379/0; не задано — кеш вимкнено
  CACHE_ENABLED      true/false — глобальний вимикач (за замовчуванням true)
  CACHE_TTL_SECONDS  термін дії запису, секунди (за замовчуванням 30)

Кеш — необов'язковий шар: якщо Redis недоступний, застосунок не падає,
а читає з бази (fail-open). Таймаути короткі, щоб збій Redis не додавав
секунди до кожного запиту.
"""

import json
import logging
import os
from typing import Any, Optional

import redis

log = logging.getLogger("smartbite.cache")

REDIS_URL = os.getenv("REDIS_URL")
CACHE_ENABLED = os.getenv("CACHE_ENABLED", "true").lower() == "true" and bool(REDIS_URL)
CACHE_TTL_SECONDS = int(os.getenv("CACHE_TTL_SECONDS", "30"))

# Клієнт є завжди, коли задано REDIS_URL: ним користуються і кеш, і ідемпотентність
# (idempotency.py). CACHE_ENABLED вимикає лише кешування списку планів.
_client: Optional[redis.Redis] = (
    redis.Redis.from_url(
        REDIS_URL,
        socket_timeout=0.2,
        socket_connect_timeout=0.2,
        decode_responses=True,
    )
    if REDIS_URL
    else None
)


def client() -> Optional[redis.Redis]:
    return _client


def get_json(key: str) -> Optional[Any]:
    """Значення з кешу або None (немає ключа, TTL сплив, Redis недоступний)."""
    if _client is None:
        return None
    try:
        raw = _client.get(key)
    except redis.RedisError as exc:
        log.warning("cache get failed: %s", exc)
        return None
    return None if raw is None else json.loads(raw)


def set_json(key: str, value: Any, ttl: int = CACHE_TTL_SECONDS) -> None:
    """Записати значення з терміном дії ttl секунд (SET key value EX ttl)."""
    if _client is None:
        return
    try:
        _client.set(key, json.dumps(value), ex=ttl)
    except redis.RedisError as exc:
        log.warning("cache set failed: %s", exc)


def record(outcome: str) -> None:
    """Лічильник HIT/MISS у Redis — спільний для всіх екземплярів."""
    if _client is None:
        return
    try:
        _client.incr(f"stats:{outcome}")
    except redis.RedisError:
        pass


def stats() -> dict:
    if _client is None or not CACHE_ENABLED:
        return {"enabled": False}
    try:
        hits = int(_client.get("stats:hit") or 0)
        misses = int(_client.get("stats:miss") or 0)
    except redis.RedisError as exc:
        return {"enabled": True, "error": str(exc)}
    total = hits + misses
    return {
        "enabled": True,
        "ttl_seconds": CACHE_TTL_SECONDS,
        "hits": hits,
        "misses": misses,
        "hit_ratio": round(hits / total, 4) if total else None,
    }


def reset_stats() -> None:
    if _client is not None:
        try:
            _client.delete("stats:hit", "stats:miss")
        except redis.RedisError:
            pass
