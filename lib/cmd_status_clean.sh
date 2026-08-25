#!/usr/bin/env bash
# status (R17, D-40) 와 clean (R11, D-38, D-51).

set -o pipefail

ho_cmd_status() {
  local root host owner uuid ws state rc
  root="$(ho_project_root "$PWD")"
  ho_config_load "$root"
  host="$(ho_lease_get "$root" remote_host 2>/dev/null || ho_config_get remote)"
  owner="$(ho_lease_owner "$root")"
  uuid="$(ho_lease_get "$root" session_uuid 2>/dev/null || true)"
  ws="$(ho_lease_get "$root" workspace_id 2>/dev/null || true)"

  # 1. 리스 소유자
  ho_say "project      : $root"
  ho_say "owner        : $owner"

  # 2. 마지막 handoff 시각
  ho_say "last handoff : $(ho_lease_get "$root" handoff_at 2>/dev/null || echo '-')"
  ho_say "last handback: $(ho_lease_get "$root" handback_at 2>/dev/null || echo '-')"

  # 3. 원격 pane 상태
  local pane_desc="-"
  if [ "$owner" = "remote" ] && [ -n "$uuid" ]; then
    state="$(ho_remote_agent_state "$host" "$uuid")"; rc=$?
    case "$rc" in
      0) pane_desc="$state (workspace ${ws:-?})" ;;
      1) if ho_remote_session_advanced "$host" "$root" "$uuid" "$(ho_lease_get "$root" session_bytes 2>/dev/null || echo 0)"; then
           pane_desc="완료됨 (에이전트 종료, 회수 대기: handback)"
         else
           pane_desc="없음 -> stale (회수 가능: handback)"
         fi ;;
      2) pane_desc="판정 불가 (SSH/herdr 무응답)" ;;
    esac
  elif [ "$owner" = "remote" ]; then
    pane_desc="세션 uuid 없음 (Codex 경로)"
  fi
  ho_say "remote pane  : $pane_desc"

  # 4. 미회수 변경 유무
  local pending="-"
  if [ "$owner" = "remote" ]; then
    if ho_remote_alive "$host"; then
      local n; n="$(ho_rsync_pull_dry "$root" "$host" "$root" | grep -c . || true)"
      pending="${n:-0} 항목"
    else
      pending="확인 불가"
    fi
  fi
  ho_say "pending pull : $pending"

  # 5. 원격 여유 공간
  local free="-"
  if ho_remote_alive "$host"; then
    local fb; fb="$(ho_remote_free_bytes "$host" "/")"
    [ -n "$fb" ] && free="$(ho_human_bytes "$fb")"
  fi
  ho_say "remote free  : $free"
  return 0
}

# clean: 보존 기간 경과분만 대상으로 하고, 미리보기 확인 없이는 아무것도 지우지 않는다.
# 활성 리스나 살아 있는 pane 을 가진 프로젝트는 건너뛴다.
#
# 삭제 대상은 원격 트리뿐이다. 로컬은 절대 건드리지 않는다.
# R10 이 무기한 보존을 요구하는 리스/설정 파일은 제어 파일이라 원격으로 동기화되지 않으므로
# (HO_CONTROL_EXCLUDES) 로컬 원본은 clean 의 영향을 받지 않는다.
# pane 활성 여부. yes = 살아있음, no = 없음, unknown = 판정 불가.
_ho_clean_pane_state() {
  local host="$1" d="$2" agent_json
  if ! agent_json="$(ho_ssh "$host" "herdr agent list" 2>/dev/null)" || [ -z "$agent_json" ]; then
    printf 'unknown'; return
  fi
  printf '%s' "$agent_json" | python3 -c "
import json,sys
d=sys.argv[1]
try: j=json.load(sys.stdin)
except Exception: print('unknown'); sys.exit(0)
for a in j.get('result',{}).get('agents',[]):
    cwd=a.get('cwd') or ''
    if cwd==d or cwd.startswith(d.rstrip('/')+'/'):
        print('yes'); break
else:
    print('no')
" "$d"
}

