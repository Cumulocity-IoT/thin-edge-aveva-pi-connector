#!/bin/bash
# build_release.sh — run on dev machine with internet access

set -euo pipefail

VERSION=${1:-0.0.4}
IMAGE_NAME="pi_historian_connector:${VERSION}"
RELEASE_DIR="release/pi_historian_connector_${VERSION}"
TARBALL="pi_historian_connector_${VERSION}.tar.gz"
ONLINE_ZIP="pi_historian_connector_v${VERSION}_online.zip"
AIRGAP_ZIP="pi_historian_connector_v${VERSION}_airgap.zip"

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
# Air-gap ZIP — Docker image tarball + wheels bundled
# ─────────────────────────────────────────────────────────
echo "📦 Step 2: Download pip packages as wheels (air-gap)..."
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

echo "📁 Step 5: Package air-gap bundle..."
mkdir -p ${RELEASE_DIR}

# Copy static files
cp logging.conf \
   requirements.txt \
   ${TARBALL} \
   ${RELEASE_DIR}/

# Dynamically generate airgap docker-compose.yaml from current project config
cat > ${RELEASE_DIR}/docker-compose.yaml <<EOF
services:
  historian_integration:
    # -----------------------------------------
    # AIR-GAP: use pre-loaded image
    # Load on device first:
    #   docker load < ${TARBALL}
    # -----------------------------------------
    image: ${IMAGE_NAME}

    restart: unless-stopped

    extra_hosts:
      - "host.containers.internal:host-gateway"

    volumes:
      - /etc/tedge/c8y:/etc/tedge/c8y
      - ./logs:/app/logs

    working_dir: /app
    command: ["python", "app.py"]
EOF

# Include pip wheels for offline pip installs
if [[ -d ./packages ]]; then
  cp -r ./packages ${RELEASE_DIR}/
fi

(cd ${RELEASE_DIR} && zip -r "../../${AIRGAP_ZIP}" .)

echo "✅ Air-gap ZIP → ${AIRGAP_ZIP}"

echo "🧹 Cleaning up temporary files..."
rm -rf ./packages ${TARBALL} ${RELEASE_DIR} ./release

echo ""
echo "✅ Done!"
echo "   Online  → ${ONLINE_ZIP}"
echo "   Air-gap → ${AIRGAP_ZIP}"
