#!/usr/bin/env bash
# dev-disable-plymouth.sh — 부팅 스플래시(plymouth)를 끈다 (Limine · nvidia-open)
#
# 증상    부팅 뒤 로그인 화면이 뜨지 않고 스플래시에서 멈춘다.
#         journalctl -b : plymouth-quit.service 시간 초과
#                         → kwin_wayland "Failed to open /dev/dri/card1 device (Device or resource busy)"
#                         → kwin_wayland core dump
# 원인    plymouthd 가 종료 요청에 응답하지 않고 GPU(DRM master)를 쥔 채 남는다.
#         https://github.com/CachyOS/linux-cachyos/issues/940
# 조치    커널 옵션의 splash 를 빼고 plymouth.enable=0 을 넣어 plymouthd 가 아예 뜨지 않게 한다.
#         plymouth 가 빠지면 vconsole 설정이 실제로 실행되므로, 없는 키맵(KEYMAP=ko 등)을 us 로 바로잡는다.
# 되돌림  /etc/default/limine 의 plymouth.enable=0 을 splash 로 바꾸고 sudo limine-update
#
# 이미 멈춰 있을 때(SSH) : sudo pkill -9 plymouthd && sudo systemctl restart plasmalogin

set -uo pipefail

LIMINE_CONF="${LIMINE_CONF:-/etc/default/limine}"
VCONSOLE_CONF="${VCONSOLE_CONF:-/etc/vconsole.conf}"
TOKEN="plymouth.enable=0"
CMDLINE_RE='^KERNEL_CMDLINE\[default\]\+?="'

log() {
  echo "[$(date '+%F %T')] $*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

[[ -f "$LIMINE_CONF" ]] || die "$LIMINE_CONF 이 없다 — Limine 환경이 아니다"
[[ -w "$LIMINE_CONF" ]] || exec sudo -- "$0" "$@"

count=$(grep -cE "$CMDLINE_RE" "$LIMINE_CONF")
[[ "$count" -eq 1 ]] || die "KERNEL_CMDLINE[default] 줄이 ${count}개다 — 직접 수정한다"

line=$(grep -E "$CMDLINE_RE" "$LIMINE_CONF")
prefix=${line%%\"*}
value=${line#*\"}
value=${value%\"*}
read -ra words <<< "$value"

changed=0

# ── 1. 커널 옵션 ─────────────────────────────────────────────────────────────
has_token=0
new_words=()
for w in "${words[@]}"; do
  [[ "$w" == "splash" ]] && continue
  [[ "$w" == "$TOKEN" ]] && has_token=1
  new_words+=("$w")
done
[[ "$has_token" -eq 1 ]] || new_words+=("$TOKEN")

if [[ "${new_words[*]}" == "${words[*]}" ]]; then
  log "커널 옵션: $TOKEN 이미 있음"
else
  backup="$LIMINE_CONF.bak-plymouth-$(date +%Y%m%d-%H%M%S)"
  cp -a "$LIMINE_CONF" "$backup"

  new_line="${prefix}\"${new_words[*]}\""
  tmp=$(mktemp)
  RE="$CMDLINE_RE" NL="$new_line" awk '$0 ~ ENVIRON["RE"] { print ENVIRON["NL"]; next } { print }' "$LIMINE_CONF" > "$tmp"
  cat "$tmp" > "$LIMINE_CONF"
  rm -f -- "${tmp:?}"

  if ! bash -n "$LIMINE_CONF" 2> /dev/null || ! grep -Fx -- "$new_line" "$LIMINE_CONF" > /dev/null; then
    cp -a "$backup" "$LIMINE_CONF"
    die "수정 결과 검증 실패 — $LIMINE_CONF 를 백업에서 되돌렸다"
  fi
  log "커널 옵션: splash 제거 · $TOKEN 추가 (백업 $backup)"
  log "  → $new_line"
  changed=1
fi

# ── 2. 콘솔 키맵 ─────────────────────────────────────────────────────────────
keymap=$(sed -n 's/^KEYMAP=//p' "$VCONSOLE_CONF" 2> /dev/null | tr -d '"')
if [[ -n "$keymap" ]] && ! localectl list-keymaps | grep -Fx -- "$keymap" > /dev/null; then
  cp -a "$VCONSOLE_CONF" "$VCONSOLE_CONF.bak-plymouth-$(date +%Y%m%d-%H%M%S)"
  sed -i 's/^KEYMAP=.*/KEYMAP=us/' "$VCONSOLE_CONF"
  log "콘솔 키맵: 없는 키맵 '$keymap' → us"
  changed=1
else
  log "콘솔 키맵: ${keymap:-(미지정)} 유지"
fi

# ── 3. 부팅 항목 · initramfs 재생성 ─────────────────────────────────────────
if [[ "$changed" -eq 1 ]]; then
  log "limine-update 실행"
  limine-update || die "limine-update 실패 — 설정 파일은 수정된 상태다. 원인을 확인한 뒤 sudo limine-update 를 다시 실행한다"
else
  log "바뀐 것이 없어 limine-update 를 건너뛴다"
fi

# ── 4. 현재 상태 ─────────────────────────────────────────────────────────────
if grep -Fw -- "$TOKEN" /proc/cmdline > /dev/null; then
  log "지금 부팅에 적용돼 있다"
else
  log "재부팅 뒤 적용된다. 확인: journalctl -b | grep -iE 'plymouth-start|plymouth-quit|Failed to open /dev/dri'"
fi
