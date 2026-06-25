#!/usr/bin/env bash
# Local convenience: lint the repo exactly as CI does. Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."
exec swiftlint lint --strict
