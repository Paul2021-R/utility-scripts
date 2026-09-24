## Claude Code 원격 제어 세션 장부 · 부팅 복구 (systemd user)

Dev PC에서 원격 제어(Remote Control)로 연결된 Claude Code 세션을 장부(`ledger.json`)에 기록한다. 기록 시점은 1분마다, 그리고 시스템 종료 직전이다. 부팅하면 장부의 세션을 tmux 창마다 `claude --resume`으로 다시 띄워 claude.ai / Claude 앱에서 바로 이어 쓸 수 있게 만들고, 원격 연결까지 됐는지 검증해 결과를 리포트로 남긴다. 대상은 이 기기(`~/.claude/sessions/`)의 세션뿐이다.

### 1. 구성

| 파일 | 설치 위치 | 역할 |
|:--|:--|:--|
| `claude-snap` | `~/.local/bin/` | `save` · `restore` · `status` · `add` · `drop` · `history` |
| `claude-snap.service` | `~/.config/systemd/user/` | 부팅 시 `restore`, 종료 시 `save --final` |
| `claude-snap-save.service` · `.timer` | `~/.config/systemd/user/` | 1분마다 `save` |

상태 파일은 `~/.local/state/claude-snap/` 아래에 둔다.

| 경로 | 내용 |
|:--|:--|
| `ledger.json` | 장부 |
| `history/ledger-*.json` | 장부 구성이 바뀌기 직전 판. 최근 50개 |
| `reports/restore-*.log` | 복구 한 번당 리포트(판단 · 결과 · 실패 창 화면). 최근 30개 |
| `events.log` | 장부에 항목이 들고 난 기록(ADD · DROP · IMPORT)과 사유 |

### 2. 설치

사전 조건은 `claude-rc-service`와 같다(로그인 · workspace trust · Remote Control 동의 · `loginctl enable-linger`). `jq` · `tmux` · `fish` · `curl` · `flock` · `systemd-run`이 필요하다.

```sh
install -Dm755 claude-snap ~/.local/bin/claude-snap
install -Dm644 -t ~/.config/systemd/user claude-snap.service claude-snap-save.service claude-snap-save.timer
systemctl --user daemon-reload
systemctl --user enable --now claude-snap.service claude-snap-save.timer
```

### 3. 장부 규칙

**들어오는 조건** — 살아 있고(`/proc/<pid>/stat`의 starttime이 `procStart`와 같다), 원격 제어에 연결돼 있으며(`bridgeSessionId`가 null이 아님), 대화 기록에 사용자 입력이 한 번이라도 있는 세션. 서버가 미리 만들어 둔 빈 세션은 입력이 생길 때까지 들어오지 않는다.

**빠지는 조건** — "끝났다는 증거"가 있을 때뿐이다.

| 사유 | 판정 |
|:--|:--|
| `archived` | 이번 부팅에 연결을 확인한 세션이 살아 있는 채 원격 연결이 null이 됨. claude.ai / 앱에서 보관한 경우다 |
| `ended` | 이번 부팅에 살아 있던 세션이 켜져 있는 동안 사라짐. `/exit`, 서버 세션 보관(서버는 보관하면 프로세스까지 끝낸다)이다. 종료 직전 저장(`--final`)에서는 적용하지 않는다 |
| `no-transcript` | 대화 기록(`~/.claude/projects/*/<id>.jsonl`)이 없음 |

이번 부팅에 아직 한 번도 보이지 않은 항목(복구 전 · 복구 실패 · 서버가 맡은 채 아직 안 띄운 세션)은 남는다. "지금 안 떠 있음"만으로는 지우지 않으므로 복구가 실패해도 장부가 비지 않는다.

항목마다 `sessionId` · `cwd` · 이름 · 출신(`server` / `local` / `manual`) · tmux 세션 이름 · 원격 세션 ID · 실행 옵션 · 마지막 확인 시각과 부팅 · 복구 실패 횟수와 사유를 남긴다. 실행 옵션은 `/proc/<pid>/cmdline`에서 `--model` · `--effort` · `--permission-mode` · `--name`/`-n` · `--agent` · `--add-dir` · `--remote-control [이름]` · `--dangerously-skip-permissions` · `--chrome`/`--no-chrome`만 골라낸다. 명령줄에 권한 모드가 없으면 대화 기록의 마지막 권한 모드(실행 중 shift+tab으로 바꾼 값)를 쓴다.

### 4. 복구

`restore`는 먼저 네트워크를 1초 간격으로 최대 120초 기다린다(DNS 조회 → HTTPS 순서). 이어서 두 단계로 복구한다.

- **1단계 — tmux · 수동 출신**: 서버가 되살릴 수 없는 세션이라 서버를 기다리지 않고 바로 띄운다.
- **2단계 — 서버 출신**: 원격 제어 서버마다 연결(`Connected`)되고 세션 목록이 10초 동안 바뀌지 않을 때까지 최대 150초 기다린 뒤 띄운다. 장부에 서버 출신이 없으면 이 단계는 통째로 건너뛴다.

두 단계 모두 항목마다 아래 순서로 판단한다.

