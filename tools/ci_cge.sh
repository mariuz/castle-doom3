#!/usr/bin/env bash
# CI (GitHub Actions, in the kambi/castle-engine-cloud-builds-tools:cge-none
# Docker image, which has FPC but no engine): get Castle Game Engine,
# build its build tool, and make the next steps use it
# (CASTLE_ENGINE_PATH and PATH through GITHUB_ENV / GITHUB_PATH).
#
# By default the engine is the doom3-port branch of mariuz/castle-engine:
# CGE master with the pull requests this port needs merged in
# (see docs/ROADMAP.md, "Changes needed in Castle Game Engine").
# Override with CGE_REPO / CGE_BRANCH, for example CGE master:
#   CGE_REPO=https://github.com/castle-engine/castle-engine.git CGE_BRANCH=master
set -euo pipefail

CGE_REPO="${CGE_REPO:-https://github.com/mariuz/castle-engine.git}"
CGE_BRANCH="${CGE_BRANCH:-doom3-port}"
CGE_DIR="${RUNNER_TEMP:-/tmp}/castle-engine"

if ! command -v git > /dev/null; then
  apt-get update
  apt-get install -y --no-install-recommends git ca-certificates
fi

rm -rf "${CGE_DIR}"
git clone --depth 1 --branch "${CGE_BRANCH}" "${CGE_REPO}" "${CGE_DIR}"
git -C "${CGE_DIR}" log -1 --format="CGE ${CGE_BRANCH}: %H %cd %s"

cd "${CGE_DIR}"
./tools/build-tool/castle-engine_compile.sh

echo "CASTLE_ENGINE_PATH=${CGE_DIR}" >> "${GITHUB_ENV}"
echo "${CGE_DIR}/tools/build-tool" >> "${GITHUB_PATH}"
