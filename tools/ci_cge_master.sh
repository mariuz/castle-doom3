#!/usr/bin/env bash
# CI (GitHub Actions, in the kambi/castle-engine-cloud-builds-tools:cge-none
# Docker image, which has FPC but no engine): get Castle Game Engine master,
# build its build tool, and make the next steps use it
# (CASTLE_ENGINE_PATH and PATH through GITHUB_ENV / GITHUB_PATH).
set -euo pipefail

CGE_DIR="${RUNNER_TEMP:-/tmp}/castle-engine"

if ! command -v git > /dev/null; then
  apt-get update
  apt-get install -y --no-install-recommends git ca-certificates
fi

rm -rf "${CGE_DIR}"
git clone --depth 1 --branch master https://github.com/castle-engine/castle-engine.git "${CGE_DIR}"
git -C "${CGE_DIR}" log -1 --format='CGE master: %H %cd %s'

cd "${CGE_DIR}"
./tools/build-tool/castle-engine_compile.sh

echo "CASTLE_ENGINE_PATH=${CGE_DIR}" >> "${GITHUB_ENV}"
echo "${CGE_DIR}/tools/build-tool" >> "${GITHUB_PATH}"
