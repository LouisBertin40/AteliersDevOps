FROM python:3.12

WORKDIR /app
COPY . .
RUN pip install -r requirements.txt

EXPOSE 5000
# --host=0.0.0.0 : sinon Flask écoute sur 127.0.0.1 et reste injoignable depuis l'hôte
CMD ["flask", "--app", "app", "run", "--host=0.0.0.0", "--port=5000"]
