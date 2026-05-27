#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# health-sync.sh
#   Obsidian 일일 건강 일지(.md) → Airtable healthDB 동기화
#
# 사용: ./health-sync.sh /절대/경로/2026-05-27.md
# 의존: curl, jq  (없으면 자동 안내)
# 환경: 스크립트와 같은 디렉토리의 .env 에 AIRTABLE_API_KEY 정의
#       (AIRTABLE_API_KEY=xxx  또는  AIRTABLE_API_KEY: xxx  둘 다 OK)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ═════════════════════════════════════════════════════════════════
# 상수
# ═════════════════════════════════════════════════════════════════
readonly BASE_ID="apprww27axwE0jF5N"
readonly TBL_DAILY="tblejp9cdvVUiNV0R"
readonly TBL_ACTIVITY="tbllhZPtUasrUgcjr"
readonly TZ_KST="Asia/Seoul"
readonly TZ_OFFSET="+09:00"
readonly AIRTABLE_API_BASE="https://api.airtable.com/v0"

# 색상
C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
C_BLUE=$'\033[0;34m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'

err()  { echo "${C_RED}❌ $*${C_RESET}" >&2; }
warn() { echo "${C_YELLOW}⚠️  $*${C_RESET}" >&2; }
info() { echo "${C_BLUE}ℹ️  $*${C_RESET}" >&2; }
ok()   { echo "${C_GREEN}✅ $*${C_RESET}" >&2; }

usage() {
    cat <<'EOF'
사용법:
  health-sync.sh <일지 마크다운 절대경로>

예:
  ./health-sync.sh ~/Documents/work-vault/daily_note/2026/05/2026-05-27.md
EOF
}

# ═════════════════════════════════════════════════════════════════
# 사전 검증
# ═════════════════════════════════════════════════════════════════
check_dependencies() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v jq   >/dev/null 2>&1 || missing+=("jq")
    if [ ${#missing[@]} -gt 0 ]; then
        err "필요한 명령어 누락: ${missing[*]}"
        echo "" >&2
        echo "CachyOS / Arch 계열 설치:" >&2
        echo "  sudo pacman -S --needed ${missing[*]}" >&2
        exit 1
    fi
}

load_env() {
    local script_dir env_file
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    env_file="$script_dir/.env"

    if [ ! -f "$env_file" ]; then
        err ".env 파일이 $script_dir 에 없음"
        echo "다음 형식으로 만들 것:" >&2
        echo "  AIRTABLE_API_KEY=your_token_here" >&2
        exit 1
    fi

    AIRTABLE_API_KEY=$(
        grep -E '^[[:space:]]*AIRTABLE_API_KEY[[:space:]]*[:=]' "$env_file" \
            | head -1 \
            | sed -E 's/^[[:space:]]*AIRTABLE_API_KEY[[:space:]]*[:=][[:space:]]*//' \
            | sed -E 's/^["'\'']?//; s/["'\'']?[[:space:]]*$//' \
            | tr -d '\r'
    )

    if [ -z "${AIRTABLE_API_KEY:-}" ]; then
        err ".env의 AIRTABLE_API_KEY 값이 비어있음"
        exit 1
    fi
    export AIRTABLE_API_KEY
}

