#!/usr/bin/env bash
# Compatibility path for previously installed browser services.
exec bash "$(dirname "$0")/port-forward-frontend.sh" "$@"
