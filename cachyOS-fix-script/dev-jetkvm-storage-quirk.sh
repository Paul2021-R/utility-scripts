#!/usr/bin/env bash
# dev-jetkvm-storage-quirk.sh — JetKVM 가상 USB 저장장치를 리눅스가 무시하게 한다 (Limine)
#
# 증상    부팅이 매번 약 42초 늦다. 스위치 루트 직후 systemd 가 멈췄다가 커널 시각 약 49초에 재개한다.
#         sudo dmesg | grep -E 'reset high-speed USB|zram: Added' 에서 JetKVM 포트(1d6b:0104)가
#         약 21초 간격으로 재설정을 두 번 찍고(≈27.9s · 48.9s), 0.1초 뒤 zram 이 올라온다.
#         journalctl 시각은 journald 가 받은 시각이라 이 구간의 커널 메시지가 49초 한 점에 몰려 보인다.
# 원인    JetKVM 은 가상 미디어를 걸지 않아도 USB 저장장치 인터페이스를 노출하고, 그 장치가
#         커널의 디스크 확인에 응답하지 않는다. 커널이 시간 초과 → 재설정을 두 번 반복한다.
#         https://github.com/jetkvm/kvm/issues/1528
# 조치    커널 옵션 usb-storage.quirks 에 1d6b:0104:i(IGNORE_DEVICE)를 넣는다.
#         키보드·마우스(usbhid)는 영향이 없다. BIOS 단계의 가상 미디어 부팅도 그대로 된다.
#         잃는 것은 실행 중인 리눅스 안에서 JetKVM 가상 미디어를 마운트하는 기능이다.
# ⚠️      1d6b:0104 는 리눅스 USB 가젯 공통 ID 다(PiKVM · 가젯 모드 라즈베리 파이 등). 그 저장장치도 무시된다.
# 되돌림  /etc/default/limine 에서 1d6b:0104:i 항목을 지우고 sudo limine-update

set -uo pipefail

LIMINE_CONF="${LIMINE_CONF:-/etc/default/limine}"
QUIRK="1d6b:0104:i"
TOKEN="usb-storage.quirks=$QUIRK"
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

# ── 1. 커널 옵션 ─────────────────────────────────────────────────────────────
# usb-storage.quirks 는 마지막 값만 살아남으므로, 이미 있으면 새로 붙이지 않고 그 목록에 합친다.
merged=0
new_words=()
for w in "${words[@]}"; do
  if [[ "$w" =~ ^usb[-_]storage\.quirks=(.*)$ ]]; then
    merged=1
    [[ ",${BASH_REMATCH[1]}," == *",$QUIRK,"* ]] || w="$w,$QUIRK"
  fi
  new_words+=("$w")
done
[[ "$merged" -eq 1 ]] || new_words+=("$TOKEN")

if [[ "${new_words[*]}" == "${words[*]}" ]]; then
  log "커널 옵션: $QUIRK 이미 있음 — limine-update 를 건너뛴다"
else
  backup="$LIMINE_CONF.bak-jetkvm-$(date +%Y%m%d-%H%M%S)"
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
  log "커널 옵션: $QUIRK 추가 (백업 $backup)"
  log "  → $new_line"

  # ── 2. 부팅 항목 · initramfs 재생성 ───────────────────────────────────────
  log "limine-update 실행"
  limine-update || die "limine-update 실패 — 설정 파일은 수정된 상태다. 원인을 확인한 뒤 sudo limine-update 를 다시 실행한다"
fi

# ── 3. 현재 상태 ─────────────────────────────────────────────────────────────
active=$(cat /sys/module/usb_storage/parameters/quirks 2> /dev/null)
if [[ ",$active," == *",$QUIRK,"* ]]; then
  log "지금 부팅에 적용돼 있다 (quirks=$active)"
else
  log "재부팅 뒤 적용된다. 확인: cat /sys/module/usb_storage/parameters/quirks ; journalctl -b -k | grep 'reset high-speed USB'"
fi
