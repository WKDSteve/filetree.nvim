#!/usr/bin/env bash
# scripts/ci-container-image.sh <testing.nvim dir> -- the step container-image of the ci section of .testing.lua.
#
# Builds the Linux image that TESTS/trash_linux_container_spec.lua runs the trash backend in (the default tag of
# testing.container) before the suite starts. On the hosted CI (CI=true) the image is built every run and a missing
# podman is red, so the spec cannot turn into an unnoticed n/a there. Elsewhere nothing is built (no surprise network
# build on a developer's machine): the step only says whether the spec will run or report n/a.
set -euo pipefail

testing_dir="${1:?usage: scripts/ci-container-image.sh <testing.nvim dir>}"
context="$testing_dir/containers/linux"
tag="localhost/testing-linux:1"

if [ "${CI:-}" = "true" ]; then
  if ! command -v podman >/dev/null 2>&1; then
    echo "error: podman is missing on this CI runner; TESTS/trash_linux_container_spec.lua would only report n/a" >&2
    exit 1
  fi
  podman build -t "$tag" "$context"
  exit 0
fi

if command -v podman >/dev/null 2>&1 && podman image exists "$tag" 2>/dev/null; then
  echo "image $tag exists: TESTS/trash_linux_container_spec.lua runs in it"
else
  echo "no image $tag here (podman build -t $tag $context): TESTS/trash_linux_container_spec.lua reports n/a"
fi
