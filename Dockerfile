# ---- Stage 1 : builder — installe les dépendances dans un venv isolé ----
FROM python:3.12-slim AS builder

ENV VIRTUAL_ENV=/opt/venv
RUN python -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ---- Stage 2 : runtime — slim, sans outils de build ni cache pip ----
FROM python:3.12-slim

LABEL org.opencontainers.image.source="https://github.com/LouisBertin40/AteliersDevOps"

# SHA du commit injecté au build (docker build --build-arg GIT_SHA=...)
ARG GIT_SHA=unknown
ENV GIT_SHA=$GIT_SHA

# Les ENV du stage builder ne survivent pas : on redéclare le PATH du venv
ENV VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN useradd --create-home --uid 1000 appuser
WORKDIR /app

COPY --from=builder /opt/venv /opt/venv
COPY --chown=appuser:appuser app.py .

USER appuser

EXPOSE 5000

# Pas de curl dans l'image slim : on utilise Python lui-même
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3   CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=2).status == 200 else 1)"

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "app:app"]
