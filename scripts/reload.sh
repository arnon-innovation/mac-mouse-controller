#!/usr/bin/env bash
# Reload config/config.json into the running controller (SIGHUP). Invalid configs are rejected
# and the previous config stays active.
source "$(dirname "$0")/common.sh"
launchctl kill SIGHUP "$DOMAIN/$LABEL" && sleep 0.3 && tail -n 3 "$CONTROLLER_LOG"
