## Claude Code Remote Control 상시 서버 (systemd user)

Dev PC가 부팅되면 작업 디렉터리마다 `claude remote-control` 서버를 하나씩 systemd user 서비스로 띄운다. claude.ai/code 또는 Claude 앱에서 붙으면 서버가 그 디렉터리 안에 세션을 온디맨드로 띄운다.

### 1. 구성

| 파일 | 설치 위치 | 역할 |
|:--|:--|:--|
| `claude-rc@.service` | `~/.config/systemd/user/` | 템플릿 유닛. 인스턴스 이름이 서버 이름 접미사가 된다 (`claude-rc@snacks` → 서버 `dev-snacks`) |
| `env/{인스턴스}.env` | `~/.config/claude-rc/` | 인스턴스별 작업 디렉터리 `WORKDIR` |

- `WORKDIR`은 절대경로로 적는다. `EnvironmentFile`은 `~`·`$HOME`을 풀지 않는다.
- 서버 이름 접두사 `dev`는 유닛의 `ExecStart`에 고정되어 있다. 다른 기기에 설치하면 그 값을 바꾼다.

### 2. 설치

사전 조건은 셋이다.

- `claude auth login`으로 claude.ai 구독 계정에 로그인되어 있다.
- 각 `WORKDIR`에서 `claude`를 한 번 실행해 workspace trust를 수락해 두었다.
- `claude remote-control`을 한 번 손으로 띄워 `Enable Remote Control? (y/n)`에 동의해 두었다. 이 동의는 디렉터리별이 아니라 계정 전역 값(`~/.claude.json`의 `remoteDialogSeen`)이다.

```sh
install -Dm644 claude-rc@.service ~/.config/systemd/user/claude-rc@.service
install -Dm644 -t ~/.config/claude-rc env/*.env
systemctl --user daemon-reload
systemctl --user enable --now claude-rc@obsidian claude-rc@snacks
loginctl enable-linger $USER    # 로그인하지 않아도 부팅 시 user 서비스가 뜨게 한다
```

### 3. 서버 추가·제거

```sh
# 추가 — 그 디렉터리의 workspace trust를 먼저 수락해 둔다
printf 'WORKDIR=%s\n' "$HOME/workspace/foo" > ~/.config/claude-rc/foo.env
systemctl --user enable --now claude-rc@foo

# 제거
systemctl --user disable --now claude-rc@foo
rm ~/.config/claude-rc/foo.env
```

### 4. 운영

```sh
systemctl --user status 'claude-rc@*'          # 상태
journalctl --user -u claude-rc@snacks -f       # 로그 (세션 URL도 여기 찍힌다)
systemctl --user restart claude-rc@snacks      # 서버 하나만 재시작
```

### 5. 설계 판단

- **fish를 거쳐 실행한다.** `config.fish`가 채우는 PATH(`~/.local/bin`)와 nvm의 Node 22를 서버와 온디맨드 세션에 물려주기 위해서다. 빠지면 세션 안에서 npx 기반 MCP 등이 깨진다. `ExecStart`의 `$$WORKDIR`는 systemd가 아니라 fish가 변수를 풀게 한다.
- **`Restart=always` + `RestartSec=30`** — 네트워크가 약 10분 끊기면 서버가 스스로 종료하므로, 종료 코드와 무관하게 30초 뒤 다시 띄운다. 다시 뜬 서버는 같은 environment ID로 등록되어 claude.ai 쪽 링크가 유지된다.
- **`StartLimitIntervalSec=0`** — 시도 제한을 걸면 부팅 직후 네트워크가 늦게 올라오는 날 서버가 영구 정지한다. 30초 간격이 재시도 폭주를 막는다(최대 분당 2회).
- **tmux를 쓰지 않는다.** tmux 안에 띄우면 systemd는 tmux를 띄운 스크립트의 종료만 보고 서버의 생사를 모른다. 서비스로 직접 돌리면 재기동·로그·개별 제어를 systemd가 맡는다. 대신 서버 TUI(상태 화면, `w` 실행 모드 토글)는 볼 수 없고, 실행 모드가 필요하면 `--spawn`으로 고정한다.

### 6. 주의

- 🚨 **`CLAUDE_CODE_OAUTH_TOKEN`이나 `claude setup-token` 토큰을 유닛 환경에 넣지 않는다.** Remote Control은 full-scope 로그인만 받으며 장기 토큰은 inference-only라 거부된다. 같은 사용자의 user 서비스는 `~/.claude/.credentials.json`을 그대로 쓴다.
- ⚠️ 같은 디렉터리에 다른 `claude remote-control`이 떠 있으면 한쪽이 "already being served by another instance"로 종료되고, 서비스 쪽은 30초마다 재시도를 반복한다.
- ⚠️ workspace trust가 없는 디렉터리는 서버가 기동 직후 종료되고 재시도만 반복한다. 원인은 `journalctl`에서 확인한다.
- ⚠️ 서버 TUI가 화면을 다시 그릴 때마다 안내 문구가 journal에 반복해 쌓이고, 제어 문자는 `[49B blob data]`처럼 찍힌다. 동작과는 무관하다.
