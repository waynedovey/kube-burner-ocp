#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "" ]]; then
  echo "Usage: $0 <uuid>"
  exit 1
fi
kube-burner destroy --uuid "$1"
