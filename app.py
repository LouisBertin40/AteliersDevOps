import os
import time

import redis
from flask import Flask, g, jsonify, request
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

app = Flask(__name__)

ALERT_THRESHOLD = 25

REQUEST_COUNT = Counter(
    "http_requests_total",
    "Nombre total de requetes HTTP",
    ["method", "endpoint", "status"],
)


REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "Duree de traitement des requetes HTTP",
    ["method", "endpoint"],
)


def alert_threshold():
    """Seuil d'alerte au-dessus duquel une notification est declenchee."""
    return ALERT_THRESHOLD


def sanitize_input(value):
    """Echappe les caracteres dangereux d'une entree utilisateur."""
    return value.replace("<", "&lt;").replace(">", "&gt;")


def get_redis_client():
    """Cree un client Redis a partir des variables d'environnement."""
    return redis.Redis(
        host=os.environ.get("REDIS_HOST", "localhost"),
        port=int(os.environ.get("REDIS_PORT", "6379")),
        decode_responses=True,
        socket_connect_timeout=2,
        socket_timeout=2,
    )


@app.before_request
def start_timer():
    g.start_time = time.perf_counter()


@app.after_request
def count_request(response):
    # /metrics exclu : sinon chaque scrape Prometheus s'auto-compte
    if request.path != "/metrics":
        endpoint = request.url_rule.rule if request.url_rule else "unmatched"
        REQUEST_COUNT.labels(request.method, endpoint, str(response.status_code)).inc()
        start = g.get("start_time")
        if start is not None:
            REQUEST_LATENCY.labels(request.method, endpoint).observe(time.perf_counter() - start)
    return response


@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


@app.route("/health")
def health():
    """Healthcheck reel : verifie que Redis repond, 503 sinon."""
    try:
        get_redis_client().ping()
    except redis.RedisError as exc:
        return jsonify(status="error", redis="unreachable", detail=str(exc)), 503
    return jsonify(status="ok", redis="ok"), 200


@app.route("/status")
def status():
    return jsonify(
        service="projet-devops-groupe-demo",
        version="1.0",
        deploy_color=os.environ.get("DEPLOY_COLOR", "none"),
        commit=os.environ.get("GIT_SHA", "unknown"),
    ), 200


@app.route("/visits")
def visits():
    count = get_redis_client().incr("visits")
    return jsonify(visits=count), 200


@app.route("/simulate-error")
def simulate_error():
    return jsonify(status="error", detail="erreur simulee"), 500


if __name__ == "__main__":
    app.run(debug=True)