1. 같은 `sessionId`가 이미 떠 있으면 건너뛴다.
2. 작업 디렉터리나 대화 기록이 없으면 실패로 기록한다.
3. 원격 세션 ID가 지금 서버(`claude-rc@*`) 화면의 세션 목록에 있으면 건너뛴다. 서버가 그 세션을 맡고 있으므로 따로 띄우면 한 대화를 프로세스 둘이 잡는다.
4. 나머지를 `fish -c 'claude --resume <sessionId> <옵션>; …; exec fish'`로 띄운다. 원래 tmux 세션 이름이 있으면 그 이름으로, 없으면 `claude-restored` 세션의 창으로 띄운다. 옵션에 `--remote-control`이 없으면 붙이고, 이름이 자동 파생(`derived`)이 아니면 그 이름을 원격 제어 이름으로 넘긴다.

띄운 뒤 최대 90초 동안 5초마다 원격 연결을 확인한다. claude가 바로 끝나 버리면 즉시, 제한 시간까지 연결되지 않으면 그 시점에 실패로 판정하고, 창 화면(종료했으면 종료 표시 앞 15줄)을 리포트에 붙인다. 실패 사유(`exited` · `not-connected` · `no-cwd` · `no-transcript` · `tmux`)와 리포트 파일명은 장부 항목의 `lastRestoreError`에 남고 `restoreFails`가 1 오른다.

검증이 끝나면 서버 목록을 한 번 더 읽는다. 복구한 세션의 원래 원격 세션을 서버가 뒤늦게 되살렸으면 `WARN … 중복`을 리포트에, `DUP`을 `events.log`에 남긴다. 저장 때도 같은 대화를 프로세스 여럿이 잡고 있으면 `DUP-LIVE`를 남긴다. 둘 다 앱에서 중복 항목 하나를 보관하면 풀린다.

`--from FILE`로 준 파일의 항목은 장부에 없는 것만 장부에 합친 뒤(`IMPORT`) 그 파일의 항목만 복구한다. 다른 장부 · history의 이전 판 · 손으로 만든 복원본을 그대로 넣을 수 있다.

### 5. 운영

```sh
claude-snap status                         # 장부 항목과 상태 (live / 연결끊김 / 대기) + 이번 부팅 복구 진행 단계
claude-snap status history/ledger-….json   # 다른 장부 파일 보기
claude-snap restore --dry-run              # 띄우지 않고 복구 판단만 출력
claude-snap restore --from FILE            # 지정한 장부의 항목만 복구 (장부에 합친다)
claude-snap add <세션ID 앞부분>             # 대화 기록으로 항목을 만들어 장부에 넣는다
claude-snap drop <세션ID 앞부분>            # 장부에서 뺀다
claude-snap history                        # 장부 이전 판 목록
tail ~/.local/state/claude-snap/events.log  # 들고 난 기록
ls -t ~/.local/state/claude-snap/reports/   # 복구 리포트
```

`add`는 대화 기록에서 작업 디렉터리(`cwd`) · 마지막 권한 모드 · 모델 · effort · 사용자 지정 제목 · 원격 세션 ID를 읽어 항목을 만든다. 장부에서 빠졌지만 이어 가고 싶은 대화를 되돌릴 때 쓴다.

### 6. 설계 판단

