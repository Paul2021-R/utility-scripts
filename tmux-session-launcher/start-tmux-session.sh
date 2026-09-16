#!/usr/bin/env bash
# start-tmux-session.sh
#
# 부팅 시(systemd user unit `start-tmux-session.service`) 작업용 tmux 세션을
# detach 상태로 띄운다. Claude 세션은 표시 이름(-n)과 Remote Control 이름을
# 같은 값으로 붙여 기동하므로 claude.ai 세션 목록과 tmux 세션이 1:1 로 대응한다.
#
#   Claude 세션 이름: {NAME_PREFIX}-{tmux세션}-{YYYYMMDD}
#                     예) dev-obsidian-claude-1-20260917
#
# 붙으려면 tmux attach -t obsidian-claude-1, 세션 사이 이동은 Ctrl-b s 다.
#
# ⚠️ 세션 이름의 날짜는 tmux 세션이 처음 만들어진 시점으로 고정된다.
#    갱신하려면 tmux kill-session -t <이름> 뒤에 이 스크립트를 다시 실행한다.
#    이미 떠 있는 세션은 건너뛰므로 그 세션만 새 날짜로 다시 뜬다.

set -u

# ── 설정 ────────────────────────────────────────────────
NAME_PREFIX="dev"                        # 기기 태그. 폰 쪽 런처는 phone 을 쓴다
REMOTE_CONTROL="${REMOTE_CONTROL:-1}"    # 1: claude 세션에 --remote-control 을 붙인다
KEEP_SHELL="${KEEP_SHELL:-1}"            # 1: 명령이 끝나도 창을 닫지 않고 셸을 남긴다
CLAUDE_ARGS=""                           # 모든 claude 세션에 공통으로 붙일 옵션 (예: "--model opus")

# 형식: "tmux세션|작업디렉터리|명령[|추가옵션]"
#
#   명령이 정확히 `claude` 이면 -n / --remote-control / CLAUDE_ARGS / 추가옵션을
#   조립해서 실행한다. 그 외 명령(`claude --continue` 처럼 인자가 붙은 것 포함)은
#   세 번째 필드부터 끝까지 적힌 그대로 실행한다.
SESSIONS=(
    "opencode-web|$HOME|opencode web --hostname 127.0.0.1 --port 4096"
    "obsidian-claude-1|$HOME/workspace/obsidian/work-vault|claude"
    "obsidian-claude-2|$HOME/workspace/obsidian/work-vault|claude"
    "snack-claude-1|$HOME/workspace/snacks|claude"
    "snack-claude-2|$HOME/workspace/snacks|claude"
    "snack-claude-3|$HOME/workspace/snacks|claude"

    # 필요할 때 아래처럼 추가
    # "snack-claude-4|$HOME/workspace/snacks|claude|--model opus"   # 이 세션만 추가 옵션
    # "codex|$HOME/projects/backend|codex"
    # "server|$HOME/projects/backend|npm run dev"
    # "monitor|$HOME|btop"
)
# ────────────────────────────────────────────────────────

# systemd user 서비스의 PATH 에는 ~/.local/bin 이 없다. 지금까지는 tmux 가 fish -c 로
# 명령을 돌리면서 fish 설정이 PATH 를 채워 준 덕에 동작했지만, 이 스크립트 안의
# 사전 점검과 tmux 서버 환경은 그 혜택을 받지 못하므로 직접 붙인다.
export PATH="$HOME/.local/bin:$PATH"

usage() {
    cat <<USAGE
사용법: $(basename "$0") [옵션]

  --dry-run              tmux 를 실행하지 않고 조립된 명령만 출력한다
  --no-remote-control    claude 세션에 --remote-control 을 붙이지 않는다
  -h, --help             이 도움말

환경변수로도 같은 값을 줄 수 있다: REMOTE_CONTROL=0 KEEP_SHELL=0 $(basename "$0")
USAGE
}

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)            DRY_RUN=1 ;;
        --no-remote-control)  REMOTE_CONTROL=0 ;;
        -h|--help)            usage; exit 0 ;;
        *) echo "[ERROR] 알 수 없는 옵션: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

if ! command -v tmux >/dev/null 2>&1; then
    echo "[ERROR] tmux 가 설치되어 있지 않다." >&2
    exit 1
fi

TODAY="$(date +%Y%m%d)"
LOGIN_SHELL="$(getent passwd "$(id -u)" | cut -d: -f7)"
LOGIN_SHELL="${LOGIN_SHELL:-/bin/bash}"   # 호출자의 $SHELL 에 의존하지 않도록 로그인 셸로 고정한다


# `claude` 키워드를 실제 명령줄로 조립한다.
build_claude_command() {
    local session="$1" extra="$2"
    local name="${NAME_PREFIX}-${session}-${TODAY}"
    local cmd="claude -n '${name}'"

    if [[ "$REMOTE_CONTROL" == "1" ]]; then
        cmd+=" --remote-control '${name}'"
    fi
    [[ -n "$CLAUDE_ARGS" ]] && cmd+=" ${CLAUDE_ARGS}"
    [[ -n "$extra" ]]       && cmd+=" ${extra}"

    printf '%s' "$cmd"
}


start_session() {
    local entry="$1"
    local session workdir rest command extra=""

    IFS='|' read -r session workdir rest <<< "$entry"

    # 세 번째 필드가 `claude` 키워드일 때만 네 번째 필드를 추가옵션으로 본다.
    # 그 외에는 `|` 가 섞여 있어도 세 번째 필드부터 통째로 명령이다.
    command="${rest%%|*}"
    [[ "$rest" == *"|"* ]] && extra="${rest#*|}"

    # '=' 접두사는 완전 일치 조회다. 붙이지 않으면 snack-claude-1 조회가
    # snack-claude-10 같은 다른 세션에 걸려 기동이 조용히 생략된다.
    if tmux has-session -t "=${session}" 2>/dev/null; then
        echo "[SKIP] ${session} 은 이미 떠 있다"
        return
    fi

    if [[ ! -d "$workdir" ]]; then
        echo "[ERROR] ${session}: 작업 디렉터리가 없다: ${workdir}" >&2
        return
    fi

    if [[ "$command" == "claude" ]]; then
        if ! command -v claude >/dev/null 2>&1; then
            echo "[ERROR] ${session}: claude 실행 파일을 PATH 에서 찾지 못했다" >&2
            return
        fi
        command="$(build_claude_command "$session" "$extra")"
    else
        command="$rest"
    fi

    # 명령이 끝나도 창을 남겨 두면 종료 원인(오류 출력)을 볼 수 있고
    # 그 자리에서 바로 다시 띄울 수 있다. tmux 가 default-shell(fish)의 -c 로
    # 이 문자열을 돌리므로 sh / fish 양쪽에서 같은 뜻인 문법만 쓴다.
    if [[ "$KEEP_SHELL" == "1" ]]; then
        command+="; exec ${LOGIN_SHELL}"
    fi

    echo "[START] ${session}"
    echo "        dir: ${workdir}"
    echo "        cmd: ${command}"

    if [[ "$DRY_RUN" == "1" ]]; then
        return
    fi

    tmux new-session \
        -d \
        -s "$session" \
        -c "$workdir" \
        "$command"
}


for entry in "${SESSIONS[@]}"; do
    start_session "$entry"
done

if [[ "$DRY_RUN" == "1" ]]; then
    echo "[DRY-RUN] 실제로 실행하지 않았다"
    exit 0
fi

echo "준비된 tmux 세션:"
tmux list-sessions -F '  #{session_name}: #{session_windows} window(s)' 2>/dev/null
