#!/usr/bin/env bash
# 전송 목록 산출 (R6, R12, AC12).
#
# 이 파일의 모든 함수는 원격 접속 없이, 같은 입력에 같은 출력을 낸다.
# 판단(후보 제시, 선택 반영)은 스킬이 하고 여기서는 규칙만 적용한다.

set -o pipefail

# 프로젝트별 목록 파일
ho_include_file() { printf '%s/.handoffinclude' "$1"; }
ho_ignore_file()  { printf '%s/.handoffignore' "$1"; }

# 패턴 파일을 배열로 (주석과 빈 줄 제거)
_ho_read_patterns() {
  local file="$1"
  [ -r "$file" ] || return 0
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$file" | grep -v '^$' || true
}

# 제어 상태 파일: 프로젝트 내용이 아니라 이 도구의 상태다.
# 설정으로 끌 수 없다. 동기화 대상이 되면 회수 시 --delete 가 로컬 리스를 지워
# handoff 시각과 세션 uuid 가 사라진다(실기계에서 실제로 발생).
# 동기화 자체를 막아야 하는 것만 남긴다.
#  - .handoff-backup: 백업 사본을 다시 전송하면 무한히 불어난다
#  - .handoff-lock: 실행 중 잠금이라 다른 머신으로 옮기면 의미가 없다
HO_CONTROL_EXCLUDES=".handoff-backup
.handoff-lock"

# 동기화는 하되 --delete 로 지워지면 안 되는 제어 파일 (R10(7)).
# 이것들이 삭제되면 handoff 시각과 세션 uuid 가 사라져 매번 첫 handoff 로 되돌아간다.
HO_PROTECTED_CONTROL=".handoff-lease
.handoffrc
.handoffinclude
.handoffignore"

# 고정 제외 목록 + .handoffignore + 제어 파일
ho_exclude_patterns() {
  local root="$1"
  ho_config_list exclude
  _ho_read_patterns "$(ho_ignore_file "$root")"
  printf '%s\n' "$HO_CONTROL_EXCLUDES"
}

# 강제 포함 목록 = 설정 include + .handoffinclude
ho_include_patterns() {
  local root="$1"
  ho_config_list include
  _ho_read_patterns "$(ho_include_file "$root")"
}

ho_secret_patterns() {
  ho_config_list secrets
}

_ho_is_git_repo() { [ -d "$1/.git" ] || (cd "$1" && git rev-parse --git-dir >/dev/null 2>&1); }

# git이 무시하지 않는 파일 (추적 + 미추적)
_ho_git_visible() {
  (cd "$1" && git ls-files --cached --others --exclude-standard 2>/dev/null) || true
}

# git이 무시하는 파일
_ho_git_ignored() {
  (cd "$1" && git ls-files --others --ignored --exclude-standard 2>/dev/null) || true
}

# git이 아닌 디렉터리: 고정 제외만 적용해 전부 열거 (D-36)
_ho_plain_files() {
  (cd "$1" && find . -type f -print 2>/dev/null | sed 's|^\./||') || true
}

