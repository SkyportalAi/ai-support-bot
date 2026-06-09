FROM python:3.11-slim

WORKDIR /app

RUN pip install poetry==1.8.3 && \
    poetry config virtualenvs.create false

COPY pyproject.toml poetry.lock* ./
RUN poetry install --no-interaction --no-ansi --only main

RUN addgroup --system app && adduser --system --ingroup app app

COPY agent/ ./agent/
COPY static/ ./static/

USER app
EXPOSE 8000
CMD ["uvicorn", "agent.server:app", "--host", "0.0.0.0", "--port", "8000"]
