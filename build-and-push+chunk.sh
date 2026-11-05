#!/bin/bash
# Build a target of Containerfile, rechunk it, and push the chunked image.
# CI (.github/workflows/build.yml) runs this same script, so local builds and
# CI builds take one code path.
#
#   1. build     podman build --target vm|base -> localhost/<name>-unchunked
#   2. clean     drop the Windows seed image and dangling layers (disk space)
#   3. chunk     rpm-ostree compose build-chunked-oci -> <image>:latest
#                (rpm-ostree runs from the image just built, so the host needs
#                none, and the tool matches the OS it chunks)
#   4. verify    every file under /usr, /etc and /opt survived the chunking
#   5. push      :TAG (if -t) and :latest
#
# The chunked image is the one installed and updated: one layer per group of
# RPMs (and the Windows disk on its own), with digests that stay the same
# between builds while their content does, so `bootc upgrade` downloads only
# what changed. The previous :latest is pulled first, because
# build-chunked-oci reuses the layer layout of the image it writes over.
set -euo pipefail

usage() {
  cat <<EOF
usage: $0 [-t TAG] [-a AUTHFILE] [-d DIGESTFILE] [-P] [vm|base]
  vm|base        target to build (default: vm)
                   vm   -> quay.io/rh-ee-sayash/tableton
                   base -> quay.io/rh-ee-sayash/tableton-base
  -t TAG         also tag and push :TAG (default: only :latest)
  -a AUTHFILE    registry auth file (default: pull-secret.json if present,
                 else podman's own login)
  -d DIGESTFILE  write the digest of the first pushed tag to DIGESTFILE
  -P             build, chunk and verify, but do not push
EOF
  exit "${1:-1}"
}

TAG="" AUTHFILE="" DIGESTFILE="" PUSH=1
[ -f pull-secret.json ] && AUTHFILE=pull-secret.json
while getopts "t:a:d:Ph" opt; do
  case "$opt" in
    t) TAG="$OPTARG" ;;
    a) AUTHFILE="$OPTARG" ;;
    d) DIGESTFILE="$OPTARG" ;;
    P) PUSH=0 ;;
    h) usage 0 ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
TARGET="${1:-vm}"
case "$TARGET" in
  vm)   NAME=tableton ;;
  base) NAME=tableton-base ;;
  *)    usage ;;
esac
[ $# -le 1 ] || usage
IMAGE="quay.io/rh-ee-sayash/$NAME"
PLAIN="localhost/$NAME-unchunked:latest"
WINDOWS_DISK_IMAGE=quay.io/rh-ee-sayash/windows10-disk:latest
AUTH=()
[ -n "$AUTHFILE" ] && AUTH=(--authfile "$AUTHFILE")

echo "---------------- Building Container Image ($TARGET) ----------------"
podman build "${AUTH[@]}" -f Containerfile --target "$TARGET" -t "$PLAIN" .

echo "---------------- Cleaning Build Leftovers ----------------"
podman rmi "$WINDOWS_DISK_IMAGE" 2>/dev/null || true
podman image prune -f

echo "------------ Building Chunked Container Image ------------"
podman pull "${AUTH[@]}" "$IMAGE:latest" \
  || echo "no previous $IMAGE:latest; chunking without a previous layout"
podman run --rm --privileged --security-opt label=disable \
  -v /var/lib/containers:/var/lib/containers \
  -v /var/tmp:/var/tmp \
  "$PLAIN" \
  rpm-ostree compose build-chunked-oci --bootc --format-version=2 \
    --from="$PLAIN" --output="containers-storage:$IMAGE:latest"

echo "------------ Verifying Chunked Container Image ------------"
# build-chunked-oci drops regular files under /var. Anything the image needs
# must live in /usr or /etc; this fails the build if any of it went missing.
paths() {
  podman run --rm "$1" sh -c \
    'find /usr /etc /opt/ \( -type f -o -type l \) 2>/dev/null; true' | sort
}
missing=$(comm -23 <(paths "$PLAIN") <(paths "$IMAGE:latest"))
if [ -n "$missing" ]; then
  echo "ERROR: $(wc -l <<<"$missing") files are in $PLAIN but not in the chunked image:" >&2
  head -50 <<<"$missing" >&2
  exit 1
fi
dropped=$(podman run --rm "$PLAIN" sh -c \
  'find /var -type f -not -path "/var/cache/*" -not -path "/var/log/*" -not -path "/var/lib/dnf/*" 2>/dev/null; true')
[ -z "$dropped" ] || { echo "Files under /var, not carried into the chunked image:"; echo "$dropped"; }
echo "Chunked layers (largest first):"
podman history --format '{{.Size}}' "$IMAGE:latest" | sort -h -r | head -5
podman rmi "$PLAIN"
[ -z "$TAG" ] || podman tag "$IMAGE:latest" "$IMAGE:$TAG"

[ "$PUSH" = 1 ] || { echo "Not pushing (-P)."; exit 0; }
echo "------------- Pushing Chunked Container Image -------------"
# The dated tag is immutable (what you roll back to); latest is what
# installed machines follow.
first="${TAG:-latest}"
podman push "${AUTH[@]}" ${DIGESTFILE:+--digestfile="$DIGESTFILE"} "$IMAGE:$first"
[ "$first" = latest ] || podman push "${AUTH[@]}" "$IMAGE:latest"
