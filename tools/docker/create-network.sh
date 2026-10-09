#!/usr/bin/env bash
set -euo pipefail

NETWORK_NAME="${DOCKER_KIT_NETWORK:-docker-kit-network}"

if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  echo "Docker network '${NETWORK_NAME}' already exists."
else
  docker network create "${NETWORK_NAME}"
  echo "Docker network '${NETWORK_NAME}' created."
fi