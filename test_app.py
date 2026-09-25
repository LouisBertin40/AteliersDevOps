from app import alert_threshold, sanitize_input, app


def test_alert_threshold():
    assert alert_threshold() == 25


def test_sanitize_input_escapes_html():
    assert sanitize_input("<script>") == "&lt;script&gt;"


def test_health_endpoint():
    client = app.test_client()
    response = client.get("/health")
    assert response.status_code == 200
    assert response.get_json()["status"] == "ok"


def test_status_endpoint():
    client = app.test_client()
    response = client.get("/status")
    assert response.status_code == 200
    data = response.get_json()
    assert data["service"] == "projet-devops-groupe-demo"
    assert data["version"] == "1.0"


class FakeRedis:
    def __init__(self):
        self.store = {}

    def incr(self, key):
        self.store[key] = self.store.get(key, 0) + 1
        return self.store[key]


def test_visits_endpoint_increments(monkeypatch):
    fake = FakeRedis()
    monkeypatch.setattr("app.get_redis_client", lambda: fake)
    client = app.test_client()
    assert client.get("/visits").get_json()["visits"] == 1
    assert client.get("/visits").get_json()["visits"] == 2
