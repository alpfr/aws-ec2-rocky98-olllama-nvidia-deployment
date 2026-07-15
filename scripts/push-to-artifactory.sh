#!/usr/bin/env bash
# push-to-artifactory.sh
# Script to tag and push a local Docker image to an Artifactory / Docker registry.

set -euo pipefail

# Default values
REGISTRY=""
NAMESPACE=""
USER=""
PASSWORD=""
LOCAL_IMAGE=""
TARGET_IMAGE=""
TARGET_TAG=""
CLEANUP=false
DRY_RUN=false

usage() {
  cat <<EOF
Usage: $0 [options] -i <local-image> -r <registry-url>

Options:
  -i, --image        Local Docker image (e.g. "my-app:1.0.0")
  -r, --registry     Artifactory registry URL/domain (e.g. "artifactory.example.com")
  -n, --namespace    Registry namespace/project path (optional, e.g. "docker-local/my-team")
  -u, --user         Username for registry login (optional)
  -p, --password     Password or API key for registry login (optional)
  -t, --target-name  Target image name on registry (optional, defaults to local image name)
  -g, --target-tag   Target tag on registry (optional, defaults to local image tag)
  -c, --cleanup      Delete the registry-tagged local image copy after pushing
  -d, --dry-run      Show commands that would be executed without running them
  -h, --help         Show this help message
EOF
  exit 1
}

# Parse options
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--image)
      LOCAL_IMAGE="$2"
      shift 2
      ;;
    -r|--registry)
      REGISTRY="$2"
      shift 2
      ;;
    -n|--namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    -u|--user)
      USER="$2"
      shift 2
      ;;
    -p|--password)
      PASSWORD="$2"
      shift 2
      ;;
    -t|--target-name)
      TARGET_IMAGE="$2"
      shift 2
      ;;
    -g|--target-tag)
      TARGET_TAG="$2"
      shift 2
      ;;
    -c|--cleanup)
      CLEANUP=true
      shift
      ;;
    -d|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

if [[ -z "${LOCAL_IMAGE}" ]] || [[ -z "${REGISTRY}" ]]; then
  echo "Error: Local image (-i) and registry URL (-r) are required."
  usage
fi

# In dry-run mode, we soft-check requirements instead of failing
if [[ "${DRY_RUN}" == "true" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "[DRY-RUN WARNING] docker command not found."
  elif ! docker info >/dev/null 2>&1; then
    echo "[DRY-RUN WARNING] docker daemon is not running or no permissions."
  fi
else
  # Ensure docker is installed and running
  if ! command -v docker >/dev/null 2>&1; then
    echo "Error: docker command not found. Please install docker first."
    exit 1
  fi

  if ! docker info >/dev/null 2>&1; then
    echo "Error: docker daemon is not running or current user has no permissions."
    exit 1
  fi
fi

# Parse local image and tag
if [[ "${LOCAL_IMAGE}" =~ ^(.*):([^:]+)$ ]]; then
  IMAGE_NAME="${BASH_REMATCH[1]}"
  IMAGE_TAG="${BASH_REMATCH[2]}"
else
  IMAGE_NAME="${LOCAL_IMAGE}"
  IMAGE_TAG="latest"
  LOCAL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
fi

# Check if local image exists
if [[ "${DRY_RUN}" == "false" ]]; then
  if ! docker image inspect "${LOCAL_IMAGE}" >/dev/null 2>&1; then
    echo "Error: Local image '${LOCAL_IMAGE}' not found."
    exit 1
  fi
fi

# Set target image and tag defaults
if [[ -z "${TARGET_IMAGE}" ]]; then
  # Strip registry/path from local image name if present to get basename
  TARGET_IMAGE="${IMAGE_NAME##*/}"
fi

if [[ -z "${TARGET_TAG}" ]]; then
  TARGET_TAG="${IMAGE_TAG}"
fi

# Strip trailing slash from registry URL if present
REGISTRY="${REGISTRY%/}"

# Define target repository path depending on namespace
if [[ -n "${NAMESPACE}" ]]; then
  # Clean namespace leading/trailing slashes
  NAMESPACE="${NAMESPACE#/}"
  NAMESPACE="${NAMESPACE%/}"
  TARGET_REPO="${REGISTRY}/${NAMESPACE}/${TARGET_IMAGE}:${TARGET_TAG}"
else
  TARGET_REPO="${REGISTRY}/${TARGET_IMAGE}:${TARGET_TAG}"
fi

echo "========================================="
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "         *** DRY RUN MODE ***"
fi
echo "Local Image : ${LOCAL_IMAGE}"
echo "Registry    : ${REGISTRY}"
echo "Namespace   : ${NAMESPACE:-[none]}"
echo "Target Tag  : ${TARGET_REPO}"
echo "========================================="

# Handle authentication
if [[ -n "${USER}" ]]; then
  if [[ "${DRY_RUN}" == "true" ]]; then
    if [[ -n "${PASSWORD}" ]]; then
      echo "[DRY-RUN] Would run: echo '***' | docker login ${REGISTRY} -u ${USER} --password-stdin"
    else
      echo "[DRY-RUN] Would run: docker login ${REGISTRY} -u ${USER}"
    fi
  else
    echo "Logging into registry: ${REGISTRY}..."
    if [[ -n "${PASSWORD}" ]]; then
      echo "${PASSWORD}" | docker login "${REGISTRY}" -u "${USER}" --password-stdin
    else
      docker login "${REGISTRY}" -u "${USER}"
    fi
  fi
fi

# Tag the image
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "[DRY-RUN] Would run: docker tag ${LOCAL_IMAGE} ${TARGET_REPO}"
else
  echo "Tagging image..."
  docker tag "${LOCAL_IMAGE}" "${TARGET_REPO}"
fi

# Push the image
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "[DRY-RUN] Would run: docker push ${TARGET_REPO}"
else
  echo "Pushing image to registry..."
  docker push "${TARGET_REPO}"
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "[DRY-RUN] Would complete pushing ${TARGET_REPO}"
else
  echo "Successfully pushed ${TARGET_REPO}"
fi

# Cleanup
if [[ "${CLEANUP}" == "true" ]]; then
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY-RUN] Would run: docker rmi ${TARGET_REPO}"
  else
    echo "Cleaning up local registry-tagged image copy..."
    docker rmi "${TARGET_REPO}"
  fi
fi
