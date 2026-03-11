FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY webui.py .
COPY templates/ ./templates/
RUN useradd -m -u 1000 appuser && chown -R appuser:appuser /app
USER appuser

EXPOSE 5003

CMD ["gunicorn", "--bind", "0.0.0.0:5003", "--workers", "4", "--threads", "2", "--timeout", "120", "webui:app"]
