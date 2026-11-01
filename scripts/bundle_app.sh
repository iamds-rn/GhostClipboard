#!/usr/bin/env zsh
set -euo pipefail
exec "$(dirname "$0")/build_app_bundle.sh" "$@"
