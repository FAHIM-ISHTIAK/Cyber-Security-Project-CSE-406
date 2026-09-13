FROM python:3.11-slim

# iproute2/net-tools/tcpdump: so you can inspect ss/netstat and confirm the
# connection entry disappears after the reset. ffmpeg is optional (to play the
# saved file); left out to keep the client image small.
RUN apt-get update \
    && apt-get install -y --no-install-recommends iproute2 net-tools tcpdump iputils-ping \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY stream_client.py /app/stream_client.py

ENV SERVER_IP=172.20.0.10 \
    SERVER_PORT=9000 \
    OUTFILE=/out/received.mp4

# Stay alive so the operator controls timing: exec the client by hand.
CMD ["sleep", "infinity"]
