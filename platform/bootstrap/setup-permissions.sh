#!/usr/bin/env bash
set -euo pipefail
find bootstrap -type f -name "*.sh" -exec chmod +x {} \;
echo "OK: scripts are executable."
