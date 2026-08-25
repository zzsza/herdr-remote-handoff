#!/usr/bin/env bash
# handback (R7, R14, R15, D-21, D-26, D-43, D-52).
#
# handback 은 확인 지점이다. --force 는 이 경로에 적용되지 않는다.
# 기각된 "handback 강제 override" 를 플래그로 되살리지 않기 위해서이며,
# 실행 중 회수와 스테일 회수도 사용자 승인을 거쳐야 한다.
#
# 파괴적 동기화 전에 원격 상태를 확인한다. 판정 불가면 진행하지 않는다(fail-closed).
# 실행 중이면 기본 거부하고, 강제 승인 시 정지 -> 세션 -> 파일 -> 리스 순으로 회수한다.
# 파일만 회수한다. 로컬 세션 파일은 건드리지 않으며, 원격 대화는 원격에 남는다.

set -o pipefail

ho_cmd_handback() {
  local root host uuid remote_path ws state rc backup
  root="$(ho_project_root "$PWD")"
  ho_config_load "$root"
  host="$(ho_lease_get "$root" remote_host 2>/dev/null || ho_config_get remote)"
  remote_path="$root"

  # handoff 와 같은 잠금을 건다. 없으면 handoff 의 리스 획득과 pane 기동 사이에
  # handback 이 끼어들어 stale 로 오판하고 소유권을 되가져갈 수 있다.
  ho_lock_acquire "$root" || exit 3
  trap ho_lock_release EXIT INT TERM

  local lease_owner; lease_owner="$(ho_lease_owner "$root")"
  if [ "$lease_owner" = "unknown" ]; then
    ho_abort "리스 파일을 읽을 수 없습니다: $(ho_lease_file "$root"). 회수를 진행하지 않습니다."
  fi
  if [ "$lease_owner" != "remote" ]; then
    ho_ok "이미 로컬 소유입니다. 회수할 것이 없습니다."
    return 0
  fi

  # handback 도 --delete 를 거는 파괴적 동기화다. handoff 와 같은 봉쇄 검사를 반복한다.
  ho_bootstrap_check_symlink "$host" \
    || ho_abort "원격 핸드오프 트리가 기대한 심링크가 아닙니다. 회수를 진행하지 않습니다."
  local real_remote real_tree
  real_remote="$(ho_ssh "$host" "cd $(ho_shq "$remote_path") && pwd -P" 2>/dev/null | tr -d '\r')"
  real_tree="$(ho_ssh "$host" "cd $(ho_shq "$(ho_remote_tree)") && pwd -P" 2>/dev/null | tr -d '\r')"
  if [ -z "$real_remote" ] || [ -z "$real_tree" ]; then
    ho_abort "원격 실경로를 확인하지 못했습니다. 회수를 진행하지 않습니다."
  fi
  # `*` 는 빈 문자열도 매칭하므로 트리 루트 자체가 통과한다. handoff 와 같은 규칙을 쓴다.
  [ "$real_remote" != "$real_tree" ] \
    || ho_abort "원격 실경로가 트리 루트 자체입니다: $real_remote. 회수를 진행하지 않습니다."
  case "$real_remote/" in
    "$real_tree"/?*) ;;
    *) ho_abort "원격 실경로가 전용 트리 밖입니다: $real_remote (트리: $real_tree)
  경로 구성요소가 바뀌었을 수 있어 회수를 진행하지 않습니다." ;;
  esac

  uuid="$(ho_lease_get "$root" session_uuid 2>/dev/null || true)"
  ws="$(ho_lease_get "$root" workspace_id 2>/dev/null || true)"
  # handoff 시점의 시크릿 정책으로 지운다. 그 사이 설정이 바뀌어도 놓치지 않는다.
  local recorded_secrets
  recorded_secrets="$(ho_lease_get "$root" secrets_policy 2>/dev/null || true)"
  [ -n "$recorded_secrets" ] && ho_config_set_flag secrets "$recorded_secrets" && ho_config_load "$root"
  local agent_name; agent_name="$(ho_lease_get "$root" agent_name 2>/dev/null || true)"

  # --- 1. 원격 상태 판정 (D-52 fail-closed) ---
  local forced=0
  if [ -n "$uuid" ]; then
    state="$(ho_remote_agent_state "$host" "$uuid")"; rc=$?
  elif [ -n "$agent_name" ]; then
    # Codex 경로: 세션 uuid 가 없으므로 handoff 가 기록한 에이전트 이름으로 판정한다.
    # 이름으로도 못 찾을 때만 stale 이며, 작업 중이면 Claude 경로와 동일하게 거부한다.
    state="$(ho_remote_agent_state_by_name "$host" "$agent_name")"; rc=$?
  else
    if ho_remote_alive "$host" && ho_remote_herdr_alive "$host"; then rc=1; else rc=2; fi
  fi

  case "$rc" in
    2)
      ho_abort "원격 상태를 판정할 수 없습니다 (SSH 불통 또는 herdr 무응답). 파괴적 동기화를 진행하지 않습니다."
      ;;
    1)
      # pane 이 없다 -> 스테일 (D-43)
      ho_warn "원격에 해당 세션 pane 이 없습니다 (stale). 원격 작업분이 남아 있을 수 있습니다."
      if ! ho_confirm "원격 파일을 먼저 회수한 뒤 리스를 반환할까요?"; then
        ho_abort "사용자가 스테일 회수를 거절했습니다."
      fi
      ;;
    0)
      if [ "$state" = "working" ]; then
        local since elapsed
        since="$(ho_lease_get "$root" handoff_at 2>/dev/null || printf '')"
        elapsed="$(ho_elapsed_since "$since")"
        ho_err "원격 세션이 아직 작업 중입니다 (handoff: ${since:-?}, 경과 ${elapsed})."
        if ho_confirm "강제로 회수할까요? (원격 에이전트를 먼저 정지시킵니다)"; then
          forced=1
        else
          exit 3
        fi
      fi
      ;;
  esac

  # --- 2. 로컬 세션은 건드리지 않는다 ---
  #
  # 회수는 파일만 가져온다. 로컬 세션 파일은 그대로 둔다.
  # 원격 대화를 로컬에 덮어쓰려던 이전 설계가 갈래 판정, 하드 스톱, 백업 이름 충돌을
  # 줄줄이 만들었고, 정작 handback 을 요청하는 대화 자체가 그 파일을 늘리기 때문에
  # 판정이 늘 참이 되어 회수를 막았다. 복잡도의 근원이었다.
  #
  # 대신 원격 대화는 원격에 그대로 남는다. 어디서 볼 수 있는지 마지막에 안내한다.
  if [ -n "$uuid" ]; then
    ho_is_valid_uuid "$uuid" \
      || ho_abort "리스의 세션 uuid 형식이 올바르지 않습니다: $uuid"
  fi

  # --- 3. 강제 회수라면 원격 에이전트를 먼저 정지 (D-21) ---
  if [ "$forced" = "1" ]; then
    ho_info "원격 에이전트를 정지시킵니다..."
    if ! ho_remote_agent_stop "$host" "${uuid:-$agent_name}"; then
      ho_abort "원격 에이전트가 멈춘 것을 확인하지 못했습니다. 쓰는 도중에 회수하면 일관성이 깨지므로 진행하지 않습니다."
    fi
    ho_ok "  정지 확인됨"
  fi

  # --- 4. 회수 미리보기와 확인 (D-30: handback 은 확인한다) ---
  ho_info "회수 대상 미리보기:"
  # dry-run 이 실패했는데 "변경 없음" 으로 보여주면, 사용자는 아무 일도 없을 거라
  # 믿고 승인하는데 실제로는 --delete 가 도는 파괴적 회수가 일어난다.
  local changes dry_rc
  changes="$(ho_rsync_pull_dry "$root" "$host" "$remote_path")"; dry_rc=$?
  if [ "$dry_rc" -ne 0 ]; then
    ho_abort "회수 미리보기(dry-run)가 실패했습니다. 무엇이 바뀔지 모르는 채로 진행하지 않습니다."
  fi
  if [ -n "$changes" ]; then
    printf '%s\n' "$changes" | head -60 >&2
  else
    ho_say "  (변경 없음)"
  fi
  if ! ho_confirm "이대로 회수할까요?"; then
    ho_abort "사용자가 회수를 거절했습니다."
  fi

  # --- 5. 회수: 파일만 ---
  ho_backup_path_is_safe "$root" "$host" "$remote_path" \
    || ho_abort "백업 경로가 안전하지 않아 회수하지 않습니다."
  # 상태 확인·정지·미리보기·승인 사이에 원격 경로가 바뀌었을 수 있다.
  # --delete 를 걸기 직전에 실경로를 다시 본다.
  local recheck
  recheck="$(ho_ssh "$host" "cd $(ho_shq "$remote_path") && pwd -P" 2>/dev/null | tr -d '\r')"
  [ -n "$recheck" ] && [ "$recheck" = "$real_remote" ] \
    || ho_abort "회수 직전 원격 실경로가 달라졌습니다(이전: $real_remote, 지금: ${recheck:-확인불가}). 진행하지 않습니다."
  backup="$(ho_backup_dirname)"
  ho_backup_target_is_safe "$root" "$host" "$remote_path" "$backup" \
    || ho_abort "백업 대상 경로가 안전하지 않습니다."
  if ! ho_rsync_pull "$root" "$host" "$remote_path" "$backup"; then
    ho_err "파일 회수가 실패했거나 중단되었습니다. 리스는 그대로이며 재실행이 안전합니다."
    exit 4
  fi

  # --- 6. 시크릿 삭제 (리스 반환보다 먼저) ---
  # 반환 뒤에 지우면 실패했을 때 "회수 성공" 으로 보고되면서 원격에 .env 가 남는다.
  if ! ho_remote_purge_secrets "$host" "$remote_path" "$root"; then
    ho_err "원격에서 시크릿을 지우지 못했습니다. 리스를 반환하지 않습니다."
    ho_say "  파일은 이미 로컬로 회수되었습니다. 원격 정리 후 handback 을 다시 실행하세요."
    exit 4
  fi

  ho_lease_release_local "$root"

  # --- 7. workspace 정리 ---
  if [ -n "$ws" ]; then
    ho_remote_ws_close "$host" "$ws" || ho_warn "원격 workspace $ws 정리에 실패했습니다 (회수 자체는 성공)."
  fi

  ho_ok "가져왔습니다. 파일만 회수했고 로컬 세션은 그대로입니다."
  if [ -n "$uuid" ]; then
    ho_say "  원격이 무엇을 했는지는 원격 대화에 남아 있습니다:"
    ho_say "    ssh $host 'ls \$HOME/.claude/projects/$(ho_session_slug "$root")'"
    ho_say "    원격 세션 uuid: $uuid"
  fi
  return 0
}
