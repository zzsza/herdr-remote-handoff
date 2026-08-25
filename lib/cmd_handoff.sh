#!/usr/bin/env bash
# handoff (R3, R4, R9, D-30, D-31, D-47).
#
# 원칙은 무확인 원샷이다. 확인은 두 경우뿐: 해당 프로젝트 최초 handoff, 전송량 임계치 초과.
# 실행 순서는 사전조건 -> 전송 -> 세션 이관 -> 리스 갱신 -> pane 생성 이며,
# 리스 갱신 이전 중단은 재실행이 안전하고 이후 실패는 상태를 그대로 두고 안내만 한다.

set -o pipefail

# 현재 herdr 에이전트에서 세션 uuid 를 얻는다. 실패하면 빈 문자열.
ho_current_session_uuid() {
  local cwd="$1"
  command -v herdr >/dev/null 2>&1 || { printf ''; return; }
  herdr agent list 2>/dev/null | python3 -c "
import json,sys
cwd=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
best=None
for a in d.get('result',{}).get('agents',[]):
    if a.get('agent')!='claude': continue
    if a.get('cwd')!=cwd and a.get('foreground_cwd')!=cwd: continue
    if a.get('focused'): best=a; break
    if best is None: best=a
if best:
    print((best.get('agent_session') or {}).get('value') or '')
" "$cwd"
}

# 프로젝트 밖(상위 디렉터리)에서 시작된 Claude 세션을 찾는다.
# 세션 파일은 시작 당시 cwd 로 키잉되므로, 상위에서 시작한 세션으로는
# 하위 프로젝트만 떼어 넘길 수 없다. 그 사실을 사용자에게 정확히 알려주기 위한 조회다.
ho_session_cwd_elsewhere() {
  local root="$1"
  command -v herdr >/dev/null 2>&1 || return 1
  herdr agent list 2>/dev/null | python3 -c "
import json,sys,os
root=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
for a in d.get('result',{}).get('agents',[]):
    if a.get('agent')!='claude': continue
    cwd=a.get('cwd') or ''
    if not cwd or cwd==root: continue
    # 이 프로젝트를 품고 있는 상위에서 시작된 세션인가
    if root.startswith(cwd.rstrip('/')+'/'):
        print(cwd)
        sys.exit(0)
sys.exit(1)
" "$root"
}

ho_local_session_file() {
  local root="$1" uuid="$2"
  printf '%s/%s.jsonl' "$(ho_session_dir "$root")" "$uuid"
}

