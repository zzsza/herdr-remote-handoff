#!/usr/bin/env bash
# 전송 엔진 (R1, R2, R5, D-14, D-47).
#
# --delete 를 켜되 삭제분까지 --backup-dir 에 남긴다.
# 리스 갱신은 전송과 세션 이관이 끝난 뒤에만 일어나므로, 그 이전 중단은
# 같은 명령 재실행으로 안전하게 이어진다.

set -o pipefail

ho_backup_dirname() { printf '.handoff-backup/%s' "$(date -u +%Y%m%dT%H%M%SZ)"; }

# .handoff-backup 이 외부를 가리키는 심링크면 백업과 .env* 가 격리 트리 밖에 쓰이고,
# 시크릿 정리의 find 는 그 심링크를 따라가지 않아 자격증명이 영구 잔존한다.
# 로컬·원격 양쪽에서 심링크가 아닌지 확인한다.
ho_backup_path_is_safe() {
  local root="$1" host="$2" remote_path="$3"
  [ ! -L "$root/.handoff-backup" ] || {
    ho_err "로컬 .handoff-backup 이 심링크입니다: $(readlink "$root/.handoff-backup")"
    return 1
  }
  if [ -n "$host" ] && [ -n "$remote_path" ]; then
    ho_ssh "$host" "test ! -L $(ho_shq "$remote_path/.handoff-backup")" >/dev/null 2>&1 || {
      ho_err "원격 .handoff-backup 이 심링크입니다: $host:$remote_path/.handoff-backup"
      return 1
    }
  fi
  return 0
}

# 전송 목록을 rsync --files-from 형식의 임시 파일로 만든다.
ho_write_filelist() {
  local root="$1" out="$2"
  ho_transfer_list "$root" > "$out"
  printf '%s' "$out"
}

# ho_rsync_push <root> <host> <remote_path> <filelist> <backup_dir> [extra...]
# 로컬 -> 원격
# --protect-args 는 rsync 3.0+ 전용이다. macOS 기본 rsync(openrsync/2.6.9 호환)와
# 구형 rsync 는 지원하지 않으므로 무조건 붙이면 전송 자체가 실패한다(실사용에서 발생).
# 양쪽이 모두 지원할 때만 쓰고, 아니면 경로에 셸 메타문자가 없음을 직접 보장한다.
_HO_PROTECT_ARGS_CACHE=""
ho_rsync_protect_args() {
  local host="$1"
  if [ -z "$_HO_PROTECT_ARGS_CACHE" ]; then
    if rsync --protect-args --version >/dev/null 2>&1 \
       && ho_ssh "$host" 'rsync --protect-args --version' >/dev/null 2>&1; then
      _HO_PROTECT_ARGS_CACHE="yes"
    else
      _HO_PROTECT_ARGS_CACHE="no"
    fi
  fi
  [ "$_HO_PROTECT_ARGS_CACHE" = "yes" ]
}

# --protect-args 를 못 쓰는 환경에서는 원격 경로가 원격 셸을 통과하므로
# 셸 메타문자가 든 경로를 아예 거부한다. 조용히 위험을 감수하지 않는다.
ho_remote_path_is_shell_safe() {
  local path="$1"
  case "$path" in
    *[\'\"\`\$\;\&\|\<\>\(\)\{\}\!\*\?\[\]$'\n'$'\t'' ']*) return 1 ;;
    *) return 0 ;;
  esac
}

# 전송 전에 한 번 판정해 rsync 에 넘길 플래그 배열을 만든다.
ho_rsync_transport_flags() {
  local host="$1" remote_path="$2"
  if ho_rsync_protect_args "$host"; then
    printf '%s\n' "--protect-args"
    return 0
  fi
  ho_remote_path_is_shell_safe "$remote_path" && return 0
  ho_err "이 환경의 rsync 는 --protect-args 를 지원하지 않는데(로컬 또는 원격),"
  ho_err "원격 경로에 셸 메타문자나 공백이 있어 안전하게 전송할 수 없습니다: $remote_path"
  return 1
}

