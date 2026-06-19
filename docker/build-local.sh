#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# Local Docker build for RyamosThomas/immich fork
# Builds server + machine-learning images and optionally pushes
# ──────────────────────────────────────────────────────────────

DOCKERHUB_USER="${DOCKERHUB_USER:-kidfearless}"
TAG="${1:-dev}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Building Immich locally ==="
echo "  Repo root:  ${REPO_ROOT}"
echo "  Tag:        ${TAG}"
echo "  Docker Hub: ${DOCKERHUB_USER}/immich-server:${TAG}"
echo "              ${DOCKERHUB_USER}/immich-machine-learning:${TAG}"
echo ""

# ── Server image ─────────────────────────────────────────────
echo ">>> Building immich-server..."
docker build \
  -t "${DOCKERHUB_USER}/immich-server:${TAG}" \
  -f "${REPO_ROOT}/server/Dockerfile" \
  "${REPO_ROOT}"

echo ">>> ✓ immich-server:${TAG} built successfully"
echo ""

# ── Machine-learning image (CPU) ─────────────────────────────
echo ">>> Building immich-machine-learning (cpu)..."
docker build \
  -t "${DOCKERHUB_USER}/immich-machine-learning:${TAG}" \
  -f "${REPO_ROOT}/machine-learning/Dockerfile" \
  --build-arg DEVICE=cpu \
  "${REPO_ROOT}/machine-learning"

echo ">>> ✓ immich-machine-learning:${TAG} built successfully"
echo ""

# ── Summary ──────────────────────────────────────────────────
echo "=== Build complete ==="
echo ""
echo "Images:"
docker images --format "  {{.Repository}}:{{.Tag}}  ({{.Size}})" \
  | grep "${DOCKERHUB_USER}/immich"
echo ""
echo "To push to Docker Hub:"
echo "  docker push ${DOCKERHUB_USER}/immich-server:${TAG}"
echo "  docker push ${DOCKERHUB_USER}/immich-machine-learning:${TAG}"
echo ""
echo "To update docker-compose.yml, set IMMICH_VERSION=${TAG}"