- **서버가 자기 세션을 되살린다고 가정하지 않는다.** 문서는 서버가 멈춘 지 약 4시간 안이면 같은 디렉터리에서 다시 띄운 서버가 세션을 되살린다고 하지만, systemd 종료 후 212분 만의 부팅에서 두 서버 모두 새 세션 하나씩만 띄웠다. 그래서 서버에 맡길지는 공백 시간이 아니라 서버 화면의 실제 목록으로 판단한다.
- **서버 목록은 journal에 찍힌 서버 화면에서 읽는다.** 서버 TUI는 상태가 바뀔 때만 다시 그리므로, 시간 창이 아니라 이번 서버 기동(`ExecMainStartTimestamp`) 이후 출력에서 마지막 화면(마지막 `Capacity:` 줄부터 안내 문구 전까지)을 쓴다.
- **서버를 기다릴 때 `activating`(auto-restart)도 대상에 넣고, 연결 후 목록이 안정될 때까지 본다.** 부팅 직후 네트워크가 늦으면 서버가 DNS 실패(`EAI_AGAIN`)로 한 번 죽고 30초 뒤 다시 뜬다. 다시 뜬 서버는 연결 직후 빈 목록(`Capacity: 0/32`)을 먼저 그리고, 이전 세션을 1~2초 뒤에 되살린다. `active` 서버만 보거나 첫 화면만 보면 서버가 되살릴 세션까지 복구해 중복이 생긴다.
- **짧은 재부팅(3분)에서는 서버가 자기 세션을 되살렸고, 212분 공백 뒤에는 되살리지 않았다.** 그래서 공백 시간으로 추정하지 않고 매번 목록을 관측한다.
- **보관한 세션은 `--resume`하면 원래 원격 세션에 다시 붙고 보관이 풀린다.** tmux에서 띄운 세션의 대화 기록에는 재접속 기록(`bridge-session`)이 남고 보관해도 지워지지 않는다. 보관 여부는 저장 시점에 원격 연결 null로 걸러야 한다.
- **서버가 띄운 세션은 대화 기록에 재접속 기록이 없다.** 복구하면 대화 맥락은 이어지지만 앱에는 새 항목으로 뜬다. 한 번 복구된 세션은 이후 tmux 세션(`local`)으로 관리된다.
- **복구가 새로 띄우는 tmux 서버는 자기 스코프(`claude-snap-tmux-*.scope`)에 둔다.** 호출한 쪽의 cgroup에 들어가면 그쪽이 멈추거나 재시작될 때 복구된 세션이 함께 죽는다. 서비스든 `claude-rc@` 세션 안의 Claude든 같다. tmux 서버가 이미 떠 있으면 그 서버에 창을 연다.
- **tmux 서버에 잠금 fd를 넘기지 않는다(`9>&-`).** 넘기면 서버가 사는 동안 잠금이 풀리지 않아 이후 저장이 전부 실패한다.
- **fish에 인자를 넘길 때 `--`를 붙인다.** 없으면 fish가 `--resume`을 자기 옵션으로 읽고 종료한다. fish를 거치는 이유는 `config.fish`의 PATH와 nvm Node를 세션에 물려주기 위해서다(`claude-rc-service`와 같다).
- **`pipefail` 아래에서 `… | grep -q`를 쓰지 않는다.** `grep -q`가 먼저 끝나면 앞 명령이 SIGPIPE로 141을 내고, 찾았는데도 실패로 판정된다.
- **리포트와 이력을 파일로 남긴다.** journal은 서버 TUI 출력(분당 수백 줄)에 밀려 이전 부팅 기록이 몇 시간 치만 남는다.
- **`After=claude-rc@obsidian.service claude-rc@snacks.service`** — 부팅 때는 서버가 먼저 떠야 서버 목록을 읽을 수 있고, 종료 때는 이 유닛이 서버보다 먼저 멈춰 최종 저장 때 서버 세션이 살아 있다. 서버 인스턴스를 늘리면 여기에 같이 적는다.

### 7. 주의

- ⚠️ **컴퓨터가 꺼져 있는 동안 보관한 세션은 다음 부팅 때 되살아난다.** 로컬에 신호가 남지 않기 때문이다. 앱 목록에 다시 뜨므로 한 번 더 보관하면 다음 저장에서 빠진다.
- ⚠️ **복구가 계속 실패하는 항목은 장부에 남아 부팅마다 다시 시도된다.** `status`의 실패 횟수와 리포트로 원인을 보고, 이어 갈 필요가 없으면 `drop`한다.
- ⚠️ **서버가 쉬고 있는 세션을 스스로 정리한다면 `ended`로 잘못 빠진다.** 아직 관측된 적은 없다. `events.log`의 `DROP … ended`가 손대지 않은 세션에 찍히면 이 경우다.
- ⚠️ **서버 목록 판단은 서버 화면 문구(`Capacity:` · `Continue coding` · `Code anywhere` · `code/session_…`)에 기대고 있다.** 문구가 바뀌면 서버가 맡은 세션을 못 찾아 그대로 복구하므로, 서버가 실제로 되살린 경우에만 같은 대화가 둘 뜬다.
- ⚠️ **이미 떠 있는 tmux 서버가 터미널(Konsole 탭 등)의 스코프에 있으면 복구한 창도 그 서버에 들어간다.** 그 터미널을 닫을 때 스코프가 정리되면 함께 죽을 수 있다. 확인: `cat /proc/$(tmux display -p '#{pid}')/cgroup`.
- 🚨 **`claude-rc@` 서버가 띄운 세션 안에서 `tmux`를 직접 처음 띄우면 그 tmux 서버가 `claude-rc@*.service`의 cgroup에 들어간다.** 서비스가 재시작되면 tmux 서버와 모든 창이 함께 죽는다. tmux 서버는 `claude-snap` 복구나 로그인 셸에서 처음 뜨게 한다.
- ⚠️ `~/.claude/sessions/*.json`과 대화 기록 형식은 Claude Code의 문서화되지 않은 내부 형식이다. 업데이트로 필드(`bridgeSessionId` · `procStart` · `tmux` · `permission-mode` · `custom-title` · `bridge-session`)가 바뀌면 저장이 비거나 판정이 틀어진다. `status`의 항목 수가 갑자기 0이 되거나 `events.log`에 이상한 `DROP`이 몰리면 이것부터 확인한다.
- 🚨 **tmux 안에서 테스트할 때 `TMUX_TMPDIR`로는 격리되지 않는다.** tmux 클라이언트는 `$TMUX`(지금 붙어 있는 서버)를 `TMUX_TMPDIR`보다 먼저 쓰므로, 격리한 줄 알고 실행한 `tmux kill-server`가 실제 서버와 그 안의 모든 세션을 끝낸다. 테스트는 `env -u TMUX tmux -L <전용 소켓>`으로만 하고, `kill-server`는 `-L` 없이 쓰지 않는다.
