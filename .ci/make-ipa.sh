#!/bin/bash
set -euo pipefail
python3 .ci/make-ipa.py "$@"
