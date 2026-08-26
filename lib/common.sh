#!/usr/bin/env bash
# 공통 출력, 오류, 경로 유틸.

set -o pipefail

HO_COLOR="${HO_COLOR:-auto}"

_ho_tty() { [ -t 2 ]; }
_ho_use_color() {
  case "$HO_COLOR" in
    always) return 0 ;;
    never) return 1 ;;
    *) _ho_tty ;;
  esac
}

ho_say()  { printf '%s\n' "$*" >&2; }
ho_info() { if _ho_use_color; then printf '\033[36m%s\033[0m\n' "$*" >&2; else printf '%s\n' "$*" >&2; fi; }
ho_warn() { if _ho_use_color; then printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; else printf 'warn: %s\n' "$*" >&2; fi; }
ho_err()  { if _ho_use_color; then printf '\033[31merror:\033[0m %s\n' "$*" >&2; else printf 'error: %s\n' "$*" >&2; fi; }
ho_ok()   { if _ho_use_color; then printf '\033[32m%s\033[0m\n' "$*" >&2; else printf '%s\n' "$*" >&2; fi; }

ho_die() { ho_err "$*"; exit 1; }

# 중단은 종료코드 3 (전송 전 사전조건 실패). 재시도가 안전하다는 뜻.
ho_abort() { ho_err "$*"; exit 3; }

ho_now_epoch() { date +%s; }
ho_now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# 사람이 읽는 용량
ho_human_bytes() {
  local b="${1:-0}"
  if [ "$b" -ge 1073741824 ] 2>/dev/null; then
    printf '%s' "$(echo "$b" | awk '{printf "%.1fG", $1/1073741824}')"
  elif [ "$b" -ge 1048576 ] 2>/dev/null; then
    printf '%s' "$(echo "$b" | awk '{printf "%.1fM", $1/1048576}')"
  elif [ "$b" -ge 1024 ] 2>/dev/null; then
    printf '%s' "$(echo "$b" | awk '{printf "%.1fK", $1/1024}')"
  else
    printf '%sB' "$b"
  fi
}

# 프로젝트 루트: git 최상위가 있으면 그것, 없으면 인자 경로 자체.
ho_project_root() {
  local dir="${1:-$PWD}" top
  if top="$(cd "$dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s' "$top"
  else
    (cd "$dir" && pwd)
  fi
}

# 이 경로를 프로젝트 루트로 넘겨도 되는가.
#
# git 레포가 아니면 루트 판정이 그냥 cwd 가 되는데, ~/projects 처럼 여러 프로젝트를
# 담는 상위 폴더에서 실행하면 그 아래 전부가 전송 대상이 된다(실사용에서 발생).
# 하위에 git 레포가 여러 개 보이면 컨테이너로 보고 거부한다.
# 반환 0 = 넘겨도 됨, 1 = 컨테이너로 보임(stdout 에 발견한 레포 수)
ho_project_root_is_sane() {
  local root="$1" n
  # git 레포면 경계가 명확하므로 통과
  (cd "$root" 2>/dev/null && git rev-parse --show-toplevel >/dev/null 2>&1) && return 0
  # 바로 아래에 .git 을 가진 디렉터리가 2개 이상이면 프로젝트 모음이다
  n="$(find "$root" -mindepth 2 -maxdepth 2 -name .git -maxdepth 2 2>/dev/null | head -20 | grep -c . || true)"
  [ "${n:-0}" -lt 2 ] && return 0
  printf '%s' "$n"
  return 1
}

# Claude 세션 디렉터리 slug: 절대경로의 / 를 - 로.
ho_session_slug() {
  printf '%s' "$1" | sed -e 's#/#-#g'
}

ho_session_dir() {
  printf '%s/.claude/projects/%s' "$HOME" "$(ho_session_slug "$1")"
}

# 파일 mtime (epoch). macOS/BSD stat.
ho_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || printf '0'
}

# 경과 일수
ho_age_days() {
  local mt now
  mt="$(ho_mtime "$1")"
  now="$(ho_now_epoch)"
  [ "$mt" -gt 0 ] 2>/dev/null || { printf '0'; return; }
  printf '%s' $(( (now - mt) / 86400 ))
}

