#!/usr/bin/env bash
# Pause/resume remapping without stopping the process (SIGUSR1). Not persisted.
source "$(dirname "$0")/common.sh"
launchctl kill SIGUSR1 "$DOMAIN/$LABEL" && sleep 0.3 && tail -n 1 "$CONTROLLER_LOG"
