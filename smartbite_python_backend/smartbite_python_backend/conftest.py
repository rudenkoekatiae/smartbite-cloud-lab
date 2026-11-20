"""Спільне налаштування тестів: SQLite замість PostgreSQL і Redis у пам'яті (fakeredis)."""

import os
import tempfile

# Має бути задано ДО імпорту database.py, який читає DATABASE_URL при імпорті.
_db_file = os.path.join(tempfile.mkdtemp(prefix="smartbite-test-"), "test.db")
os.environ.setdefault("DATABASE_URL", f"sqlite:///{_db_file}")
os.environ.pop("REDIS_URL", None)
os.environ.pop("SQS_QUEUE_URL", None)

import fakeredis  # noqa: E402
import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import cache  # noqa: E402
import main  # noqa: E402

PREFIX = main.PREFIX


@pytest.fixture
def redis_fake(monkeypatch):
    fake = fakeredis.FakeRedis(decode_responses=True)
    monkeypatch.setattr(cache, "_client", fake)
    return fake


@pytest.fixture
def client(redis_fake):
    with TestClient(main.app) as c:  # lifespan → init_db() створює таблиці
        yield c