# --delete 로부터 제어 파일을 보호하는 필터. 양방향에 동일하게 적용한다.
_ho_protect_filters() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] && printf '%s\n' "--filter=protect $f"
  done <<< "$HO_PROTECTED_CONTROL"
}

ho_rsync_push() {
  local root="$1" host="$2" remote_path="$3" filelist="$4" backup="$5"; shift 5
  local -a prot=() tflag=(); local pf
  while IFS= read -r pf; do [ -n "$pf" ] && prot+=( "$pf" ); done < <(_ho_protect_filters)
  while IFS= read -r pf; do [ -n "$pf" ] && tflag+=( "$pf" ); done < <(ho_rsync_transport_flags "$host" "$remote_path") || return 1
  rsync -a --delete "${tflag[@]}" "${prot[@]}" \
    --files-from="$filelist" \
    --backup --backup-dir="$backup" \
    --rsh="ssh -o BatchMode=yes -o ConnectTimeout=10" \
    "$@" \
    "$root/" "$host:$remote_path/"
}

# ho_rsync_pull <root> <host> <remote_path> <backup_dir> [extra...]
# 원격 -> 로컬. 회수 때는 원격의 목록 파일을 만들 수 없으므로
# 제외 규칙을 --exclude 로 넘긴다.
ho_rsync_pull() {
  local root="$1" host="$2" remote_path="$3" backup="$4"; shift 4
  local -a excl=()
  local p pf
  while IFS= read -r pf; do [ -n "$pf" ] && excl+=( "$pf" ); done < <(_ho_protect_filters)
  while IFS= read -r p; do
    [ -n "$p" ] && excl+=( "--exclude=$p" )
  done < <(ho_exclude_patterns "$root")
  excl+=( "--exclude=.handoff-backup" )
  local -a tflag=(); local tf
  while IFS= read -r tf; do [ -n "$tf" ] && tflag+=( "$tf" ); done < <(ho_rsync_transport_flags "$host" "$remote_path") || return 1
  rsync -a --delete "${tflag[@]}" \
    "${excl[@]}" \
    --backup --backup-dir="$backup" \
    --rsh="ssh -o BatchMode=yes -o ConnectTimeout=10" \
    "$@" \
    "$host:$remote_path/" "$root/"
}

# 미리보기 (전송하지 않음)
ho_rsync_push_dry() {
  local root="$1" host="$2" remote_path="$3" filelist="$4"
  rsync -a --delete --dry-run --itemize-changes \
    --files-from="$filelist" \
    --rsh="ssh -o BatchMode=yes -o ConnectTimeout=10" \
    "$root/" "$host:$remote_path/" 2>/dev/null
}

ho_rsync_pull_dry() {
  local root="$1" host="$2" remote_path="$3"
  local -a excl=()
  local p pf
  while IFS= read -r pf; do [ -n "$pf" ] && excl+=( "$pf" ); done < <(_ho_protect_filters)
  while IFS= read -r p; do
    [ -n "$p" ] && excl+=( "--exclude=$p" )
  done < <(ho_exclude_patterns "$root")
  excl+=( "--exclude=.handoff-backup" )
  local -a tflag=(); local tf
  while IFS= read -r tf; do [ -n "$tf" ] && tflag+=( "$tf" ); done < <(ho_rsync_transport_flags "$host" "$remote_path") || return 1
  rsync -a --delete --dry-run --itemize-changes "${tflag[@]}" \
    "${excl[@]}" \
    --rsh="ssh -o BatchMode=yes -o ConnectTimeout=10" \
    "$host:$remote_path/" "$root/" 2>/dev/null
}

# 세션 파일 이관 (D-02, D-41).
# 원격 HOME 은 로컬과 다르지만 slug 는 프로젝트 절대경로 기준이라 충돌하지 않는다.
# 실제로 쓸 타임스탬프 디렉터리까지 심링크가 아닌지 확인한다.
# 상위만 보면 미리 만들어 둔 .handoff-backup/<ts> 심링크가 그대로 백업 대상이 된다.
ho_backup_target_is_safe() {
  local root="$1" host="$2" remote_path="$3" backup="$4"
  [ ! -L "$root/$backup" ] || { ho_err "로컬 백업 대상이 심링크입니다: $root/$backup"; return 1; }
  if [ -n "$host" ] && [ -n "$remote_path" ]; then
    ho_ssh "$host" "test ! -L $(ho_shq "$remote_path/$backup")" >/dev/null 2>&1 \
      || { ho_err "원격 백업 대상이 심링크입니다: $host:$remote_path/$backup"; return 1; }
  fi
  return 0
}

