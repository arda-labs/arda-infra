#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "Restore is intentionally conservative."
echo "Recommended flow:"
echo "  1. Put required secrets into secrets/generated/"
echo "  2. Run ./bootstrap/install-all.sh"
echo "  3. Run ./bootstrap/init-garage.sh if Garage was re-created"
echo
echo "Backups are in ./backups/ for manual inspection."
