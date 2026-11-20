FROM python:3.12-slim
COPY relay.py /app/relay.py
USER 65534:65534
ENV RELAY_DB=/data/relay.db RELAY_PORT=8000
CMD ["python", "-u", "/app/relay.py"]