ho_cmd_clean() {
  local host tree_days backup_days
  ho_config_load "$(ho_project_root "$PWD")"
  host="$(ho_config_get remote)"
  tree_days="${HO_OLDER_THAN_DAYS:-$(ho_config_get tree_retention_days)}"
  backup_days="$(ho_config_get backup_retention_days)"

  ho_remote_alive "$host" || ho_abort "원격 $host 에 접속할 수 없습니다."
  # rm -rf 를 걸기 전에 정리 루트가 여전히 기대한 전용 트리인지 확인한다.
  ho_bootstrap_check_symlink "$host" \
    || ho_abort "원격 핸드오프 트리가 기대한 심링크가 아닙니다. 정리를 진행하지 않습니다."

  local root_tree="$(ho_remote_tree)"
  local real_tree
  real_tree="$(ho_ssh "$host" "cd $(ho_shq "$root_tree") && pwd -P" 2>/dev/null | tr -d '\r')"
  [ -n "$real_tree" ] || ho_abort "원격 정리 루트의 실경로를 확인하지 못했습니다."

  # 대상 수집. root_tree 는 심링크이므로 후행 슬래시를 붙여야 find 가 따라간다(실기계에서 확인).
  local targets
  # 깊이 2 고정은 틀렸다. handoff 는 임의 깊이의 프로젝트를 받으므로
  # <트리>/foo 같은 깊이 1 프로젝트에서는 foo/.git 과 foo/src 가
  # 각각 독립 트리로 잡혀 개별 삭제 대상이 된다.
  # .git 을 가진 디렉터리를 프로젝트 루트로 보고, 그 아래 중첩된 것은 제외한다.
  targets="$(ho_ssh "$host" "find $(ho_shq "$root_tree/") -maxdepth 4 -type d -name .git -prune -print 2>/dev/null" \
    | sed 's#/\.git$##' \
    | LC_ALL=C sort \
    | awk '{ if (prev != "" && index($0, prev "/") == 1) next; print; prev=$0 }' \
    | while IFS= read -r d; do
        [ -z "$d" ] && continue
        case "$d" in
          *"/.handoff"*) continue ;;
          "$root_tree") continue ;;
        esac
        printf '%s\n' "$d"
      done)"

  # 경로에 탭이나 개행이 있으면 한 문자열로 직렬화한 뒤 다시 나눌 때 잘린다.
  # 잘린 앞부분과 같은 이름의 다른 디렉터리가 있으면 그것을 지울 수 있다.
  # 필드별로 병렬 배열을 써서 경로를 절대 쪼개지 않는다.
  local -a del_kind=() del_path=() del_age=() del_bytes=()
  local -a skip_path=() skip_why=()
  local d age bytes owner_remote pane_alive

  while IFS= read -r d; do
    [ -z "$d" ] && continue
    # 디렉터리 mtime 은 안에 있는 파일을 고쳐도 갱신되지 않는다.
    # 트리 안에서 가장 최근에 수정된 파일을 기준으로 삼아야 최근 작업물을 지우지 않는다.
    age="$(ho_ssh "$host" "python3 - $(ho_shq "$d") <<'PYAGE'
import os,sys,time
root=sys.argv[1]
newest=0
for dirpath,dirnames,filenames in os.walk(root):
    dirnames[:] = [x for x in dirnames if x not in ('.git','node_modules','.handoff-backup')]
    for name in filenames:
        try: newest=max(newest, os.path.getmtime(os.path.join(dirpath,name)))
        except OSError: pass
    try: newest=max(newest, os.path.getmtime(dirpath))
    except OSError: pass