ho_push_session() {
  local host="$1" root="$2" session_file="$3"
  local slug remote_expanded
  slug="$(ho_session_slug "$root")"
  remote_expanded="$(ho_ssh "$host" "printf %s \"\$HOME/.claude/projects/\"")" || return 1
  remote_expanded="$remote_expanded$slug"
  ho_ssh "$host" "mkdir -p $(ho_shq "$remote_expanded")" || return 1
  rsync -a --rsh="ssh -o BatchMode=yes -o ConnectTimeout=10" \
    "$session_file" "$host:$remote_expanded/" 2>/dev/null
}


# --force 로 리스를 덮어쓰기 전에 원격 세션 사본을 보존한다.
# 이 백업이 없으면 원격에서 진행 중이던 대화가 오래된 로컬 사본에 덮여 사라진다.
ho_backup_remote_session() {
  local host="$1" root="$2" uuid="$3" slug remote_dir stamp
  [ -n "$uuid" ] || return 0
  slug="$(ho_session_slug "$root")"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  remote_dir="$(ho_ssh "$host" "printf %s \"\$HOME/.claude/projects/\"" 2>/dev/null)$slug"
  ho_ssh "$host" "test -f $(ho_shq "$remote_dir/$uuid.jsonl") && mkdir -p $(ho_shq "$remote_dir/.handoff-session-backup") && cp $(ho_shq "$remote_dir/$uuid.jsonl") $(ho_shq "$remote_dir/.handoff-session-backup/$uuid.$stamp.jsonl")" >/dev/null 2>&1
}

# 회수 성공 직후 원격에서 시크릿만 지운다 (R7, D-48).
# 트리와 백업 양쪽을 대상으로 하며, 시크릿이 아닌 포함 파일은 남긴다.
# 실패를 삼키지 않는다. 하나라도 실패하면 0 이 아닌 값을 반환해 호출부가
# 리스를 반환하기 전에 멈출 수 있게 한다.
ho_remote_purge_secrets() {
  local host="$1" remote_path="$2" root="$3"
  local pat rc=0 left
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    if ! ho_is_safe_pattern "$pat"; then
      ho_err "시크릿 패턴에 셸 메타문자가 있어 원격 삭제를 수행하지 않습니다: $pat"
      rc=1; continue
    fi
    # 슬래시가 든 패턴(.claude/settings.local.json)은 -name 으로 절대 매칭되지 않는다.
    if case "$pat" in */*) true ;; *) false ;; esac; then
      ho_ssh "$host" "find $(ho_shq "$remote_path") -path $(ho_shq "*/$pat") \\( -type f -o -type l \\) -delete" >/dev/null 2>&1 || rc=1
    else
      ho_ssh "$host" "find $(ho_shq "$remote_path") -name $(ho_shq "$pat") \\( -type f -o -type l \\) -delete" >/dev/null 2>&1 || rc=1
    fi
  done < <(ho_secret_patterns)
  # 실제로 남아 있는지 확인한다. 삭제 명령이 성공해도 잔존하면 실패로 본다.
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    ho_is_safe_pattern "$pat" || continue
    if case "$pat" in */*) true ;; *) false ;; esac; then
      left="$(ho_ssh "$host" "find $(ho_shq "$remote_path") -path $(ho_shq "*/$pat") \\( -type f -o -type l \\) -print -quit" 2>/dev/null)"
    else
      left="$(ho_ssh "$host" "find $(ho_shq "$remote_path") -name $(ho_shq "$pat") \\( -type f -o -type l \\) -print -quit" 2>/dev/null)"
    fi
    [ -n "$left" ] && { ho_err "원격에 시크릿이 남아 있습니다: $left"; rc=1; }
  done < <(ho_secret_patterns)
  return $rc
}
