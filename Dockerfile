# ZIMA DISK STATION — image pour ZimaOS (utilisée seulement si Python n'est pas sur le système)
FROM python:3.12-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends smartmontools util-linux \
 && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir pillow
WORKDIR /app
COPY ecran-disques.py /app/
COPY polices /app/polices
ENV PYTHONUNBUFFERED=1
CMD ["python3", "/app/ecran-disques.py"]
