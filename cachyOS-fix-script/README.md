## CachyOS 증상별 조치 스크립트 (Dev PC)

Dev PC(CachyOS · Limine · nvidia-open · KDE Plasma)에서 한 번 겪은 증상을 다시 만났을 때 스크립트 하나로 같은 조치를 다시 적용한다. 부팅 설정을 고치는 스크립트는 여러 번 실행해도 결과가 같고(이미 적용돼 있으면 건너뛴다), 수정 전 원본을 `*.bak-{스크립트}-{시각}`으로 남긴다.

### 1. 구성

| 스크립트 | 증상 | 권한 |
|:--|:--|:--|
| `dev-santize-audio.sh` | Brio 500 마이크가 입력 장치로 잡히지 않는다 | 사용자 |
| `dev-disable-plymouth.sh` | 부팅 뒤 로그인 화면 대신 스플래시에서 멈춘다 | root(스스로 sudo 재실행) |
| `dev-jetkvm-storage-quirk.sh` | 부팅이 매번 약 42초 늦다 | root(스스로 sudo 재실행) |

OS를 다시 설치했거나 `/etc/default/limine`이 초기화됐으면 부팅 설정 스크립트 두 개를 다시 실행한다. 설치기 기본 커널 옵션에는 `splash`가 들어 있다.

```sh
./dev-disable-plymouth.sh
./dev-jetkvm-storage-quirk.sh
```

둘 다 적용된 커널 옵션은 `quiet nowatchdog rw rootflags=subvol=/@ root=UUID=… plymouth.enable=0 usb-storage.quirks=1d6b:0104:i` 형태다(순서는 무관하다). 적용은 재부팅 뒤부터다.

### 2. `dev-disable-plymouth.sh` — 스플래시에서 멈춤

**판별**

```sh
journalctl -b | grep -E "plymouth-quit.service: start operation timed out|Failed to open /dev/dri"
```

`plymouth-quit.service` 시간 초과 뒤 `kwin_wayland`가 `Failed to open /dev/dri/card1 device (Device or resource busy)`를 반복하다 core dump로 죽는다. `systemctl list-jobs`에 `plymouth-quit-wait.service`가 running으로 남고 `graphical.target`이 끝나지 않는다.

**멈춰 있을 때 즉시 복구(SSH)**

```sh
sudo pkill -9 plymouthd && sudo systemctl restart plasmalogin
```

