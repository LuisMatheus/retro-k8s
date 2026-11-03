#!/usr/bin/env bash
# Compatibility path for existing user systemd units.
exec bash "$(dirname "$0")/../../deploy/kubernetes/local/browser.sh" "$@"
