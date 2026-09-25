FROM python:3.12

WORKDIR /app

# Dépendances d'abord (cache de couche), en root
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Utilisateur applicatif créé et activé APRÈS les installations qui nécessitent root
RUN useradd --create-home --uid 1000 appuser
USER appuser

EXPOSE 5000
CMD ["flask", "--app", "app", "run", "--host=0.0.0.0", "--port=5000"]
