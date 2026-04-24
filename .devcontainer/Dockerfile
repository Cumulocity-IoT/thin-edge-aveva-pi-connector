FROM mcr.microsoft.com/devcontainers/python:3.13

# Install additional OS packages if needed
RUN apt-get update && apt-get install -y \
    unixodbc \
    unixodbc-dev \
    gcc \
    g++ \
    curl \
    gnupg \
    build-essential \
    && rm -rf /var/lib/apt/lists/*
