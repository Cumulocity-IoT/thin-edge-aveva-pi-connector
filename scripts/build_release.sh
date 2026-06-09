#!/bin/bash
# build_release.sh — run on dev machine with internet access

set -euo pipefail

# Accept version as argument or prompt interactively
if [[ $# -ge 1 ]]; then
  VERSION="$1"
else
  read -rp "Enter release version (e.g. 0.0.4): " VERSION
  VERSION="${VERSION:-0.0.4}"
fi

IMAGE_NAME="pi_historian_connector:${VERSION}"
RELEASE_DIR="release/pi_historian_connector_${VERSION}"
TARBALL="pi_historian_connector_${VERSION}.tar.gz"
ONLINE_ZIP="pi_historian_connector_v${VERSION}_online.zip"
OFFLINE_ZIP="pi_historian_connector_v${VERSION}_offline.zip"

# ─────────────────────────────────────────────────────────
# Online ZIP — source files only, Docker image pulled at runtime
# ─────────────────────────────────────────────────────────
echo "🌐 Step 1: Build online ZIP (standard deploy)..."
zip "${ONLINE_ZIP}" \
    app.py \
    docker-compose.yaml \
    Dockerfile \
    logging.conf \
    requirements.txt

echo "✅ Online ZIP → ${ONLINE_ZIP}"

# ─────────────────────────────────────────────────────────
# Offline ZIP — Docker image tarball + wheels bundled
# ─────────────────────────────────────────────────────────
echo "📦 Step 2: Download pip packages as wheels (offline)..."
# Target Python 3.11 + Linux x86_64 to match the Docker base image (python:3.11-slim)
pip download -r requirements.txt -d ./packages/ \
    --python-version 3.11 \
    --platform manylinux2014_x86_64 \
    --only-binary=:all: \
    --implementation cp

echo "🐳 Step 3: Build Docker image..."
docker build -t ${IMAGE_NAME} .

echo "💾 Step 4: Export image to tarball..."
docker save ${IMAGE_NAME} | gzip > ${TARBALL}

echo "📁 Step 5: Package offline bundle..."
mkdir -p ${RELEASE_DIR}

# Copy static files
cp logging.conf \
   requirements.txt \
   ${TARBALL} \
   ${RELEASE_DIR}/

# Dynamically generate offline docker-compose.yaml from current project config
cat > ${RELEASE_DIR}/docker-compose.yaml <<EOF
services:
  historian_integration:
    # -----------------------------------------
    # OFFLINE: use pre-loaded image
    # Load on device first:
    #   docker load < ${TARBALL}
    # -----------------------------------------
    image: ${IMAGE_NAME}

    restart: unless-stopped

    extra_hosts:
      - "host.containers.internal:host-gateway"

    volumes:
      - /etc/tedge/c8y:/etc/tedge/c8y

    working_dir: /app
    command: ["python", "app.py"]
EOF

# Include pip wheels for offline pip installs
if [[ -d ./packages ]]; then
  cp -r ./packages ${RELEASE_DIR}/
fi

(cd ${RELEASE_DIR} && zip -r "../../${OFFLINE_ZIP}" .)

echo "✅ Offline ZIP → ${OFFLINE_ZIP}"

echo "🧹 Cleaning up temporary files..."
rm -rf ./packages ${TARBALL} ${RELEASE_DIR} ./release

echo ""
echo "✅ Done!"
echo "   Online  → ${ONLINE_ZIP}"
echo "   Offline → ${OFFLINE_ZIP}"
