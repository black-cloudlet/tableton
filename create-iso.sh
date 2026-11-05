#!/bin/bash
# Usage: ./create-iso.sh [vm|base]   (default: vm). Build the image first.
set -euo pipefail
case "${1:-vm}" in
  vm)   IMAGE=quay.io/rh-ee-sayash/tableton:latest ;;
  base) IMAGE=quay.io/rh-ee-sayash/tableton-base:latest ;;
  *)    echo "usage: $0 [vm|base]" >&2; exit 1 ;;
esac
podman run \
    --rm \
    -it \
    --authfile pull-secret.json \
    --privileged \
    --pull=newer \
    --security-opt label=type:unconfined_t \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    -v ./config.toml:/config.toml \
    -v ./output:/output \
    registry.redhat.io/rhel9/bootc-image-builder:latest \
    --type iso \
    --config /config.toml \
  "$IMAGE"
