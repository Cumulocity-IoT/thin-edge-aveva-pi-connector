FROM mcr.microsoft.com/devcontainers/python:3.13

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        unixodbc \
        unixodbc-dev \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

# Pre-create log directory used by start-tedge.sh (runs as non-root vscode user)
RUN mkdir -p /var/log/tedge && chown vscode:vscode /var/log/tedge && chmod 755 /var/log/tedge

WORKDIR /workspaces

CMD ["sleep", "infinity"]
