FROM python:3.11-slim

# ffmpeg/ffprobe: generate a real, playable test video and probe its duration.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg iproute2 net-tools \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY stream_server.py /app/stream_server.py

# Bake a 120s test-pattern video (video timer + audio tone) into the image so
# the demo is fully self-contained and the client-side save is genuinely playable.
RUN mkdir -p /media \
    && ffmpeg -hide_banner -loglevel error \
        -f lavfi -i testsrc=size=640x360:rate=25:duration=120 \
        -f lavfi -i sine=frequency=1000:duration=120 \
        -c:v libx264 -preset veryfast -pix_fmt yuv420p \
        -c:a aac -shortest /media/sample.mp4 \
    && ls -l /media/sample.mp4

ENV PORT=9000 \
    MEDIA=/media/sample.mp4 \
    STREAM_SECONDS=90

EXPOSE 9000
CMD ["python3", "-u", "stream_server.py"]
