FROM mcr.microsoft.com/devcontainers/python:3.13

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        unixodbc \
        unixodbc-dev \
        build-essential \
    && curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Pre-create log directory used by start-tedge.sh (runs as non-root vscode user)
RUN mkdir -p /var/log/tedge && chmod 777 /var/log/tedge

WORKDIR /workspaces

CMD ["sleep", "infinity"]
