FROM python:3.11-slim
ENV PYTHONUNBUFFERED=1 MAX_UPLOAD_MB=500 CPU_THREADS=4
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg fonts-noto-core fontconfig && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py subtitle_utils.py .
RUN mkdir -p /app/data/jobs /app/data/models
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