**원인** — `plymouthd`가 종료 요청에 응답하지 않고 GPU 제어권(DRM master)을 쥔 채 남아, 로그인 화면의 `kwin_wayland`가 GPU를 열지 못한다. 커널 7.x와 nvidia-open 조합에서 보고된 문제다([linux-cachyos#940](https://github.com/CachyOS/linux-cachyos/issues/940)). 매 부팅이 아니라 간헐적으로 걸린다.

**하는 일**

1. `KERNEL_CMDLINE[default]`에서 `splash`를 빼고 `plymouth.enable=0`을 넣는다. `plymouth-start.service`가 `ConditionKernelCommandLine=!plymouth.enable=0` 조건으로 initrd와 실제 루트 모두에서 건너뛰어지므로 `plymouthd`가 뜨지 않는다.
2. `/etc/vconsole.conf`의 `KEYMAP`이 존재하지 않는 키맵(`ko` 등)이면 `us`로 바꾼다. plymouth가 콘솔을 잡고 있을 때는 `systemd-vconsole-setup`이 건너뛰어졌지만, plymouth가 빠지면 실제로 실행되며 `loadkeys: Unable to open file: ko`로 실패한다.
3. 바뀐 것이 있으면 `limine-update`로 initramfs와 부팅 항목을 다시 만든다.

**확인(재부팅 뒤)** — `journalctl -b | grep -iE "plymouth-start|plymouth-quit"`에 `Show Plymouth Boot Screen skipped`가 보이고, `systemctl --failed`가 비어 있으면 된다.

**되돌림** — `/etc/default/limine`의 `plymouth.enable=0`을 `splash`로 바꾸고 `sudo limine-update`. 시간 초과 시 `plymouthd`를 강제 종료하는 [CachyOS-Settings PR #260](https://github.com/CachyOS/CachyOS-Settings/pull/260)이 병합되면 스플래시를 다시 켤 수 있다.

### 3. `dev-jetkvm-storage-quirk.sh` — 부팅 42초 지연

**판별**

```sh
sudo dmesg | grep -E "reset high-speed USB|zram: Added"
```

JetKVM 포트(`1d6b:0104`)가 약 21초 간격으로 재설정을 두 번 찍고(≈27.9s · 48.9s) 0.1초 뒤 `zram: Added device`가 나온다. 그 사이 systemd는 스위치 루트 직후에서 멈춰 있다. `journalctl`의 시각은 journald가 *받은* 시각이라 이 구간의 커널 메시지가 49초 한 점에 몰려 보이므로, 커널 시각은 `dmesg`나 `journalctl -o json`의 `_SOURCE_MONOTONIC_TIMESTAMP`로 본다.

**원인** — JetKVM은 가상 미디어를 걸지 않아도 USB 저장장치 인터페이스를 노출하고, 그 장치가 커널의 디스크 확인에 응답하지 않는다. 커널은 시간 초과 → 재설정을 두 번 반복한다. Windows에서도 같은 장치로 부팅이 120초 늦어지는 보고가 있다([jetkvm/kvm#1528](https://github.com/jetkvm/kvm/issues/1528)).

**하는 일** — 커널 옵션 `usb-storage.quirks`에 `1d6b:0104:i`(`i` = IGNORE_DEVICE, [커널 문서](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/Documentation/admin-guide/kernel-parameters.txt))를 넣고 `limine-update`를 실행한다. `usb-storage.quirks`는 마지막 값만 살아남으므로, 이미 있으면 새로 붙이지 않고 그 목록에 `,1d6b:0104:i`를 합친다.

**영향**

- JetKVM 키보드·마우스는 다른 드라이버(usbhid)가 맡으므로 그대로 동작한다.
- BIOS 단계의 가상 미디어(ISO) 부팅은 펌웨어가 자기 USB 드라이버를 쓰므로 그대로 된다.
- 실행 중인 리눅스 안에서 JetKVM 가상 미디어를 마운트하는 기능은 쓸 수 없다. 그 기능이 필요하면 이 스크립트 대신 JetKVM 설정에서 Mass Storage를 끄고, 필요할 때만 켠다.
- ⚠️ `1d6b:0104`는 리눅스 USB 가젯 공통 ID다(PiKVM · 가젯 모드 라즈베리 파이 등). 그런 기기의 저장장치도 무시된다.

**확인(재부팅 뒤)** — `cat /sys/module/usb_storage/parameters/quirks`가 `1d6b:0104:i`를 포함하고, `dmesg`에 JetKVM 포트 재설정이 없으며, `systemd-analyze`의 userspace 시간이 약 42초 줄어든다.

**되돌림** — `/etc/default/limine`에서 `1d6b:0104:i` 항목을 지우고 `sudo limine-update`.

### 4. 공통

- 🚨 `limine-update`는 initramfs와 부팅 항목을 다시 만든다. 설정 파일이 잘못되면 부팅 항목이 깨진다. 스크립트는 수정 뒤 문법(`bash -n`)과 결과 줄을 검증하고, 실패하면 백업으로 되돌린 뒤 멈춘다. 그래도 부팅이 안 되면 Limine 메뉴에서 `e`로 옵션을 한 번만 고치거나 Snapshots 항목으로 부팅한다.
- `KERNEL_CMDLINE[default]` 줄이 하나일 때만 동작한다. 여러 줄이면 멈추고 직접 수정을 요구한다.
- `limine-update`가 실패하면 설정 파일은 수정된 채로 남는다. 원인을 확인한 뒤 `sudo limine-update`를 다시 실행한다.
- 대상 파일은 `LIMINE_CONF` · `VCONSOLE_CONF` 환경변수로 바꿀 수 있다. 쓰기 가능한 사본을 가리키면 sudo 없이 돌므로, 스크립트를 고친 뒤 사본으로 시험할 때 쓴다.
