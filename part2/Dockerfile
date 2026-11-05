FROM debian:13-slim

# ruby : interpréteur, iproute2 : ip et ss, procps : ps, systemd : systemctl
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ruby \
        iproute2 \
        procps \
        systemd \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY audit.rb /app/audit.rb

EXPOSE 9100

# Les arguments de "command" (compose.yaml) sont transmis à audit.rb
ENTRYPOINT ["ruby", "/app/audit.rb"]