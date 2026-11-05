#!/bin/bash
# Usage: ./build-and-push+chunk.sh [vm|base]   (default: vm)
#   vm   -> quay.io/rh-ee-sayash/tableton       (what CI builds and devices follow)
#   base -> quay.io/rh-ee-sayash/tableton-base  (no Windows VM)
set -euo pipefail
TARGET="${1:-vm}"
case "$TARGET" in
  vm)   IMAGE=quay.io/rh-ee-sayash/tableton ;;
  base) IMAGE=quay.io/rh-ee-sayash/tableton-base ;;
  *)    echo "usage: $0 [vm|base]" >&2; exit 1 ;;
esac

echo "---------------- Building Container Image ($TARGET) ----------------"
podman build -f Containerfile --target "$TARGET" -t "$IMAGE:latest" .

echo "------------ Building Chunked Container Image ------------"
rpm-ostree compose image \
  --bootc \
  --format=chunked-oci \
  --format-version=2 \
  --from="$IMAGE:latest" \
  "containers-storage:$IMAGE:latest-chunked"

echo "---------- Pushing to Registry ----------"
podman push "$IMAGE:latest" --authfile pull-secret.json

echo "------------- Pushing Chunked Container Image -------------"
podman push "$IMAGE:latest-chunked" --authfile pull-secret.json
