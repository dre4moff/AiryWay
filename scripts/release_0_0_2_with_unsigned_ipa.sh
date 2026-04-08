#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
TAG="${TAG:-0.0.2}" exec "$script_dir/release_with_unsigned_ipa.sh"