print(int((time.time()-newest)//86400) if newest else 0)
PYAGE" 2>/dev/null)"
    [ -z "$age" ] && age=0

    # 보호 규칙: 리스 owner=remote 이거나 pane 이 살아 있으면 건너뛴다 (D-38).
    # 리스는 제어 파일이라 원격으로 동기화되지 않는다. 절대경로가 양쪽에서 같으므로
    # 같은 경로의 로컬 리스를 권위 있는 것으로 읽는다.
    owner_remote="$(ho_lease_owner "$d" 2>/dev/null || printf '')"

    if [ "$owner_remote" = "remote" ]; then
      skip_path+=( "$d" ); skip_why+=( "리스 소유자가 원격 (작업 중일 수 있음)" )
      continue
    fi

    pane_alive="$(_ho_clean_pane_state "$host" "$d")"
    if [ "$pane_alive" = "yes" ]; then
      skip_path+=( "$d" ); skip_why+=( "herdr pane 이 살아 있음" )
      continue
    fi
    if [ "$pane_alive" != "no" ]; then
      skip_path+=( "$d" ); skip_why+=( "herdr 조회 실패로 활성 여부 판정 불가" )
      continue
    fi

    if [ "$age" -lt "$tree_days" ] 2>/dev/null; then
      continue
    fi
    bytes="$(ho_ssh "$host" "du -sk $(ho_shq "$d") 2>/dev/null | awk '{print \$1*1024}'" | tr -d ' ')"
    del_kind+=( "tree" ); del_path+=( "$d" ); del_age+=( "$age" ); del_bytes+=( "${bytes:-0}" )
  done <<< "$targets"

  # 백업 디렉터리 (자동 삭제하지 않고 목록에 올린다 - D-51).
  # 트리와 같은 보호 규칙을 적용한다. 백업만 따로 지우면 활성 프로젝트의
  # 복구 수단을 작업 중에 없애는 셈이 된다.
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    local bage bbytes bproj
    # .handoff-backup/<ts> 의 소유 프로젝트를 구한다
    bproj="${b%/.handoff-backup/*}"
    if [ "$(ho_lease_owner "$bproj" 2>/dev/null)" = "remote" ]; then
      skip_path+=( "$b" ); skip_why+=( "소유 프로젝트의 리스가 원격" )
      continue
    fi
    if [ "$(_ho_clean_pane_state "$host" "$bproj")" != "no" ]; then
      skip_path+=( "$b" ); skip_why+=( "소유 프로젝트의 pane 이 살아 있거나 판정 불가" )
      continue
    fi
    bage="$(ho_ssh "$host" "python3 -c \"
import os,time,sys
try: print(int((time.time()-os.path.getmtime(sys.argv[1]))//86400))
except Exception: print(0)
\" $(ho_shq "$b")" 2>/dev/null)"
    [ -z "$bage" ] && bage=0
    [ "$bage" -lt "$backup_days" ] 2>/dev/null && continue
    bbytes="$(ho_ssh "$host" "du -sk $(ho_shq "$b") 2>/dev/null | awk '{print \$1*1024}'" | tr -d ' ')"
    del_kind+=( "backup" ); del_path+=( "$b" ); del_age+=( "$bage" ); del_bytes+=( "${bbytes:-0}" )
  done < <(ho_ssh "$host" "find $(ho_shq "$root_tree/") -maxdepth 4 -type d -name .handoff-backup -exec find {} -mindepth 1 -maxdepth 1 -type d \; 2>/dev/null")

  # 건너뛴 항목 보고
  local i
  for (( i=0; i<${#skip_path[@]}; i++ )); do
    ho_warn "건너뜀: ${skip_path[$i]}  (${skip_why[$i]})"
  done

  if [ ${#del_path[@]} -eq 0 ]; then
    ho_ok "정리 대상이 없습니다 (트리 ${tree_days}일 / 백업 ${backup_days}일 기준)."
    return 0
  fi

  # 미리보기: 대상과 용량 (확인 전에는 절대 삭제하지 않는다)
  ho_info "정리 대상 (트리 ${tree_days}일 / 백업 ${backup_days}일 경과):"
  local total=0
  for (( i=0; i<${#del_path[@]}; i++ )); do
    total=$(( total + del_bytes[i] ))
    ho_say "  [${del_kind[$i]}] $(ho_human_bytes "${del_bytes[$i]}")  ${del_age[$i]}일  ${del_path[$i]}"
  done
  ho_say "  합계: $(ho_human_bytes "$total")"

  if ! ho_confirm "삭제할까요? (되돌릴 수 없습니다)"; then
    ho_abort "사용자가 정리를 거절했습니다. 아무것도 삭제하지 않았습니다."
  fi

  # 부분 실패해도 나머지를 계속 진행하고 마지막에 보고한다 (D-38)
  local -a fail_path=() fail_why=()
  for (( i=0; i<${#del_path[@]}; i++ )); do
    local path="${del_path[$i]}" real_path
    # 삭제 직전에 실경로가 전용 트리 안인지 다시 본다.
    real_path="$(ho_ssh "$host" "cd $(ho_shq "$path") && pwd -P" 2>/dev/null | tr -d '\r')"
    if [ -z "$real_path" ] || [ "$real_path" = "$real_tree" ]; then
      fail_path+=( "$path" ); fail_why+=( "실경로 확인 불가 또는 트리 루트라 건너뜀" ); continue
    fi
    case "$real_path/" in
      "$real_tree"/?*) ;;
      *) fail_path+=( "$path" ); fail_why+=( "실경로가 전용 트리 밖이라 건너뜀($real_path)" ); continue ;;
    esac
    if ho_ssh "$host" "rm -rf $(ho_shq "$path")" >/dev/null 2>&1; then
      ho_say "  삭제: $path"
    else
      fail_path+=( "$path" ); fail_why+=( "삭제 실패 (권한 또는 사용 중)" )
    fi
  done

  if [ ${#fail_path[@]} -gt 0 ]; then
    ho_err "일부 항목을 삭제하지 못했습니다:"
    for (( i=0; i<${#fail_path[@]}; i++ )); do
      ho_say "  ${fail_path[$i]}  (${fail_why[$i]})"
    done
    return 6
  fi
  ho_ok "정리 완료 ($(ho_human_bytes "$total"))"
  return 0
}
