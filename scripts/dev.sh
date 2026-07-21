#!/bin/bash
# Fast dev loop: kill the running AgentShelf, debug build, relaunch the bundled app.
#   ./scripts/dev.sh
set -euo pipefail
cd "$(dirname "$0")/.."

pkill -x AgentShelf 2>/dev/null || true
./scripts/build-app.sh debug
open AgentShelf.app
