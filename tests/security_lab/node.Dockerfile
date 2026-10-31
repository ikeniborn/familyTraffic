FROM python:3.12-slim-bookworm
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bash ca-certificates curl fail2ban iproute2 iptables jq openssl ufw && rm -rf /var/lib/apt/lists/*
# UFW sysctl writes are unnecessary inside this disposable namespace.
RUN printf '' > /etc/ufw/sysctl.conf && sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
CMD ["sleep", "infinity"]
