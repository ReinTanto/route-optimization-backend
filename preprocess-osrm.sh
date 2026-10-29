#!/usr/bin/env bash
#
# Pre-process the Indonesia OSM data into an OSRM routing database.
# This is a one-time (or per-data-update) step, run BEFORE `docker compose up`.
#
# It runs the three OSRM preparation stages (extract -> partition -> customize)
# using the official osrm-backend image, then leaves the resulting
# `indonesia-latest.osrm` files in ./osrm-data for the `osrm-routed` server.
#
# Requirements:
#   - ./osm-indonesia-latest.osm.pbf  (downloaded OSM extract, ~250 MB)
#   - ~8 GB free RAM, ~25 GB free disk
#
# Usage:
#   ./preprocess-osrm.sh
#
set -euo pipefail

cd "$(dirname "$0")"

OSM_FILE="osm-indonesia-latest.osm.pbf"
DATA_DIR="osrm-data"
IMAGE="ghcr.io/project-osrm/osrm-backend:latest"

if [[ ! -f "$OSM_FILE" ]]; then
  echo "ERROR: $OSM_FILE not found."
  echo "Download it first:"
  echo "  curl -sL -o $OSM_FILE https://download.geofabrik.de/asia/indonesia-latest.osm.pbf"
  exit 1
fi

mkdir -p "$DATA_DIR"

# Stage 1: Extract — parse the PBF into OSRM's internal format.
# Most memory-hungry step.
echo "==> [1/3] osrm-extract (this can take 20-60 min)..."
docker run --rm -v "$PWD/$DATA_DIR:/data" "$IMAGE" \
  osrm-extract -p /opt/car.lua \
  --input /data/"$OSM_FILE" \
  --extractor-car \
  --threads "$(nproc)" \
  /data/indonesia-latest.osrm

# Stage 2: Partition — build the MLD contraction hierarchy.
echo "==> [2/3] osrm-partition..."
docker run --rm -v "$PWD/$DATA_DIR:/data" "$IMAGE" \
  osrm-partition \
  --threads "$(nproc)" \
  /data/indonesia-latest.osrm

# Stage 3: Customize — prepare the node-based turn restrictions.
echo "==> [3/3] osrm-customize..."
docker run --rm -v "$PWD/$DATA_DIR:/data" "$IMAGE" \
  osrm-customize \
  --threads "$(nproc)" \
  /data/indonesia-latest.osrm

echo ""
echo "==> Done. Files in $DATA_DIR:"
ls -lh "$DATA_DIR"
echo ""
echo "Now start the services:"
echo "  docker compose up -d"
