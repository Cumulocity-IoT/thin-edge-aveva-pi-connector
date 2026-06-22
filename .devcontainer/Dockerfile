FROM mcr.microsoft.com/devcontainers/python:3.13

RUN apt-get update && apt-get install -y --no-install-recommends \
    unixodbc \
    unixodbc-dev \
    gcc \
    g++ \
    curl \
    gnupg \
    build-essential \
    mosquitto \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js LTS (includes npm)
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

COPY systemctl-mock.sh /usr/local/bin/systemctl
RUN chmod +x /usr/local/bin/systemctl

RUN mkdir -p /var/log && \
    touch /var/log/mosquitto.log \
          /var/log/tedge-mapper.log \
          /var/log/tedge-agent.log \
          /var/log/tedge-watchdog.log && \
    chmod 666 /var/log/mosquitto.log \
              /var/log/tedge-mapper.log \
              /var/log/tedge-agent.log \
              /var/log/tedge-watchdog.log

WORKDIR /workspaces

# Keep container alive — devcontainer CLI overrides this with its own
# keep-alive when overrideCommand is true (default), but this is a safe fallback
CMD ["sleep", "infinity"]