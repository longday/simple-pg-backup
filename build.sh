#!/usr/bin/env bash
# Build and publish the image, then create a matching git tag.
# The version to release is read from the VERSION file (semver MAJOR.MINOR.PATCH).
set -euo pipefail

# Constants
IMAGE="longday/simple-pg-backup"
PLATFORMS="linux/amd64,linux/arm64"
BASETAG="18-alpine"
GOCRONVER="v0.0.11"

cd "$(dirname "$0")"

VERSION="$(tr -d '[:space:]' < VERSION)"
if ! printf '%s' "${VERSION}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "VERSION file must contain a semver version like 1.0.0 (got: '${VERSION}')." >&2
  exit 1
fi

# Require a changelog entry for this version in README.md
if ! grep -q "^### ${VERSION} " README.md; then
  echo "Add a changelog entry '### ${VERSION} - <date>' under '## Changelog' in README.md before releasing." >&2
  exit 1
fi

# Require a clean working tree so the tag matches what is published
if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is dirty. Commit your changes before releasing." >&2
  exit 1
fi

TAG="v${VERSION}"
if git rev-parse "${TAG}" >/dev/null 2>&1; then
  echo "Git tag ${TAG} already exists." >&2
  exit 1
fi

echo "Building and pushing ${IMAGE}:${VERSION} and ${IMAGE}:latest for ${PLATFORMS}..."
docker buildx build \
  --platform "${PLATFORMS}" \
  --build-arg BASETAG="${BASETAG}" \
  --build-arg GOCRONVER="${GOCRONVER}" \
  --pull \
  --tag "${IMAGE}:${VERSION}" \
  --tag "${IMAGE}:latest" \
  --push \
  .

echo "Creating and pushing git tag ${TAG}..."
git tag -a "${TAG}" -m "Release ${VERSION}"
git push origin "${TAG}"

echo "Done: published ${IMAGE}:${VERSION} and tagged ${TAG}."
