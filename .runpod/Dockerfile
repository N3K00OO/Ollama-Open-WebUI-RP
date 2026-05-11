FROM python:3.11-slim

WORKDIR /

ENV PYTHONUNBUFFERED=1
ENV PIP_ROOT_USER_ACTION=ignore

RUN pip install --no-cache-dir "runpod>=1.7,<2"

COPY .runpod/handler.py /handler.py
COPY .runpod/ci_smoke.py /ci_smoke.py

CMD ["python", "/handler.py"]
