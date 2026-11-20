"""
SmartBite — черга завдань Amazon SQS (бонус 6).

SQS_QUEUE_URL задає Terraform (terraform/queue.tf). Без нього асинхронний
ендпоінт відповідає 503, а синхронний POST /generate-plan працює як раніше.
Облікові дані boto3 бере з ролі задачі ECS (task role) — ключів у коді немає.
"""

import json
import os
import threading
from typing import Optional

import boto3

QUEUE_URL = os.getenv("SQS_QUEUE_URL")

_client = None
_lock = threading.Lock()


def enabled() -> bool:
    return bool(QUEUE_URL)


def client():
    global _client
    with _lock:
        if _client is None:
            _client = boto3.client("sqs")
        return _client


def send(job_id: str) -> None:
    client().send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps({"job_id": job_id}))


def receive(max_messages: int = 1, wait_seconds: int = 10) -> list[dict]:
    resp = client().receive_message(
        QueueUrl=QUEUE_URL,
        MaxNumberOfMessages=max_messages,
        WaitTimeSeconds=wait_seconds,  # long polling: не платимо за порожні запити
        AttributeNames=["ApproximateReceiveCount"],
    )
    return resp.get("Messages", [])


def delete(receipt_handle: str) -> None:
    client().delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=receipt_handle)


def parse(message: dict) -> Optional[str]:
    try:
        return json.loads(message["Body"])["job_id"]
    except (KeyError, ValueError, TypeError):
        return None