# y/N 확인. HO_ASSUME_YES=1 이면 자동 승인, HO_ASSUME_NO=1 이면 자동 거절.
ho_confirm() {
  local prompt="$1" ans
  if [ "${HO_ASSUME_YES:-0}" = "1" ]; then ho_say "$prompt [y/N] y (auto)"; return 0; fi
  if [ "${HO_ASSUME_NO:-0}" = "1" ]; then ho_say "$prompt [y/N] n (auto)"; return 1; fi
  if ! _ho_tty; then
    # 대화형이 아니면 확인을 통과시킬 수 없다. 파괴적 동작 앞에서는 거절이 안전하다.
    ho_err "확인이 필요하지만 대화형 입력이 없습니다: $prompt"
    return 1
  fi
  printf '%s [y/N] ' "$prompt" >&2
  read -r ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# glob 패턴 목록 중 하나라도 경로에 매칭되는지.
# 패턴에 / 가 있으면 경로 전체와, 없으면 basename 과 비교한다.
ho_matches_any() {
  local path="$1"; shift
  local base pat
  base="$(basename "$path")"
  for pat in "$@"; do
    [ -z "$pat" ] && continue
    case "$pat" in
      */*) case "$path" in $pat) return 0 ;; esac ;;
      *)   case "$base" in $pat) return 0 ;; esac
           case "$path" in $pat) return 0 ;; esac ;;
    esac
  done
  return 1
}

# 원격 셸에 값을 넘길 때 쓰는 안전한 인용. 작은따옴표를 닫고 이스케이프한 뒤 다시 연다.
# 경로에 작은따옴표나 셸 메타문자가 있어도 원격에서 임의 명령이 실행되지 않는다.
ho_shq() {
  local s="$1"
  printf "'%s'" "$(printf '%s' "$s" | sed "s/'/'\\\\''/g")"
}

# 원격 에이전트 이름을 herdr 규칙에 맞춰 만든다.
# ho_agent_label <basename> <hash8>
#
# herdr 는 소문자로 시작하고 [a-z0-9_-] 만 쓰는 1-32자 이름만 받는다.
# basename 을 그대로 붙이면 조금만 길어도 agent start 가 invalid_agent_name 으로
# 거부해 기동이 통째로 실패한다(실기계 확인: codex-trust-verify, 26자에서 재현).
# 해시 8자는 같은 이름의 다른 프로젝트를 가르는 유일한 수단이라 줄이지 않는다.
# 남는 예산 15자에 맞춰 이름 쪽만 자른다.
ho_agent_label() {
  local base="$1" tag="$2" slug
  slug="$(printf '%s' "$base" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed -e 's/[^a-z0-9_-]/-/g')"
  slug="${slug:0:15}"
  # 잘린 끝이 구분자로 끝나면 해시와 붙어 읽기 어렵다. 떼어낸다.
  slug="${slug%"${slug##*[!-_]}"}"
  # 이름이 전부 비ASCII 였으면 남는 게 없다. 그때는 해시만으로 구분한다.
  [ -n "$slug" ] || slug="p"
  printf 'handoff-%s-%s' "$slug" "$tag"
}

# 사용자 제공 패턴이 셸에 그대로 들어가도 안전한지 검사한다.
# 허용: 영숫자, 점, 밑줄, 하이픈, 슬래시, 별표, 물음표, 대괄호.
ho_is_safe_pattern() {
  case "$1" in
    *[\'\"\`\$\;\&\|\<\>\(\)\{\}\!$'\n']*) return 1 ;;
    *) return 0 ;;
  esac
}

# ISO8601(UTC) 시각 이후 경과 시간을 사람이 읽는 형태로 (AC14).
ho_elapsed_since() {
  local iso="$1"
  [ -n "$iso" ] || { printf '알 수 없음'; return; }
  python3 - "$iso" <<'PYEOF'
import datetime, sys
try:
    t = datetime.datetime.strptime(sys.argv[1], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
except Exception:
    print('알 수 없음'); raise SystemExit(0)
sec = int((datetime.datetime.now(datetime.timezone.utc) - t).total_seconds())
if sec < 0: sec = 0
if sec < 60: print('%d초' % sec)
elif sec < 3600: print('%d분' % (sec // 60))
elif sec < 86400: print('%d시간 %d분' % (sec // 3600, (sec % 3600) // 60))
else: print('%d일 %d시간' % (sec // 86400, (sec % 86400) // 3600))
PYEOF
}

# 세션 uuid 형식 검증. 리스와 환경변수 모두 프로젝트가 만질 수 있으므로
# 경로 조립과 원격 명령에 쓰기 전에 반드시 통과시킨다.
ho_is_valid_uuid() {
  case "$1" in
    ''|*[!0-9a-fA-F-]*) return 1 ;;
    *) [ ${#1} -ge 8 ] && [ ${#1} -le 64 ] ;;
  esac
}

# 프로젝트 잠금. mkdir 은 원자적이라 경쟁 조건이 없다.
# 잠금 안에 소유 PID 를 남겨, 프로세스가 죽어 trap 이 안 돈 경우를 stale 로 판정한다.
# 이게 없으면 중단된 실행 하나가 그 프로젝트를 영구히 잠근다(실사용에서 발생).
# 해제는 trap 에서 함수 밖 컨텍스트로 불리므로, 잠금 경로를 전역에 남긴다.
# 지역 변수를 참조하면 set -u 아래에서 unbound variable 로 죽는다(실사용에서 발생).
HO_LOCK_DIR=""

ho_lock_acquire() {
  local root="$1" lockdir="$1/.handoff-lock" owner
  if mkdir "$lockdir" 2>/dev/null; then
    printf '%s\n' "$$" > "$lockdir/pid" 2>/dev/null || true
    HO_LOCK_DIR="$lockdir"
    return 0
  fi
  owner="$(cat "$lockdir/pid" 2>/dev/null | tr -d ' \n')"
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
    ho_err "이 프로젝트에서 다른 handoff/handback 이 실행 중입니다 (pid $owner)."
    return 1
  fi
  ho_warn "이전 실행이 남긴 잠금을 정리합니다 (${owner:-소유자 불명}, 프로세스 없음)."
  rm -rf "$lockdir" 2>/dev/null || true
  if mkdir "$lockdir" 2>/dev/null; then
    printf '%s\n' "$$" > "$lockdir/pid" 2>/dev/null || true
    HO_LOCK_DIR="$lockdir"
    return 0
  fi
  ho_err "잠금을 획득하지 못했습니다: $lockdir"
  return 1
}

ho_lock_release() {
  [ -n "${HO_LOCK_DIR:-}" ] || return 0
  rm -rf "$HO_LOCK_DIR" 2>/dev/null || true
  HO_LOCK_DIR=""
}

# 프로젝트 파일을 열어 "쓰고 있는" 프로세스를 찾는다.
#
# cwd 기준으로 잡으면 안 된다. 이 도구는 세션 안의 에이전트가 부르는 것을 전제로 하는데,
# 에이전트의 셸 도구는 명령마다 프로젝트 cwd 로 새 프로세스를 띄운다.
# cwd 로 판정하면 handoff 가 언제나 자기 자신에 걸려 구조적으로 호출이 불가능해진다.
# 또 그 폴더에 cwd 만 걸쳐 있을 뿐 파일과 무관한 프로세스(터미널, caffeinate, MCP 서버)까지 막는다.
#
# 실제 위험은 "프로젝트 파일에 계속 쓰는 프로세스"다. 그 결과만이 handback 때
# 원격 내용으로 덮여 사라진다. 그래서 쓰기 열린 파일 기술자만 본다.
#
# 한계를 분명히 해둔다. 이것은 스냅샷이라 최선 노력(best-effort)이지 보증이 아니다.
# 파일을 열고-쓰고-닫는 순간적인 쓰기는 구조적으로 놓친다. 실측으로 확인했다:
#   - tsc -b --watch 의 재빌드 구간을 40회 연속 폴링해도 쓰기 fd 가 한 번도 안 잡혔다
#   - 셸의 >> 추가 리다이렉션은 매번 열고 닫으므로 지속 fd 가 아예 없다
# 지속적으로 파일을 붙들고 쓰는 프로세스(dev server 의 로그, DB, 장시간 빌드 산출)는 잡는다.
# 이 검사를 통과했다는 것이 "아무도 안 쓴다"는 증명은 아니다.
#
# 비용은 실측했다. 47k~58k 파일 트리에서 1.2~1.5초, 705 파일에서 0.19초.
ho_self_and_ancestors() {
  local pid="$$"
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ]; do
    printf '%s\n' "$pid"
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  done
}

# "<pid>\t<명령>\t<쓰는 파일>" 을 한 줄씩. 없으면 아무것도 출력하지 않는다.
ho_live_processes() {
  local root="$1" real skip
  command -v lsof >/dev/null 2>&1 || return 0
  real="$(cd "$root" 2>/dev/null && pwd -P)" || return 0
  skip="$(ho_self_and_ancestors | tr '\n' ' ')"
  # lsof 출력을 먼저 받아둔다. 파이프로 바로 넘기면 뒤따르는 awk/sort 가
  # 같은 트리에서 동시에 돌아 자기 파이프라인을 스스로 감지한다.
  local raw; raw="$(lsof -w -F pcfan +D "$real" 2>/dev/null)"
  [ -n "$raw" ] || return 0
  printf '%s\n' "$raw" | awk -v skip=" $skip " '
    /^p/ { pid = substr($0, 2); cmd = ""; next }
    /^c/ { cmd = substr($0, 2); next }
    /^f/ { fd = substr($0, 2); acc = ""; next }
    /^a/ { acc = substr($0, 2); next }
    /^n/ {
      path = substr($0, 2)
      # 숫자 fd 이면서 쓰기(w) 또는 읽기쓰기(u) 로 열린 것만 위험이다.
      # cwd, txt, mem 같은 항목과 읽기 전용(r)은 넘긴다.
      if (fd ~ /^[0-9]+$/ && acc ~ /[wu]/ \
          && index(skip, " " pid " ") == 0 && cmd != "lsof")
        print pid "\t" cmd "\t" path
      next
    }
  ' | sort -u
}
