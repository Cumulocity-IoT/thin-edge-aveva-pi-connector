FROM mcr.microsoft.com/devcontainers/python:3.13

# Install system dependencies including QEMU and network utilities for Lima
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        unixodbc \
        unixodbc-dev \
        build-essential \
        curl \
        ca-certificates \
        qemu-system-x86 \
        qemu-utils \
        iptables \
    && rm -rf /var/lib/apt/lists/*

# Install just command runner
RUN curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to /usr/local/bin

# Install Lima (limactl)
RUN LIMA_VERSION=$(curl -s https://api.github.com/repos/lima-vm/lima/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/') \
    && curl -fsSL "https://github.com/lima-vm/lima/releases/download/v${LIMA_VERSION}/lima-${LIMA_VERSION}-Linux-x86_64.tar.gz" | tar -C /usr/local -xz

# Pre-create log directory used by start-tedge.sh (runs as non-root vscode user)
RUN mkdir -p /var/log/tedge && chown vscode:vscode /var/log/tedge && chmod 755 /var/log/tedge

WORKDIR /workspaces

CMD ["sleep", "infinity"]