# content-api — multi-stage: wheels are built in the builder, the runtime layer
# gets only the installed packages. slim (not alpine) because manylinux wheels
# for pydantic-core install straight off the shelf on glibc.
FROM python:3.12-slim AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build
COPY requirements.txt .
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade pip \
    && /opt/venv/bin/pip install -r requirements.txt


FROM python:3.12-slim AS runtime

# Non-root from the start: the deployment also sets runAsNonRoot, which fails
# closed if the image has no numeric USER.
RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --no-create-home app

# Stamped by CI with the git SHA so the running pod can report exactly what it
# is. Baked in rather than passed as env — the manifest can then never disagree
# with the image.
ARG APP_VERSION=0.1.0

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    APP_VERSION=${APP_VERSION}

COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
COPY --chown=app:app app ./app

USER 10001
EXPOSE 8000

# One worker per pod — scale with replicas, not with in-pod workers, so the HPA
# and the scheduler see the real unit of capacity.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--no-server-header"]
