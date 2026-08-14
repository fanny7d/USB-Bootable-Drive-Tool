#!/bin/zsh
set -euo pipefail

exec "${0:A:h}/script/build_and_run.sh" "$@"
