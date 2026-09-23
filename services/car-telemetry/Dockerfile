FROM python:3.12-slim

WORKDIR /srv

ENV PYTHONUNBUFFERED=1
ENV CAR_TELEMETRY_DB=/data/telemetry.db
ENV PORT=8080

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY static ./static
RUN chmod -R a+rX /srv

RUN useradd --uid 1000 --no-create-home --shell /usr/sbin/nologin appuser
USER 1000

EXPOSE 8080
CMD ["python", "-m", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
