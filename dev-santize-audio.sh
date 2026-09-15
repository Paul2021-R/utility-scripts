#!/usr/bin/env bash

set -u

BRIO_CARD="alsa_card.usb-046d_Brio_500_2512ZBH2XP28-02"
BRIO_SOURCE="alsa_input.usb-046d_Brio_500_2512ZBH2XP28-02.analog-stereo"

log() {
  echo "[$(date '+%F %T')] $*"
}

log "Restarting desktop media services"

systemctl --user restart \
  pipewire.service \
  pipewire-pulse.service \
  wireplumber.service

systemctl --user try-restart \
  xdg-desktop-portal.service \
  xdg-desktop-portal-kde.service 2>/dev/null || true

sleep 2

log "Checking Brio 500"

if pactl list cards | grep -Fq "$BRIO_CARD"; then
  pactl set-card-profile "$BRIO_CARD" input:analog-stereo || true
  sleep 1
fi

if pactl list short sources | grep -Fq "$BRIO_SOURCE"; then
  pactl set-default-source "$BRIO_SOURCE"
  log "Brio 500 OK"
else
  log "Brio 500 source missing - resetting WirePlumber state"

  wpctl reset --force 2>/dev/null || {
    rm -rf "$HOME/.local/state/wireplumber"
    systemctl --user restart wireplumber pipewire pipewire-pulse
  }

  sleep 2

  pactl set-card-profile "$BRIO_CARD" input:analog-stereo || true
  pactl set-default-source "$BRIO_SOURCE" || true
fi

log "Audio state"
wpctl status

log "Sanitize complete"
