FROM python:3.13-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 PYTHONPATH=/srv
WORKDIR /srv
COPY app/requirements.txt app/requirements.txt
RUN pip install -r app/requirements.txt
COPY app/detector detector
RUN useradd -r -u 10001 app
USER 10001
ENTRYPOINT ["python", "-m", "detector.main"]
