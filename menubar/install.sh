#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "${1:-}" != "--skip-build" ]]; then ./make-app.sh; fi
python3 install.py
