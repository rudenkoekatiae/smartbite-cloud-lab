# Базовий образ із зафіксованою версією Python і дистрибутива (не latest).
FROM python:3.13.5-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Непривілейований користувач: процес у контейнері не працює від root.
RUN groupadd --system --gid 1001 app \
 && useradd --system --uid 1001 --gid app --no-create-home app

# Залежності — окремим шаром ДО копіювання коду: поки requirements.txt
# не змінився, Docker бере цей шар із кешу і не перевстановлює пакети.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Код змінюється найчастіше, тому копіюється останнім.
COPY main.py meal_engine.py database.py cache.py ingredient_graph.json ./

USER 1001:1001

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
