FROM python:3.11-slim

# tcpdump pulls libpcap (used by scapy); iproute2/net-tools for inspection;
# dsniff provides arpspoof as an alternative to arp_spoof.py.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        tcpdump iproute2 net-tools iputils-ping dsniff procps \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir scapy

WORKDIR /app
COPY arp_spoof.py rst_attack.py attack.sh capture.sh /app/
RUN chmod +x /app/*.sh /app/*.py

ENV CLIENT_IP=172.20.0.20 \
    SERVER_IP=172.20.0.10 \
    SERVER_PORT=9000 \
    IFACE=eth0

# Stay alive; the operator execs the tools by hand to control timing.
CMD ["sleep", "infinity"]