extract_date() {
    local filepath="$1" basename
    basename=$(basename "$filepath" .md)
    if [[ "$basename" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        warn "파일명에서 날짜 추출 실패 → KST 오늘 날짜 사용"
        TZ="$TZ_KST" date +%Y-%m-%d
    fi
}

# ═════════════════════════════════════════════════════════════════
# 변환 유틸
# ═════════════════════════════════════════════════════════════════

# "H:MM" → seconds.  빈 입력은 빈 문자열 반환.
hm_to_seconds() {
    local s="${1// /}"
    [ -z "$s" ] && { echo ""; return; }
    if [[ "$s" =~ ^([0-9]+):([0-9]+)$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 3600 + ${BASH_REMATCH[2]} * 60 ))
    else
        echo ""
    fi
}

# "HH:MM" + 날짜 → "YYYY-MM-DDTHH:MM:00+09:00"
hm_to_iso() {
    local date_str="$1" time_str="${2// /}"
    [ -z "$time_str" ] && { echo ""; return; }
    if [[ "$time_str" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
        printf "%sT%02d:%02d:00%s" "$date_str" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$TZ_OFFSET"
    else
        echo ""
    fi
}

# ═════════════════════════════════════════════════════════════════
# 마크다운 표 파싱
# ═════════════════════════════════════════════════════════════════

# 특정 섹션 패턴 이후의 첫 마크다운 표를 TAB 구분 행으로 출력
# (표 헤더 + 구분자 라인 제거, 데이터 행만)
extract_table_after() {
    local file="$1" pat="$2"
    awk -v pat="$pat" '
    BEGIN { in_section=0; in_table=0; header_seen=0 }
    {
        if (match($0, /^#+[[:space:]]+/)) {
            if (in_section && index($0, pat) == 0) exit
            if (index($0, pat) > 0) {
                in_section=1; in_table=0; header_seen=0
                next
            }
        }
        if (!in_section) next

        if ($0 ~ /^[[:space:]]*\|/) {
            in_table=1
            # 구분자 라인 (| --- | :--- | 등): 하이픈을 반드시 포함해야 함
            if ($0 ~ /^[[:space:]]*\|[[:space:]:|\-]+\|[[:space:]]*$/ && index($0, "-") > 0) next
            if (!header_seen) { header_seen=1; next }
            line=$0
            sub(/^[[:space:]]*\|/, "", line)
            sub(/\|[[:space:]]*$/, "", line)
            gsub(/\|/, "\t", line)
            print line
        } else if (in_table) {
            exit
        }
    }' "$file"
}

# 운동표 → TAB 구분 (종목 무게 횟수 세트 시간 칼로리 비고)
# 무게/횟수/세트/칼로리는 숫자만 추출. 종목/시간/비고는 텍스트.
parse_workout_rows() {
    local file="$1"
    extract_table_after "$file" "운동 관리" | awk -F'\t' '
    function clean(s) { gsub(/^[[:space:]]+/, "", s); gsub(/[[:space:]]+$/, "", s); return s }
    function num(s) {
        s = clean(s)
        if (match(s, /-?[0-9]+\.?[0-9]*/)) return substr(s, RSTART, RLENGTH)
        return ""
    }
    {
        for (i=1;i<=NF;i++) $i = clean($i)
        if ($1 == "" || $1 ~ /데일리[[:space:]]*누계/) next
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1, num($2), num($3), num($4), $5, num($6), $7
    }'
}

# 운동표의 "데일리 누계" 칼로리만 추출
parse_workout_total() {
    local file="$1"
    extract_table_after "$file" "운동 관리" | awk -F'\t' '
    function clean(s) { gsub(/^[[:space:]]+/, "", s); gsub(/[[:space:]]+$/, "", s); return s }
    function num(s) {
        s = clean(s)
        if (match(s, /-?[0-9]+\.?[0-9]*/)) return substr(s, RSTART, RLENGTH)
        return ""
    }
    {
        if (clean($1) ~ /데일리[[:space:]]*누계/) { print num($6); exit }
    }'
}

# 식단표 → key=value 라인들
parse_diet_table() {
    local file="$1"
    extract_table_after "$file" "식단 & 수분량 관리" | awk -F'\t' '
    function clean(s) { gsub(/^[[:space:]]+/, "", s); gsub(/[[:space:]]+$/, "", s); return s }
    function num(s) {
        s = clean(s)
        if (match(s, /-?[0-9]+\.?[0-9]*/)) return substr(s, RSTART, RLENGTH)
        return ""
    }
    {
        kind = clean($1)
        # 컬럼: 구분 | 내용 | 칼로리 | 탄 | 단 | 지 | 시간 | 수분
        if (kind=="아침" || kind=="점심" || kind=="저녁" || kind=="간식") {
            print kind"_kcal=" num($3)
            print kind"_carb=" num($4)
            print kind"_protein=" num($5)
            print kind"_fat=" num($6)
            print kind"_water=" num($8)
        } else if (kind=="수분") {
            print "row_수분_water=" num($8)
        } else if (kind=="토탈" || kind=="총계") {
            print "row_토탈_water=" num($8)
        }
    }'
}

parse_vitals_table() {
    local file="$1"
    extract_table_after "$file" "혈당 / 혈압" | awk -F'\t' '
    function clean(s) { gsub(/^[[:space:]]+/, "", s); gsub(/[[:space:]]+$/, "", s); return s }
    function num(s) {
        s = clean(s)
        if (match(s, /-?[0-9]+\.?[0-9]*/)) return substr(s, RSTART, RLENGTH)
        return ""
    }
    NR==1 {
        print "공복혈당=" num($1)
        print "수축기="   num($2)
        print "이완기="   num($3)
    }'
}

# 신체 수치 11개
parse_body_table() {
    local file="$1"
    extract_table_after "$file" "신체 수치 데이터" | awk -F'\t' '
    function clean(s) { gsub(/^[[:space:]]+/, "", s); gsub(/[[:space:]]+$/, "", s); return s }
    function num(s) {
        s = clean(s)
        if (match(s, /-?[0-9]+\.?[0-9]*/)) return substr(s, RSTART, RLENGTH)
        return ""
    }
    NR==1 {
        print "목="        num($1)
        print "어깨="      num($2)
        print "가슴="      num($3)
        print "허리="      num($4)
        print "엉덩이="    num($5)
        print "팔_L="      num($6)
        print "팔_R="      num($7)
        print "허벅지_L="  num($8)
        print "허벅지_R="  num($9)
        print "종아리_L="  num($10)
        print "종아리_R="  num($11)
    }'
}

# 수면 표
# 헤더: 기상시간 | 취침시간 | 총 수면시간 | 수면 총 시간 | 수면 중 깸 | 렘 | 얕은 | 깊은
# Airtable 매핑: 4번째 "수면 총 시간"만 사용(3번째는 중복)
parse_sleep_table() {
    local file="$1"
    extract_table_after "$file" "수면 데이터" | awk -F'\t' '
    function clean(s) { gsub(/^[[:space:]]+/, "", s); gsub(/[[:space:]]+$/, "", s); return s }
    NR==1 {
        print "기상시간_hm="  clean($1)
        print "취침시간_hm="  clean($2)
        # $3 "총 수면시간" 스킵 ($4 와 중복)
        print "수면총시간_hm=" clean($4)
        print "수면중깸_hm="  clean($5)
        print "렘수면_hm="    clean($6)
        print "얕은수면_hm="  clean($7)
        print "깊은수면_hm="  clean($8)
    }'
}

parse_notes() {
    local file="$1"
    awk '
    BEGIN { in_section=0 }
    /^###[[:space:]]+비고/ { in_section=1; next }
    /^#+[[:space:]]+/ && in_section { exit }
    in_section { print }
    ' "$file" | sed -E 's/^[[:space:]]*-[[:space:]]*//' | sed '/^[[:space:]]*$/d'
}

# kv 라인들에서 key 값 추출
kv_get() {
    local kvs="$1" key="$2"
    echo "$kvs" | grep -E "^${key}=" 2>/dev/null | head -1 | sed -E "s/^${key}=//" || true
}

# ═════════════════════════════════════════════════════════════════
# 칼로리 분배
# ═════════════════════════════════════════════════════════════════
# 입력: 운동행 (parse_workout_rows 출력)
# 정책:
#   - 무게 있고 본문 칼로리 비어있는 행 = 분배 대상
#   - 가중치 = 무게 × 횟수 × 세트
#   - 분배 잔량 = 데일리 누계 - (이미 명시된 무게있는 행의 칼로리 합)
allocate_calories() {
    local workout_lines="$1" total_kcal="$2"

    if [ -z "$workout_lines" ]; then
        echo ""
        return
    fi
    if [ -z "$total_kcal" ] || ! [[ "$total_kcal" =~ ^[0-9]+\.?[0-9]*$ ]] || \
       [ "$(awk -v t="$total_kcal" 'BEGIN{print (t+0)<=0}')" = "1" ]; then
        echo "$workout_lines"
        return
    fi

    echo "$workout_lines" | awk -F'\t' -v total="$total_kcal" '
    {
        lines[NR] = $0
        n_weight[NR]  = ($2 == "") ? 0 : ($2 + 0)
        n_reps[NR]    = ($3 == "") ? 0 : ($3 + 0)
        n_sets[NR]    = ($4 == "") ? 0 : ($4 + 0)
        s_kcal[NR]    = $6
        has_w[NR]     = (n_weight[NR] > 0)
        has_kcal[NR]  = ($6 != "")

        if (has_w[NR] && has_kcal[NR]) {
            allocated += ($6 + 0)
        }
        if (has_w[NR] && !has_kcal[NR]) {
            target_count++
            w = n_weight[NR] * n_reps[NR] * n_sets[NR]
            if (w <= 0) w = 1   # 무게는 있는데 reps/sets 누락 시 균등 fallback
            tw[NR] = w
            weight_sum += w
        }
    }
    END {
        remaining = total - allocated
        for (i=1; i<=NR; i++) {
            if (has_w[i] && !has_kcal[i] && remaining > 0 && weight_sum > 0) {
                share = remaining * (tw[i] / weight_sum)
                share = int(share * 10 + 0.5) / 10
                n = split(lines[i], cells, "\t")
                cells[6] = share
                out = cells[1]
                for (j=2; j<=n; j++) out = out "\t" cells[j]
                print out
            } else {
                print lines[i]
            }
        }
    }'
}

# ═════════════════════════════════════════════════════════════════
# JSON 빌드 (Airtable fields)
# ═════════════════════════════════════════════════════════════════

# emit: field<TAB>value<TAB>type (num/int/str). 빈 값은 안 내보냄.
emit() {
    local field="$1" value="$2" type="${3:-str}"
    [ -z "$value" ] && return
    printf '%s\t%s\t%s\n' "$field" "$value" "$type"
}

# emit 라인들 → JSON object
emits_to_json() {
    jq -Rn '
        [inputs | split("\t") | {f: .[0], v: .[1], t: .[2]}]
        | map(
            if .t == "num"   then {(.f): (.v | tonumber)}
            elif .t == "int" then {(.f): (.v | tonumber | floor)}
            else                  {(.f): .v}
            end
          )
        | add // {}
    '
}

build_daily_fields() {
    local date_str="$1" diet_kv="$2" vitals_kv="$3" body_kv="$4" sleep_kv="$5" notes="$6"

    local base
    base=$( {
        emit "날짜" "$date_str" str

        # 식단 4끼
        for meal in 아침 점심 저녁 간식; do
            emit "${meal} 칼로리 섭취량"    "$(kv_get "$diet_kv" "${meal}_kcal")"    num
            emit "${meal} 탄수화물 섭취량" "$(kv_get "$diet_kv" "${meal}_carb")"    num
            emit "${meal} 단백질 섭취량"    "$(kv_get "$diet_kv" "${meal}_protein")" num
            emit "${meal} 지방 섭취량"      "$(kv_get "$diet_kv" "${meal}_fat")"     num
        done

        # 수분 보충량: 토탈 행 우선 → 수분 행 → 끼니별 합산
        local water
        water="$(kv_get "$diet_kv" "row_토탈_water")"
        if [ -z "$water" ]; then
            water="$(kv_get "$diet_kv" "row_수분_water")"
        fi
        if [ -z "$water" ]; then
            water=$(echo "$diet_kv" | grep -E '_water=' | grep -v '^row_' \
                | sed -E 's/.*=//' \
                | awk '$1!=""{s+=$1} END {if (s>0) printf "%g", s}')
        fi
        emit "수분 보충량" "$water" num

        # 혈당/혈압
        emit "공복 혈당"   "$(kv_get "$vitals_kv" "공복혈당")" num
        emit "오전 수축기" "$(kv_get "$vitals_kv" "수축기")"   num
        emit "오전 이완기" "$(kv_get "$vitals_kv" "이완기")"   num

        # 신체 수치
        emit "신체 - 목"        "$(kv_get "$body_kv" "목")"       num
        emit "신체 - 어깨"      "$(kv_get "$body_kv" "어깨")"     num
        emit "신체 - 가슴"      "$(kv_get "$body_kv" "가슴")"     num
        emit "신체 - 허리"      "$(kv_get "$body_kv" "허리")"     num
        emit "신체 - 엉덩이"    "$(kv_get "$body_kv" "엉덩이")"   num
        emit "신체 - 팔(L)"     "$(kv_get "$body_kv" "팔_L")"     num
        emit "신체 - 팔(R)"     "$(kv_get "$body_kv" "팔_R")"     num
        emit "신체 - 허벅지(L)" "$(kv_get "$body_kv" "허벅지_L")" num
        emit "신체 - 허벅지(R)" "$(kv_get "$body_kv" "허벅지_R")" num
        emit "신체 - 종아리(L)" "$(kv_get "$body_kv" "종아리_L")" num
        emit "신체 - 종아리(R)" "$(kv_get "$body_kv" "종아리_R")" num

        # 수면 시각 (dateTime)
        emit "기상시간" "$(hm_to_iso "$date_str" "$(kv_get "$sleep_kv" "기상시간_hm")")" str
        emit "취침시간" "$(hm_to_iso "$date_str" "$(kv_get "$sleep_kv" "취침시간_hm")")" str

        # 수면 duration (초)
        emit "수면 총 시간" "$(hm_to_seconds "$(kv_get "$sleep_kv" "수면총시간_hm")")" int
        emit "수면 중 깸"   "$(hm_to_seconds "$(kv_get "$sleep_kv" "수면중깸_hm")")"   int
        emit "렘 수면"      "$(hm_to_seconds "$(kv_get "$sleep_kv" "렘수면_hm")")"     int
        emit "얕은 수면"    "$(hm_to_seconds "$(kv_get "$sleep_kv" "얕은수면_hm")")"   int
        emit "깊은 수면"    "$(hm_to_seconds "$(kv_get "$sleep_kv" "깊은수면_hm")")"   int

        # 비고는 multiline 가능성 있어 emit 안 거치고 아래서 별도 주입
    } | emits_to_json )

    if [ -n "$notes" ]; then
        echo "$base" | jq --arg n "$notes" '. + {"비고": $n}'
    else
        echo "$base"
    fi
}

# 운동행 → activity_log records 배열 (JSON)
build_activity_records() {
    local date_str="$1" workout_rows="$2"
    local datetime_str="${date_str}T00:00:00${TZ_OFFSET}"

    if [ -z "$workout_rows" ]; then
        echo "[]"
        return
    fi

    echo "$workout_rows" | jq -Rn --arg dt "$datetime_str" '
        [
          inputs
          | split("\t")
          | . as $c
          | {
              jongmok: ($c[0] // "" | gsub("^\\s+|\\s+$"; "")),
              muge:    ($c[1] // "" | gsub("\\s"; "")),
              hoesu:   ($c[2] // "" | gsub("\\s"; "")),
              set:     ($c[3] // "" | gsub("\\s"; "")),
              kcal:    ($c[5] // "" | gsub("\\s"; "")),
              bigo:    ($c[6] // "" | gsub("^\\s+|\\s+$"; ""))
            }
          | select(.jongmok != "")
        ]
        | map({
            fields: (
              {"실행일시": $dt, "종목명": .jongmok}
              + (if .muge  != "" then {"무게":        (.muge  | tonumber)} else {} end)
              + (if .hoesu != "" then {"횟수":        (.hoesu | tonumber)} else {} end)
              + (if .set   != "" then {"세트":        (.set   | tonumber)} else {} end)
              + (if .kcal  != "" then {"소모 칼로리": (.kcal  | tonumber)} else {} end)
              + (if .bigo  != "" then {"비고": .bigo} else {} end)
            )
          })
    '
}

# ═════════════════════════════════════════════════════════════════
# Airtable API
# ═════════════════════════════════════════════════════════════════
api_call() {
    local method="$1" url="$2" body="${3:-}"
    local args=(-sS -X "$method" -H "Authorization: Bearer $AIRTABLE_API_KEY")
    if [ -n "$body" ]; then
        args+=(-H "Content-Type: application/json" --data-raw "$body")
    fi
    curl "${args[@]}" "$url"
}

# URL-encode (jq 사용)
urlencode() { jq -rn --arg s "$1" '$s | @uri'; }

fetch_daily_by_date() {
    local date_str="$1" formula encoded
    formula="{날짜}=\"$date_str\""
    encoded=$(urlencode "$formula")
    api_call GET "${AIRTABLE_API_BASE}/${BASE_ID}/${TBL_DAILY}?filterByFormula=${encoded}"
}

fetch_activity_by_date() {
    local date_str="$1" formula encoded
    formula="DATETIME_FORMAT({실행일시}, 'YYYY-MM-DD')=\"$date_str\""
    encoded=$(urlencode "$formula")
    api_call GET "${AIRTABLE_API_BASE}/${BASE_ID}/${TBL_ACTIVITY}?filterByFormula=${encoded}&pageSize=100"
}

# ═════════════════════════════════════════════════════════════════
# 미리보기
# ═════════════════════════════════════════════════════════════════
print_preview() {
    local date_str="$1" daily_fields="$2" activity_records="$3" existing_daily="$4"

    echo ""
    echo "${C_BOLD}═══ 일일 건강 로그 ($date_str) ═══${C_RESET}"

    local existing_id existing_fields
    existing_id=$(echo "$existing_daily" | jq -r '.records[0].id // empty')
    existing_fields=$(echo "$existing_daily" | jq '.records[0].fields // {}')

    if [ -n "$existing_id" ]; then
        echo "모드: ${C_YELLOW}PATCH${C_RESET} (기존 record: $existing_id)"
        echo ""
        echo "${C_BOLD}변경 사항:${C_RESET}"

        # diff (formula/시스템 필드 제외 위해 새 필드 키 기준)
        echo "$daily_fields" | jq -r --argjson old "$existing_fields" '
            to_entries | sort_by(.key)[] |
            . as $new |
            ($old[$new.key] // null) as $old_val |
            if $old_val == null then
                "ADD\t\($new.key)\t\($new.value)"
            elif ($old_val | tostring) == ($new.value | tostring) then
                "SAME\t\($new.key)\t\($new.value)"
            else
                "MOD\t\($new.key)\t\($old_val | tostring)\t\($new.value | tostring)"
            end
        ' | while IFS=$'\t' read -r kind field a b; do
            case "$kind" in
                ADD)  printf "  ${C_GREEN}+ %s: %s${C_RESET}\n"        "$field" "$a" ;;
                SAME) printf "  ${C_DIM}= %s: %s${C_RESET}\n"          "$field" "$a" ;;
                MOD)  printf "  ${C_YELLOW}~ %s: %s → %s${C_RESET}\n"  "$field" "$a" "$b" ;;
            esac
        done

        # 기존엔 있지만 일지엔 없는 필드 (보존됨) - formula/시스템 제외
        local preserved
        preserved=$(echo "$daily_fields" | jq -r --argjson old "$existing_fields" '
            (($old | keys) - (. | keys))[]
        ' 2>/dev/null | grep -v -E '^(\[f\]|created_at|modified_at)' || true)
        if [ -n "$preserved" ]; then
            echo ""
            echo "${C_DIM}일지에 없어 기존값 유지:${C_RESET}"
            echo "$preserved" | while read -r f; do
                local v
                v=$(echo "$existing_fields" | jq -r --arg k "$f" '.[$k] | tostring')
                printf "  ${C_DIM}· %s: %s${C_RESET}\n" "$f" "$v"
            done
        fi
    else
        echo "모드: ${C_GREEN}CREATE${C_RESET} (신규)"
        echo ""
        echo "${C_BOLD}전송 필드:${C_RESET}"
        echo "$daily_fields" | jq -r 'to_entries | sort_by(.key)[] | "  + \(.key): \(.value)"'
    fi

    # activity_log
    local rec_count
    rec_count=$(echo "$activity_records" | jq 'length')
    echo ""
    echo "${C_BOLD}═══ activity_log ($rec_count 건) ═══${C_RESET}"
    if [ "$rec_count" -eq 0 ]; then
        echo "  (없음)"
    else
        echo "$activity_records" | jq -r '
            to_entries | .[] |
            "  \(.key + 1). \(.value.fields["종목명"] // "?")"
            + " | 무게 \(.value.fields["무게"] // "-")kg"
            + " × \(.value.fields["횟수"] // "-")회"
            + " × \(.value.fields["세트"] // "-")세트"
            + " | \(.value.fields["소모 칼로리"] // "-")kcal"
            + (if (.value.fields["비고"] // "") != "" then " | \(.value.fields["비고"])" else "" end)
        '
        echo ""
        warn "이 날짜의 기존 activity_log는 모두 삭제 후 재삽입됨"
    fi
}

# ═════════════════════════════════════════════════════════════════
# 전송
# ═════════════════════════════════════════════════════════════════
sync_daily() {
    local fields_json="$1" existing="$2"
    local existing_id resp body

    existing_id=$(echo "$existing" | jq -r '.records[0].id // empty')

    if [ -n "$existing_id" ]; then
        body=$(jq -n --arg id "$existing_id" --argjson f "$fields_json" \
            '{records: [{id: $id, fields: $f}]}')
        resp=$(api_call PATCH "${AIRTABLE_API_BASE}/${BASE_ID}/${TBL_DAILY}" "$body")
    else
        body=$(jq -n --argjson f "$fields_json" '{records: [{fields: $f}]}')
        resp=$(api_call POST "${AIRTABLE_API_BASE}/${BASE_ID}/${TBL_DAILY}" "$body")
    fi

    if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
        err "일일 건강 로그 전송 실패:"
        echo "$resp" | jq . >&2
        return 1
    fi

    local new_id
    new_id=$(echo "$resp" | jq -r '.records[0].id')
    if [ -n "$existing_id" ]; then
        ok "일일 건강 로그 업데이트 완료 ($new_id)"
    else
        ok "일일 건강 로그 생성 완료 ($new_id)"
    fi
}

sync_activities() {
    local date_str="$1" records_json="$2"

    # 1. 기존 그 날짜 row 조회
    local existing existing_ids count
    existing=$(fetch_activity_by_date "$date_str")
    if echo "$existing" | jq -e '.error' >/dev/null 2>&1; then
        err "activity_log 조회 실패:"
        echo "$existing" | jq . >&2
        return 1
    fi
    existing_ids=$(echo "$existing" | jq -r '.records[].id')

    # 2. 삭제 (10개씩 batch)
    if [ -n "$existing_ids" ]; then
        count=$(echo "$existing_ids" | wc -l | tr -d ' ')
        info "기존 activity_log $count건 삭제 중"
        # 10개씩 모아서 ?records[]=...&records[]=... 쿼리스트링
        local params="" del_count=0 resp
        while IFS= read -r id; do
            [ -z "$id" ] && continue
            params+="&records[]=${id}"
            del_count=$((del_count + 1))
            if [ $((del_count % 10)) -eq 0 ]; then
                resp=$(api_call DELETE "${AIRTABLE_API_BASE}/${BASE_ID}/${TBL_ACTIVITY}?${params:1}")
                if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
                    err "activity_log 삭제 실패:"
                    echo "$resp" | jq . >&2
                    return 1
                fi
                params=""
            fi
        done <<< "$existing_ids"
        # 남은 것
        if [ -n "$params" ]; then
            resp=$(api_call DELETE "${AIRTABLE_API_BASE}/${BASE_ID}/${TBL_ACTIVITY}?${params:1}")
            if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
                err "activity_log 삭제 실패:"
                echo "$resp" | jq . >&2
                return 1
            fi
        fi
    fi

    # 3. 신규 batch insert (10개씩)
    local rec_count
    rec_count=$(echo "$records_json" | jq 'length')
    if [ "$rec_count" -eq 0 ]; then
        info "추가할 activity 없음"
        return
    fi

    info "신규 activity_log $rec_count건 생성 중"
    local i=0 batch body resp
    while [ "$i" -lt "$rec_count" ]; do
        batch=$(echo "$records_json" | jq --argjson s "$i" '.[$s:$s+10]')
        body=$(jq -n --argjson r "$batch" '{records: $r}')
        resp=$(api_call POST "${AIRTABLE_API_BASE}/${BASE_ID}/${TBL_ACTIVITY}" "$body")
        if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
            err "activity_log 생성 실패:"
            echo "$resp" | jq . >&2
            return 1
        fi
        i=$((i + 10))
    done
    ok "activity_log 동기화 완료 ($rec_count건)"
}

# ═════════════════════════════════════════════════════════════════
# main
# ═════════════════════════════════════════════════════════════════
main() {
    if [ $# -ne 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        usage
        exit 1
    fi

    local filepath="$1"
    if [ ! -f "$filepath" ]; then
        err "파일 없음: $filepath"
        exit 1
    fi

    check_dependencies
    load_env

    local date_str
    date_str=$(extract_date "$filepath")
    info "동기화 대상 날짜: $date_str"

    # 파싱
    local workout_rows workout_total
    workout_rows=$(parse_workout_rows "$filepath" || true)
    workout_total=$(parse_workout_total "$filepath" || true)
    workout_rows=$(allocate_calories "$workout_rows" "$workout_total")

    local diet_kv vitals_kv body_kv sleep_kv notes
    diet_kv=$(parse_diet_table "$filepath" || true)
    vitals_kv=$(parse_vitals_table "$filepath" || true)
    body_kv=$(parse_body_table "$filepath" || true)
    sleep_kv=$(parse_sleep_table "$filepath" || true)
    notes=$(parse_notes "$filepath" || true)

    # JSON 빌드
    local daily_fields activity_records
    daily_fields=$(build_daily_fields "$date_str" "$diet_kv" "$vitals_kv" "$body_kv" "$sleep_kv" "$notes")
    activity_records=$(build_activity_records "$date_str" "$workout_rows")

    # 기존 row 조회
    local existing_daily
    existing_daily=$(fetch_daily_by_date "$date_str")
    if echo "$existing_daily" | jq -e '.error' >/dev/null 2>&1; then
        err "일일 건강 로그 조회 실패:"
        echo "$existing_daily" | jq . >&2
        exit 1
    fi

    # 미리보기
    print_preview "$date_str" "$daily_fields" "$activity_records" "$existing_daily"

    # 확인
    echo ""
    read -rp "전송할까요? (Y/n): " answer
    answer=${answer:-Y}
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        warn "취소됨"
        exit 0
    fi

    # 전송
    sync_daily "$daily_fields" "$existing_daily"
    sync_activities "$date_str" "$activity_records"

    ok "동기화 완료"
}

main "$@"