ho_cmd_handoff() {
  local instruction="$1"
  local runtime="${HO_RUNTIME:-claude}"
  local root host uuid session_file remote_free bytes filelist backup ws pane
  root="$(ho_project_root "$PWD")"
  ho_config_load "$root"
  host="$(ho_config_get remote)"

  # --- 0. 프로젝트 잠금 ---
  # 리스 획득이 원자적이지 않아, 동시 실행되면 둘 다 owner=local 을 보고 각각
  # bypass 에이전트를 띄울 수 있다. mkdir 은 원자적이므로 이것으로 막는다.
  ho_lock_acquire "$root" || exit 3
  trap ho_lock_release EXIT INT TERM

  # --- 1. 사전조건 ---
  ho_require_bootstrap "$host"

  ho_remote_alive "$host"       || ho_abort "원격 $host 가 SSH에 응답하지 않습니다."
  ho_remote_herdr_alive "$host" || ho_abort "원격 herdr 서버가 응답하지 않습니다."

  # 리스가 이미 원격이면 중단한다 (D-31 의 중단 조건). 확인 프롬프트를 띄우지 않는다 -
  # 확인은 최초 handoff 와 용량 초과 두 경우뿐이라는 원칙(D-30)을 지키기 위해서다.
  # 덮어쓰려면 사용자가 --force 를 명시해야 한다(D-13 의 파일 리스 강제 경로).
  local lease_owner; lease_owner="$(ho_lease_owner "$root")"
  if [ "$lease_owner" = "unknown" ]; then
    ho_abort "리스 파일을 읽을 수 없습니다: $(ho_lease_file "$root")
  원격에 에이전트가 남아 있을 수 있어 진행하지 않습니다.
  'handoff status' 로 확인하거나 리스 파일을 고친 뒤 다시 시도하세요."
  fi
  if [ "$lease_owner" = "remote" ]; then
    if [ "${HO_FORCE:-0}" != "1" ]; then
      ho_err "이 프로젝트의 리스가 이미 원격에 있습니다 (이전 handoff 미완)."
      ho_say "  회수하려면: handback   상태 확인: handoff status"
      ho_say "  그래도 덮어쓰려면: handoff --force \"<지시문>\""
      exit 3
    fi
    # 원격 에이전트가 아직 있으면 --force 로도 덮지 않는다. 두 에이전트가 같은
    # 파일과 세션에 동시에 쓰는 상황을 만들면 안 되고, 세션 리스는 하드 스톱이다(D-26).
    local prev_uuid prev_name prev_state prev_rc
    prev_uuid="$(ho_lease_get "$root" session_uuid 2>/dev/null || true)"
    prev_name="$(ho_lease_get "$root" agent_name 2>/dev/null || true)"
    if [ -n "$prev_uuid" ]; then
      prev_state="$(ho_remote_agent_state "$host" "$prev_uuid")"; prev_rc=$?
    elif [ -n "$prev_name" ]; then
      prev_state="$(ho_remote_agent_state_by_name "$host" "$prev_name")"; prev_rc=$?
    else
      prev_rc=1
    fi
    case "$prev_rc" in
      2) ho_abort "원격 상태를 판정할 수 없어 --force 덮어쓰기를 중단합니다." ;;
      0) ho_abort "원격 세션이 아직 살아 있습니다(상태: $prev_state). --force 로도 덮어쓸 수 없습니다.
  handback 으로 회수한 뒤 다시 넘기세요." ;;
    esac
    ho_warn "--force 로 리스 위반을 덮어씁니다. 원격 세션 사본을 먼저 백업합니다."
    if [ -n "$prev_uuid" ]; then
      ho_backup_remote_session "$host" "$root" "$prev_uuid" \
        || ho_abort "원격 세션 백업에 실패해 덮어쓰기를 중단합니다. 원격 대화를 잃을 수 있습니다."
    fi
  fi

  local remote_path="$root"
  # 경로 봉쇄: 이 도구는 로컬과 원격의 절대경로가 같다는 전제 위에 돈다.
  # 트리 밖(예: /tmp/foo)에서 실행하면 원격의 무관한 같은 경로를 --delete 로 파괴한다.
  # 프로젝트 모음 디렉터리는 거부한다. ~/projects 에서 실행하면 그 아래 전부가 넘어간다.
  local repo_count
  if ! repo_count="$(ho_project_root_is_sane "$root")"; then
    ho_abort "여기는 프로젝트가 아니라 프로젝트 모음으로 보입니다: $root
  바로 아래에 git 레포가 ${repo_count}개 이상 있습니다. 넘길 프로젝트 디렉터리 안에서 실행하세요.
  예: cd $root/<프로젝트> && handoff \"<지시문>\""
  fi

  # 트리 루트 자체는 거부한다. 허용하면 홈 전체가 전송 대상이 된다.
  [ "$root" != "$(ho_remote_tree)" ] \
    || ho_abort "핸드오프 트리 루트 자체는 넘길 수 없습니다: $root"
  case "$root/" in
    "$(ho_remote_tree)"/?*) ;;
    *) ho_abort "이 프로젝트는 핸드오프 트리($(ho_remote_tree)) 밖에 있습니다: $root
  원격의 같은 경로를 덮어쓸 수 있어 전송하지 않습니다." ;;
  esac

  if [ "$runtime" = "claude" ]; then
    uuid="${HO_SESSION_UUID:-$(ho_current_session_uuid "$root")}"
    if [ -z "$uuid" ]; then
      local outer
      if outer="$(ho_session_cwd_elsewhere "$root")"; then
        ho_abort "이 프로젝트에서 시작된 Claude 세션이 없습니다.
  지금 세션은 상위 디렉터리에서 시작됐습니다: $outer
  세션 기록은 시작 당시 경로로 저장되므로 하위 프로젝트만 떼어 넘길 수 없습니다.
  넘기려면 그 프로젝트 안에서 새로 시작하세요:
      cd $root && claude"
      fi
      ho_abort "이 프로젝트에서 시작된 Claude 세션을 찾을 수 없습니다.
  $root 안에서 claude 를 실행한 뒤 다시 시도하거나, HO_SESSION_UUID 로 직접 지정하세요."
    fi
    # 리스와 HO_SESSION_UUID 모두 조작될 수 있다. 경로를 조립하기 전에 형식을 강제한다.
    ho_is_valid_uuid "$uuid" \
      || ho_abort "세션 uuid 형식이 올바르지 않습니다: $uuid"
    session_file="$(ho_local_session_file "$root" "$uuid")"
    [ -f "$session_file" ] || ho_abort "세션 파일이 없습니다: $session_file"
  fi

  # 전송량 개산 (최초 handoff 확인에서 목록이 바뀔 수 있으므로 목록 자체는 뒤에서 확정한다)
  bytes="$(ho_transfer_bytes "$root")"

  remote_free="$(ho_remote_free_bytes "$host" "$remote_path")"
  # 값을 못 얻으면 검사를 건너뛰지 않고 중단한다. 여유 공간을 모른 채 전송하면
  # 라이브 원격의 디스크를 채울 수 있다. (최초 handoff 는 경로가 아직 없으므로
  # ho_remote_free_bytes 가 존재하는 조상으로 올라가 값을 얻는다.)
  if [ -z "$remote_free" ] || [ "$remote_free" -le 0 ] 2>/dev/null; then
    ho_abort "원격 여유 공간을 확인하지 못했습니다. 전송하지 않습니다."
  fi
  # rsync --backup 이 덮어쓰기/삭제분 사본을 원격에 남기고 세션 파일도 들어간다.
  # 전송량만 보면 실제로는 공간이 모자랄 수 있으므로 2배 + 세션 크기를 요구한다.
  local need session_bytes_needed=0
  [ -n "${session_file:-}" ] && [ -f "${session_file:-}" ] \
    && session_bytes_needed="$(wc -c < "$session_file" | tr -d ' ')"
  need=$(( bytes * 2 + session_bytes_needed ))
  if [ "$remote_free" -lt "$need" ] 2>/dev/null; then
    ho_abort "원격 여유 공간($(ho_human_bytes "$remote_free"))이 필요량($(ho_human_bytes "$need"), 백업·세션 포함)보다 적습니다."
  fi

  # --- 2. 세 단계 조건 (D-31) ---
  local warn_gib; warn_gib="$(ho_config_get free_space_warn_gib)"
  if [ -n "$remote_free" ] && [ "$remote_free" -lt $(( warn_gib * 1073741824 )) ] 2>/dev/null; then
    ho_warn "원격 여유 공간 $(ho_human_bytes "$remote_free") (임계치 ${warn_gib}Gi 미만). 'handoff clean' 을 고려하세요."
  fi

  # 프로젝트 파일에 쓰고 있는 프로세스는 사전조건 실패다.
  # 프로세스는 이관되지 않고 로컬에 남아 계속 쓴다.
  # 그대로 넘기면 handback 이 원격 내용으로 덮어 그 결과가 조용히 사라진다.
  local proc_lines proc_count
  proc_lines="$(ho_live_processes "$root")"
  if [ -n "$proc_lines" ]; then
    proc_count="$(printf '%s\n' "$proc_lines" | wc -l | tr -d ' ')"
    ho_err "프로젝트 파일에 쓰고 있는 프로세스 ${proc_count}개가 있어 넘길 수 없습니다."
    local p_pid p_cmd p_path
    while IFS=$'\t' read -r p_pid p_cmd p_path; do
      [ -z "$p_pid" ] && continue
      ho_say "    pid $p_pid  $p_cmd  ->  ${p_path#$root/}"
    done < <(printf '%s\n' "$proc_lines" | head -10)
    [ "$proc_count" -gt 10 ] && ho_say "    ... 외 $(( proc_count - 10 ))개"
    ho_say ""
    ho_say "  프로세스는 넘어가지 않고 로컬에 남아 계속 씁니다."
    ho_say "  회수(handback) 때 원격 내용으로 덮여 그동안의 결과가 사라집니다."
    ho_say "  먼저 정리한 뒤 다시 넘기세요."
    exit 3
  fi

  # 최초 handoff: 후보 제시 (D-50)
  if ho_is_first_handoff "$root"; then
    ho_info "이 프로젝트의 첫 handoff 입니다. gitignore된 파일 중 전송 후보:"
    local any=0 line size path
    while IFS=$'\t' read -r size path; do
      [ -z "$path" ] && continue
      any=1
      ho_say "    $(ho_human_bytes "$size")  $path"
    done < <(ho_candidate_list "$root" | head -40)
    [ "$any" = "0" ] && ho_say "    (없음)"
    ho_say ""
    ho_say "  포함 목록: $(ho_config_get include)"
    ho_say "  제외 목록: $(ho_config_get exclude)"
    # 후보를 자동으로 거절 목록에 넣지 않는다. 무엇을 가져갈지는 사람의 판단이며(D-50),
    # 그 판단을 이끌어내는 것은 스킬의 몫이다(D-09).
    # 스크립트는 미결정 후보가 있다는 사실만 알리고 기록 통로를 안내한다.
    if [ "$any" = "1" ]; then
      ho_say ""
      ho_say "  아직 결정되지 않은 후보가 있습니다. 각각 다음으로 굳힐 수 있습니다:"
      ho_say "      handoff include <경로>     handoff exclude <경로>"
      ho_say "  지금 넘기면 위 '포함 목록' 규칙에 걸리는 것만 전송됩니다."
    fi
    if ! ho_confirm "이대로 전송할까요?"; then
      ho_abort "사용자가 최초 handoff 확인을 거절했습니다."
    fi
    # 확인이 끝나면 목록 파일을 만들어 2회차부터 무확인이 되게 한다.
    : >> "$(ho_include_file "$root")"
    : >> "$(ho_ignore_file "$root")"
  fi

  # 후보 선택으로 목록이 바뀌었을 수 있으므로 전송량과 여유 공간을 다시 계산한다.
  # 재계산하지 않으면 처음 제외됐던 대용량 파일을 포함시켜 용량·공간 검사를 우회할 수 있다.
  ho_config_load "$root"
  bytes="$(ho_transfer_bytes "$root")"
  remote_free="$(ho_remote_free_bytes "$host" "$remote_path")"
  if [ -z "$remote_free" ] || [ "$remote_free" -le 0 ] 2>/dev/null; then
    ho_abort "원격 여유 공간을 확인하지 못했습니다. 전송하지 않습니다."
  fi
  need=$(( bytes * 2 + session_bytes_needed ))
  if [ "$remote_free" -lt "$need" ] 2>/dev/null; then
    ho_abort "원격 여유 공간($(ho_human_bytes "$remote_free"))이 필요량($(ho_human_bytes "$need"), 백업·세션 포함)보다 적습니다."
  fi

  # 용량 임계치
  local limit; limit="$(ho_config_get size_confirm_bytes)"
  if [ "$bytes" -gt "$limit" ] 2>/dev/null; then
    if ! ho_confirm "전송량이 $(ho_human_bytes "$bytes") 입니다 (임계치 $(ho_human_bytes "$limit")). 계속할까요?"; then
      ho_abort "사용자가 용량 확인을 거절했습니다."
    fi
  fi

  # Codex 경로의 요약 계약을 스크립트가 강제한다 (R16/AC16, D-44).
  # 스킬이 네 항목을 붙여 보내지만 형식 위반은 여기서 기계적으로 잡고,
  # 위반 시 요약을 떼어내 지시문만 전달한다. 요약 실패가 handoff 실패가 되면 안 된다.
  if [ "$runtime" = "codex" ]; then
    if ! ho_codex_summary_ok "$instruction"; then
      ho_warn "요약이 계약(네 항목, 각 5줄 이내)을 만족하지 않아 제거하고 지시문만 전달합니다."
      instruction="$(ho_strip_summary "$instruction")"
    fi
  fi

  # 프롬프트가 시크릿을 흘리면 전송하지 않는다 (R16/AC16).
  # Codex 경로는 스킬이 만든 요약이 프롬프트에 들어가므로 여기서 기계적으로 막는다.
  if ho_prompt_leaks_secret "$root" "$instruction"; then
    ho_abort "지시문/요약에 시크릿 파일의 내용이 포함되어 있습니다. 요약에서 제거한 뒤 다시 실행하세요."
  fi

  # --- 3. 전송 ---
  # 최초 handoff 확인에서 목록 파일이 갱신될 수 있으므로 여기서 확정한다.
  ho_config_load "$root"
  filelist="$(mktemp -t handoff-files)"
  ho_transfer_list "$root" > "$filelist"
  ho_backup_path_is_safe "$root" "$host" "$remote_path" \
    || { rm -f "$filelist"; ho_abort "백업 경로가 안전하지 않아 전송하지 않습니다."; }
  backup="$(ho_backup_dirname)"
  ho_backup_target_is_safe "$root" "$host" "$remote_path" "$backup" \
    || ho_abort "백업 대상 경로가 안전하지 않습니다."
  ho_info "전송: $root -> $host:$remote_path ($(ho_human_bytes "$bytes"))"
  ho_ssh "$host" "mkdir -p $(ho_shq "$remote_path")" || { rm -f "$filelist"; ho_abort "원격 디렉터리 생성 실패"; }
  # 경로 중간 구성요소가 트리 밖을 가리키는 심링크일 수 있다. 원격에서 실경로를 확인한다.
  local real_remote real_tree
  real_remote="$(ho_ssh "$host" "cd $(ho_shq "$remote_path") && pwd -P" 2>/dev/null | tr -d '\r')"
  real_tree="$(ho_ssh "$host" "cd $(ho_shq "$(ho_remote_tree)") && pwd -P" 2>/dev/null | tr -d '\r')"
  if [ -z "$real_remote" ] || [ -z "$real_tree" ]; then
    rm -f "$filelist"; ho_abort "원격 실경로를 확인하지 못했습니다. 전송하지 않습니다."
  fi
  [ "$real_remote" != "$real_tree" ] || { rm -f "$filelist"; ho_abort "원격 실경로가 트리 루트 자체입니다: $real_remote"; }
  # 트리 대상이 그 자체로 원격 홈을 가리키는 심링크면 전용 트리가 아니다.
  local remote_home
  remote_home="$(ho_ssh "$host" 'cd "$HOME" && pwd -P' 2>/dev/null | tr -d '\r')"
  if [ -n "$remote_home" ] && [ "$real_tree" = "$remote_home" ]; then
    rm -f "$filelist"
    ho_abort "원격 핸드오프 트리가 원격 홈 자체로 해석됩니다($real_tree). 전용 트리가 아니므로 전송하지 않습니다."
  fi
  case "$real_remote/" in
    "$real_tree"/?*) ;;
    *) rm -f "$filelist"
       ho_abort "원격 실경로가 전용 트리 밖입니다: $real_remote (트리: $real_tree)
  경로 중간에 외부를 가리키는 심링크가 있을 수 있어 전송하지 않습니다." ;;
  esac
  if ! ho_rsync_push "$root" "$host" "$remote_path" "$filelist" "$backup"; then
    rm -f "$filelist"
    ho_err "전송이 실패했거나 중단되었습니다. 리스는 그대로이며 같은 명령을 다시 실행하면 이어집니다."
    # 부분 전송으로 .env 가 이미 원격에 갔을 수 있다. 리스가 local 로 남아
    # handback 이 정리해주지 못하므로 여기서 지운다.
    if ho_remote_purge_secrets "$host" "$remote_path" "$root"; then
      ho_say "  부분 전송된 시크릿은 삭제했습니다."
    else
      ho_err "  원격 시크릿 삭제에도 실패했습니다. $host:$remote_path 를 직접 확인하세요."
    fi
    exit 4
  fi
  rm -f "$filelist"

  # --- 4. 세션 이관 ---
  if [ "$runtime" = "claude" ]; then
    if ! ho_push_session "$host" "$root" "$session_file"; then
      ho_err "세션 이관에 실패했습니다. 리스는 그대로이며 재실행이 안전합니다."
      # 파일은 이미 원격에 있다. 리스가 local 로 남으므로 handback 이 정리해주지 못한다.
      # 시크릿만이라도 여기서 지운다.
      if ho_remote_purge_secrets "$host" "$remote_path" "$root"; then
        ho_say "  원격에 전송된 시크릿은 삭제했습니다."
      else
        ho_err "  원격 시크릿 삭제에도 실패했습니다. $host:$remote_path 를 직접 확인하세요."
      fi
      exit 4
    fi
  fi

  # --- 5. 리스 갱신 (이 지점 이후의 실패는 상태를 보존하고 안내만 한다) ---
  # 리스 쓰기가 실패한 채 원격 에이전트를 띄우면 owner 가 local 로 남아
  # 훅 차단과 handback 이 모두 무력해지고 세션이 갈라진다.
  if ! ho_lease_claim_remote "$root" "${uuid:-}" "$host" "" \
     || [ "$(ho_lease_owner "$root")" != "remote" ]; then
    ho_err "리스를 기록하지 못했습니다. 원격 에이전트를 시작하지 않습니다."
    # 리스가 local 로 남으면 handback 이 '회수할 것 없음' 으로 끝나 원격 시크릿을 정리하지 못한다.
    if ho_remote_purge_secrets "$host" "$remote_path" "$root"; then
      ho_say "  원격에 전송된 시크릿은 삭제했습니다."
    else
      ho_err "  원격 시크릿 삭제에도 실패했습니다. $host:$remote_path 를 직접 확인하세요."
    fi
    exit 4
  fi
  # 갈래 판정 기준선. 이 시점 이후 로컬에 사람이 쓴 메시지가 붙으면 진짜 갈래다.
  if [ -n "${session_file:-}" ]; then
    ho_lease_record_session_bytes "$root" "$session_file" \
      || ho_warn "세션 기준선을 기록하지 못했습니다. 갈래 판정이 보수적으로 동작합니다."
  fi

  # --- 6. 원격 pane 생성과 자율 실행 ---
  # basename 만 쓰면 같은 이름의 다른 프로젝트와 충돌해 엉뚱한 에이전트를 조회/정지한다.
  local label path_tag
  path_tag="$(printf '%s' "$root" | shasum | cut -c1-8)"
  label="handoff-$(basename "$root")-$path_tag"
  ws="$(ho_remote_ws_create "$host" "$remote_path" "$label")"
  if [ -z "$ws" ]; then
    ho_err "원격 workspace 생성에 실패했습니다."
    ho_say "  파일과 세션은 원격에 있고 리스는 원격 소유입니다."
    ho_say "  handoff 를 다시 실행하거나 handback 으로 회수하세요."
    exit 5
  fi
  # 이 쓰기가 실패하면 Codex 는 리스에 식별자가 없어 handback 이 살아있는 에이전트를
  # stale 로 오판한다. 실패하면 workspace 를 정리하고 중단한다.
  if ! ho_lease_set "$root" "workspace_id=$ws" "agent_name=$label" \
     || [ "$(ho_lease_get "$root" workspace_id 2>/dev/null)" != "$ws" ]; then
    ho_err "workspace 식별자를 리스에 기록하지 못했습니다. 원격 workspace 를 정리합니다."
    ho_remote_ws_close "$host" "$ws" || ho_warn "  workspace $ws 정리 실패. 직접 확인하세요."
    exit 4
  fi

  pane="$(ho_remote_ws_pane "$host" "$ws")"
  if [ -z "$pane" ]; then
    ho_err "원격 pane 을 찾지 못했습니다 (workspace $ws)."
    ho_say "  handoff 재실행 또는 handback 으로 회수하세요."
    exit 5
  fi

  local settings="$(ho_remote_tree)/.handoff/claude-settings.json"
  if [ "$runtime" = "claude" ]; then
    ho_remote_trust_project "$host" "$remote_path" >/dev/null 2>&1 \
      || ho_warn "폴더 신뢰 선기록 실패. trust 대화상자에서 멈추면 herdr --remote $host 로 붙어 수락하세요."
    if ! ho_remote_agent_start "$host" "$pane" "$label" "$uuid" "$settings" "$instruction"; then
      ho_err "원격 자율 세션 기동에 실패했습니다 (workspace $ws)."
      ho_say "  handoff 재실행 또는 handback 으로 회수하세요."
      exit 5
    fi
  else
    if ! ho_remote_codex_start "$host" "$pane" "$label" "$instruction"; then
      ho_err "원격 Codex 세션 기동에 실패했습니다 (workspace $ws)."
      exit 5
    fi
  fi

  ho_ok "넘겼습니다. workspace $ws ($host)"
  ho_say "  붙어보기:  herdr --remote $host"
  ho_say "  회수:      handback"
  return 0
}
