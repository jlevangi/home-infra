FROM python:3.14-slim

WORKDIR /srv
COPY app ./app
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin netboxsync
USER 10001

CMD ["python", "-m", "app.main"]
