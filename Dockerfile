FROM python:3.11-slim

WORKDIR /app

RUN pip install poetry==1.8.3 && \
    poetry config virtualenvs.create false

COPY pyproject.toml poetry.lock* ./
RUN poetry install --no-interaction --no-ansi --only main

COPY agent/ ./agent/

ENV OLLAMA_BASE_URL=http://ollama:11434/v1

CMD ["python", "-m", "agent.main"]
