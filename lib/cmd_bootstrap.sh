#!/usr/bin/env bash
# bootstrap (R18, D-42, D-54).
#
# 멱등하다. 각 단계를 개별 검사해 미완료분만 수행한다.
# sudo 가 필요한 단계는 명령을 출력만 하고 사용자가 직접 실행한다.

set -o pipefail

# 원격 자율 세션에서 차단할 규칙 목록. 한 줄에 하나.
#
# 생성과 검증이 같은 함수를 쓴다. 두 곳에 목록을 적으면 한쪽만 고쳐져 검증이
# 통과하는데 실제 규칙은 다른 상태가 만들어진다.
#
# 무엇을 막는가:
#   - 원격의 launchd 항목. 상주 서비스를 건드리면 그 머신의 운영이 깨진다.
#   - 원격 홈 트리 전체. 핸드오프 트리는 별도 이름의 심링크로 접근하므로
#     경로 문자열이 달라 이 규칙에 걸리지 않는다.
#   - 설정 deny_extra 로 사용자가 지정한 경로.
#   - launchctl 실행.
#
# Claude Code 는 Write(path) 가 파일 권한 검사에 매칭되지 않는다고 경고할 수
# 있으므로 Edit 를 함께 넣어 실효성을 확보한다. 이 규칙이 bypassPermissions
# 에서 무력한 것으로 확인되면 경고만 하고 진행한다(fail-open).
ho_deny_rules() {
  local remote_home="$1" p
  for p in '~/Library/LaunchAgents' "$remote_home"; do
    printf 'Read(%s/**)\nEdit(%s/**)\nWrite(%s/**)\n' "$p" "$p" "$p"
  done
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf 'Read(%s/**)\nEdit(%s/**)\nWrite(%s/**)\n' "$p" "$p" "$p"
  done < <(ho_config_list deny_extra)
  printf 'Bash(launchctl:*)\n'
}

ho_claude_settings_json() {
  ho_deny_rules "$1" | python3 -c "
import json,sys
deny = [l for l in sys.stdin.read().splitlines() if l]
json.dump({'permissions': {'deny': deny}}, sys.stdout, ensure_ascii=False, indent=2)
sys.stdout.write('\\n')
"
}

# 원격 설정 파일이 지금 기대하는 규칙을 모두 담고 있는지 확인.
# 존재 검사로는 부족하다. 규칙이 하나 빠져도 파일은 있기 때문이다.
ho_verify_deny_rules() {
  local host="$1" remote_home="$2" json
  json="$(ho_ssh "$host" "cat $(ho_shq "$(ho_remote_tree)/.handoff/claude-settings.json")" 2>/dev/null)" || return 1
  # 기대 목록은 인자로 넘긴다. 표준입력은 원격 JSON 이 쓴다.
  printf '%s' "$json" | python3 -c "
import json,sys
required = [l for l in sys.argv[1].splitlines() if l]
try:
    deny = json.load(sys.stdin)['permissions']['deny']
except Exception:
    sys.exit(1)
if not isinstance(deny, list): sys.exit(1)
missing = [r for r in required if r not in deny]
if missing:
    sys.stderr.write('빠진 deny 규칙: %s\\n' % ', '.join(missing))
    sys.exit(1)
sys.exit(0)
" "$(ho_deny_rules "$remote_home")"
}

# 각 단계: 이름|검사|수행. 검사가 통과하면 건너뛴다.
# 쓰기 가능 여부만으로는 부족하다. 실제 디렉터리이거나 다른 곳을 가리키는 심링크면
# rsync --delete 가 원격의 무관한 같은 경로 프로젝트를 덮거나 지울 수 있다.
ho_bootstrap_check_symlink() {
  local host="$1" tree target want real_target real_home
  tree="$(ho_remote_tree)"
  want="$(ho_remote_tree_target "$host")" || return 1
  ho_ssh "$host" "test -L $(ho_shq "$tree") && test -d $(ho_shq "$tree") && test -w $(ho_shq "$tree")" >/dev/null 2>&1 || return 1
  target="$(ho_ssh "$host" "readlink $(ho_shq "$tree")" 2>/dev/null | tr -d '\r\n')"
  [ "$target" = "$want" ] || return 1
  # readlink 문자열만 보면 대상이 다시 심링크로 바뀌어도 통과한다.
  # 대상의 실경로가 원격 홈이나 다른 운영 트리가 아닌지 확인한다.
  real_target="$(ho_ssh "$host" "cd $(ho_shq "$want") && pwd -P" 2>/dev/null | tr -d '\r')"
  [ -n "$real_target" ] || return 1
  [ "$real_target" = "$want" ] || return 1
  real_home="$(ho_remote_home "$host")" || return 1
  [ -n "$real_home" ] && [ "$real_target" = "$real_home" ] && return 1
  return 0
}