# 경로가 고정 제외/무시 패턴에 걸리는가. 디렉터리 성분도 검사한다.
ho_is_excluded() {
  local root="$1" path="$2"
  local -a pats=()
  local p seg
  while IFS= read -r p; do [ -n "$p" ] && pats+=("$p"); done < <(ho_exclude_patterns "$root")
  [ ${#pats[@]} -eq 0 ] && return 1
  ho_matches_any "$path" "${pats[@]}" && return 0
  # 경로 성분 단위 검사 (node_modules/foo/bar.js -> node_modules)
  local IFS='/'
  for seg in $path; do
    [ -z "$seg" ] && continue
    ho_matches_any "$seg" "${pats[@]}" && return 0
  done
  return 1
}

ho_is_included() {
  local root="$1" path="$2"
  local -a pats=()
  local p
  while IFS= read -r p; do [ -n "$p" ] && pats+=("$p"); done < <(ho_include_patterns "$root")
  [ ${#pats[@]} -eq 0 ] && return 1
  ho_matches_any "$path" "${pats[@]}"
}

ho_is_secret() {
  local path="$1"
  local -a pats=()
  local p
  while IFS= read -r p; do [ -n "$p" ] && pats+=("$p"); done < <(ho_secret_patterns)
  [ ${#pats[@]} -eq 0 ] && return 1
  ho_matches_any "$path" "${pats[@]}"
}

# 경로 목록을 한 프로세스에서 거른다 (issue #1).
# 파일마다 ho_is_included/ho_is_excluded 서브셸을 띄우면 무시 파일이 수만 개인
# 프로젝트에서 스캔이 분 단위로 걸린다. 단일 경로 판정은 기존 함수를 그대로 쓴다.
_ho_filter_paths() {
  local root="$1" mode="$2"
  HO_PF_INCLUDE="$(ho_include_patterns "$root")" \
  HO_PF_EXCLUDE="$(ho_exclude_patterns "$root")" \
    python3 "$_HO_LIB_DIR/path_filter.py" "$mode"
}

# ho_transfer_list <root>
# 전송할 상대경로를 정렬해 출력한다.
ho_transfer_list() {
  local root="$1"
  {
    if _ho_is_git_repo "$root"; then
      _ho_git_visible "$root"
      # 무시되지만 포함 목록에 걸린 것은 되살린다
      _ho_git_ignored "$root" | _ho_filter_paths "$root" include-only
      # .git 자체는 포함 (D-08)
      if [ -d "$root/.git" ]; then
        (cd "$root" && find .git -type f -print 2>/dev/null) || true
      fi
    else
      _ho_plain_files "$root"
    fi
  } | _ho_filter_paths "$root" not-excluded | LC_ALL=C sort -u
}

# ho_candidate_list <root>
# 최초 handoff에서 사람에게 보여줄 후보: 무시되는데 포함도 제외도 결정되지 않은 것.
# 출력은 "<bytes>\t<path>" 이며 큰 것부터.
ho_candidate_list() {
  local root="$1"
  _ho_is_git_repo "$root" || return 0
  # 매칭과 용량 조회 모두 일괄 처리한다. 파일당 프로세스를 띄우면 무시 파일이
  # 많을 때 멈춘다 (issue #1).
  _ho_git_ignored "$root" | _ho_filter_paths "$root" candidates | python3 -c "
import os,sys
root=sys.argv[1]
rows=[]
for rel in sys.stdin.read().splitlines():
    rel=rel.strip()
    if not rel: continue
    try: rows.append((os.path.getsize(os.path.join(root,rel)), rel))
    except OSError: rows.append((0, rel))
rows.sort(reverse=True)
for size, rel in rows:
    print('%d\t%s' % (size, rel))
" "$root"
}

# ho_transfer_bytes <root>
# 파일마다 wc -c 를 띄우면 프로젝트가 커질수록 사실상 끝나지 않는다(실사용에서 확인).
# 목록을 한 번에 넘겨 파이썬 한 프로세스로 합산한다.
ho_transfer_bytes() {
  local root="$1"
  ho_transfer_list "$root" | python3 -c "
import os,sys
root=sys.argv[1]
total=0
for rel in sys.stdin.read().splitlines():
    rel=rel.strip()
    if not rel: continue
    try: total+=os.path.getsize(os.path.join(root,rel))
    except OSError: pass
print(total)
" "$root"
}

# 선택/거절 결과를 목록 파일에 기록 (D-50). 중복 없이 추가만 한다.
ho_record_include() {
  local root="$1" path="$2" file
  file="$(ho_include_file "$root")"
  grep -qxF "$path" "$file" 2>/dev/null && return 0
  printf '%s\n' "$path" >> "$file"
}

ho_record_ignore() {
  local root="$1" path="$2" file
  file="$(ho_ignore_file "$root")"
  grep -qxF "$path" "$file" 2>/dev/null && return 0
  printf '%s\n' "$path" >> "$file"
}

# 해당 프로젝트의 최초 handoff 인가 (목록 파일이 아직 없으면 최초)
ho_is_first_handoff() {
  local root="$1"
  [ -f "$(ho_include_file "$root")" ] && return 1
  [ -f "$(ho_ignore_file "$root")" ] && return 1
  return 0
}

# --- 프롬프트 안전 검사 (R16/AC16). 세부 로직은 lib/prompt_guard.py 가 소유한다. ---

# 이 라이브러리의 위치에서 헬퍼 경로를 스스로 찾는다.
# HO_ROOT 에 의존하면 bin/handoff 를 거치지 않는 호출(테스트 등)에서 깨진다.
_HO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_ho_guard() {
  local action="$1"; shift
  HO_SECRET_PATTERNS="$(ho_config_get secrets)" \
    python3 "$_HO_LIB_DIR/prompt_guard.py" "$action" "$@"
}

# 시크릿 값이 프롬프트에 섞였으면 0 을 반환한다(차단해야 함).
# 전송 목록뿐 아니라 무시된 파일까지 훑는다. 제외된 시크릿이 새는 쪽이 더 위험하다.
ho_prompt_leaks_secret() {
  local root="$1" prompt="$2"
  [ -n "$prompt" ] || return 1
  # 전송 목록 + 무시된 파일 + 추적 중인 파일 전부. 시크릿이 커밋되어 있어도 잡아야 한다.
  { ho_transfer_list "$root"; _ho_git_ignored "$root"; _ho_git_visible "$root"; } \
    | LC_ALL=C sort -u \
    | _ho_guard leak "$root" "$prompt"
}

# Codex 요약 계약: 네 항목이 모두 있고 각 항목이 5줄 이내인가 (D-44).
ho_codex_summary_ok() { _ho_guard check "$1" </dev/null; }

# 계약을 못 지킨 요약을 떼어내고 사용자 지시문만 남긴다 (D-44 실패 폴백).
ho_strip_summary() { _ho_guard strip "$1" </dev/null; }
