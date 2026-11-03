#!/usr/bin/env bash
# Compatibility path for existing local commands.
exec bash "$(dirname "$0")/../../deploy/kubernetes/local/attach-node-input.sh" "$@"