ho_bootstrap_check_settings() {
  local host="$1" remote_home
  ho_ssh "$host" "test -f $(ho_shq "$(ho_remote_tree)/.handoff/claude-settings.json")" >/dev/null 2>&1 || return 1
  remote_home="$(ho_remote_home "$host")" || return 1
  ho_verify_deny_rules "$host" "$remote_home"
}

ho_bootstrap_check_cli() {
  ho_ssh "$1" 'command -v claude >/dev/null && command -v herdr >/dev/null' >/dev/null 2>&1
}

ho_cmd_bootstrap() {
  local host; host="$(ho_config_get remote)"
  local pending=0 did=0 tree target remote_home
  tree="$(ho_remote_tree)"

  ho_info "bootstrap: $host"

  if ! ho_remote_alive "$host"; then
    ho_abort "SSH로 $host 에 접속할 수 없습니다. ~/.ssh/config 와 네트워크를 확인하세요."
  fi
  ho_say "  [ok] ssh 접속"

  remote_home="$(ho_remote_home "$host")" \
    || ho_abort "원격 홈 경로를 확인하지 못했습니다. SSH 로그인 셸을 점검하세요."
  target="$(ho_remote_tree_target "$host")" \
    || ho_abort "핸드오프 트리 대상 경로를 정하지 못했습니다. 설정 remote_tree_target 을 지정하세요."
  ho_say "  [ok] 원격 홈 $remote_home"

  # 1. 핸드오프 트리 (sudo 필요, human-only)
  if ho_bootstrap_check_symlink "$host"; then
    ho_say "  [ok] 핸드오프 트리 $tree -> $target"
  else
    pending=1
    ho_warn "핸드오프 트리가 없거나 기대한 심링크가 아닙니다. $host 에서 아래 명령을 직접 실행하세요:"
    ho_say ""
    ho_say "    mkdir -p $target && sudo ln -s $target $tree"
    ho_say ""
    ho_say "  홈이 놓이는 상위 디렉터리는 대개 root 소유라 관리자 권한이 필요하고,"
    ho_say "  에이전트가 대신 실행할 수 없습니다."
  fi

  # 2. CLI 존재
  if ho_bootstrap_check_cli "$host"; then
    ho_say "  [ok] 원격 claude/herdr PATH"
  else
    pending=1
    ho_warn "원격에서 claude 또는 herdr 를 찾을 수 없습니다 (~/.local/bin 확인 필요)"
  fi

  # 3. 권한 설정 파일 (자동)
  if [ "$pending" = "0" ] || ho_bootstrap_check_symlink "$host"; then
    if ho_bootstrap_check_settings "$host"; then
      ho_say "  [ok] 권한 설정 파일"
    else
      ho_claude_settings_json "$remote_home" | ho_ssh "$host" "mkdir -p $(ho_shq "$tree/.handoff") \
        && rm -f $(ho_shq "$tree/.handoff/claude-settings.json") \
        && umask 077 && cat > $(ho_shq "$tree/.handoff/claude-settings.json")" \
        && { ho_say "  [+] 권한 설정 파일 생성"; did=1; } \
        || { ho_warn "권한 설정 파일 생성 실패"; pending=1; }
    fi
  fi

  # 4. CLI 계약 확인과 버전 기록 (V12 근거)
  if ho_remote_herdr_alive "$host"; then
    local cv hv
    cv="$(ho_ssh "$host" 'claude --version' 2>/dev/null | head -1)"
    hv="$(ho_ssh "$host" 'herdr --version' 2>/dev/null | head -1)"
    ho_say "  [ok] herdr 서버 응답 (claude: ${cv:-?} / herdr: ${hv:-?})"
  else
    pending=1
    ho_warn "원격 herdr 서버가 응답하지 않습니다"
  fi

  if [ "$pending" = "1" ]; then
    ho_err "bootstrap 미완료. 위 항목을 처리한 뒤 다시 실행하세요."
    return 3
  fi
  [ "$did" = "1" ] && ho_ok "bootstrap 완료" || ho_ok "bootstrap 이미 완료됨 (변경 없음)"
  return 0
}

# handoff/handback 진입 전 사전조건 (D-42: 미완료면 중단)
ho_require_bootstrap() {
  local host="$1"
  ho_bootstrap_check_symlink "$host" \
    || ho_abort "핸드오프 트리 $(ho_remote_tree) 가 준비되지 않았거나 기대한 심링크가 아닙니다. 'handoff bootstrap' 을 먼저 실행하세요."
  # CLI 준비 상태를 여기서 확인해야 한다. 이 검사가 없으면 claude 가 없는 원격에
  # 파일과 시크릿을 먼저 보내고 리스까지 넘긴 뒤 기동 단계에서 실패한다.
  ho_bootstrap_check_cli "$host" \
    || ho_abort "원격에 claude 또는 herdr 가 없습니다. 'handoff bootstrap' 을 먼저 실행하세요."
  ho_bootstrap_check_settings "$host" \
    || ho_abort "권한 설정 파일이 없습니다. 'handoff bootstrap' 을 먼저 실행하세요."
}
