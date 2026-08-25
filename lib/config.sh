#!/usr/bin/env bash
# 설정 계층: CLI 플래그 > 프로젝트 .handoffrc > 전역 config.toml > 내장 기본값 (R13)
#
# 각 설정 항목은 HO_<KEY> 전역 변수로 노출된다.
# 플래그는 호출부가 ho_config_set_flag 로 먼저 등록하고, ho_config_load 가
# 낮은 우선순위 계층을 채운다. 이미 플래그로 정해진 키는 덮어쓰지 않는다.

set -o pipefail

# 오버라이드 가능한 기본값. 순서는 문서와 테스트가 함께 쓴다.
HO_CONFIG_KEYS="remote remote_tree remote_tree_target deny_extra include exclude secrets tree_retention_days backup_retention_days size_confirm_bytes free_space_warn_gib"

ho_config_defaults() {
  HO_DEFAULT_remote="mini"
  # 이 도구는 로컬과 원격의 프로젝트 절대경로가 같다는 전제 위에 돈다.
  # 그래서 핸드오프 트리는 언제나 로컬 홈 경로이고, 원격에 같은 이름의
  # 심링크를 만들어 맞춘다. 사람마다 다르므로 하드코딩하지 않는다.
  HO_DEFAULT_remote_tree="$HOME"
  # 그 심링크가 가리킬 원격의 실제 디렉터리. 비어 있으면 원격 홈을 조회해
  # <원격 홈>/.handoff-tree 로 파생한다(ho_remote_tree_target).
  HO_DEFAULT_remote_tree_target=""
  # 원격 자율 세션에서 추가로 차단할 경로(콤마 구분). 그 머신에만 있는
  # 운영 자산을 지키기 위한 것으로, 기본은 비어 있다.
  HO_DEFAULT_deny_extra=""
  HO_DEFAULT_include=".env*,*.local.json,.claude/settings.local.json,*.sqlite,*.db"
  HO_DEFAULT_exclude="node_modules,.venv,__pycache__,dist,build,.next,.DS_Store"
  HO_DEFAULT_secrets=".env*"
  HO_DEFAULT_tree_retention_days="14"
  HO_DEFAULT_backup_retention_days="7"
  HO_DEFAULT_size_confirm_bytes="524288000"
  HO_DEFAULT_free_space_warn_gib="20"
}

ho_config_reset() {
  local k
  for k in $HO_CONFIG_KEYS; do
    unset "HO_$k" "HO_FLAG_$k" "HO_SRC_$k" 2>/dev/null || true
  done
}

# ho_config_set_flag <key> <value>
ho_config_set_flag() {
  local key="$1" val="$2"
  case " $HO_CONFIG_KEYS " in
    *" $key "*) ;;
    *) ho_die "unknown config key: $key" ;;
  esac
  printf -v "HO_FLAG_$key" '%s' "$val"
}

# key = value 형태의 아주 작은 파서. TOML/rc 공통.
# 따옴표를 벗기고 주석과 빈 줄과 섹션 헤더를 버린다.
_ho_config_read_file() {
  local file="$1" prefix="$2" line key val
  [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    case "$line" in \[*\]) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    key="$(printf '%s' "$key" | sed -e 's/[[:space:]]*$//')"
    val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//')"
    # 양쪽 따옴표 제거
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    # TOML 배열 [a, b] -> a,b
    case "$val" in
      \[*\])
        val="${val#\[}"; val="${val%\]}"
        val="$(printf '%s' "$val" | tr -d '"'\''[:space:]')"
        ;;
    esac
    case " $HO_CONFIG_KEYS " in
      *" $key "*) printf -v "${prefix}$key" '%s' "$val" ;;
    esac
  done < "$file"
}

# ho_config_load <project_dir>
# 우선순위대로 병합하고 각 키의 출처를 HO_SRC_<key> 에 남긴다.
ho_config_load() {
  local project_dir="${1:-$PWD}" k flagvar projvar globvar
  ho_config_defaults

  local global_file="${HO_GLOBAL_CONFIG:-$HOME/.config/handoff/config.toml}"
  local project_file="$project_dir/.handoffrc"

  _ho_config_read_file "$global_file" "HO_GLOBALV_"
  _ho_config_read_file "$project_file" "HO_PROJV_"

  for k in $HO_CONFIG_KEYS; do
    flagvar="HO_FLAG_$k"
    projvar="HO_PROJV_$k"
    globvar="HO_GLOBALV_$k"
    if [ -n "${!flagvar-}" ]; then
      printf -v "HO_$k" '%s' "${!flagvar}"
      printf -v "HO_SRC_$k" '%s' "flag"
    elif [ -n "${!projvar-}" ]; then
      printf -v "HO_$k" '%s' "${!projvar}"
      printf -v "HO_SRC_$k" '%s' "project"
    elif [ -n "${!globvar-}" ]; then
      printf -v "HO_$k" '%s' "${!globvar}"
      printf -v "HO_SRC_$k" '%s' "global"
    else
      local defvar="HO_DEFAULT_$k"
      printf -v "HO_$k" '%s' "${!defvar}"
      printf -v "HO_SRC_$k" '%s' "default"
    fi
    unset "$projvar" "$globvar" 2>/dev/null || true
  done
  ho_config_validate
}

# 숫자여야 하는 설정은 숫자인지 확인한다.
# 검증 없이 $(( )) 에 들어가면 프로젝트 설정 파일로 임의 명령이 실행될 수 있다.
HO_NUMERIC_KEYS="tree_retention_days backup_retention_days size_confirm_bytes free_space_warn_gib"

# 절대경로여야 하는 설정. 빈 값은 "파생하라"는 뜻이라 허용한다.
HO_PATH_KEYS="remote_tree remote_tree_target"

ho_config_validate() {
  local k v
  for k in $HO_NUMERIC_KEYS; do
    v="$(ho_config_get "$k")"
    case "$v" in
      ''|*[!0-9]*)
        ho_err "설정 $k 는 0 이상의 정수여야 합니다 (현재: $v). 기본값으로 되돌립니다."
        local defvar="HO_DEFAULT_$k"
        printf -v "HO_$k" '%s' "${!defvar}"
        ;;
    esac
  done
  # 경로 설정은 셸에 들어가고 rsync --delete 의 대상이 되므로
  # 메타문자뿐 아니라 절대경로인지까지 확인한다.
  for k in $HO_PATH_KEYS; do
    v="$(ho_config_get "$k")"
    if [ -n "$v" ] && { ! ho_is_safe_pattern "$v" || case "$v" in /?*) false ;; *) true ;; esac; }; then
      ho_err "설정 $k 는 절대경로여야 하고 셸 메타문자를 담을 수 없습니다. 기본값으로 되돌립니다: $v"
      local defvar="HO_DEFAULT_$k"
      printf -v "HO_$k" '%s' "${!defvar}"
    fi
  done
  # 패턴 설정도 셸에 들어가므로 메타문자를 거른다.
  for k in include exclude secrets remote deny_extra; do
    v="$(ho_config_get "$k")"
    if ! ho_is_safe_pattern "$v"; then
      ho_err "설정 $k 에 셸 메타문자가 있습니다. 기본값으로 되돌립니다: $v"
      local defvar="HO_DEFAULT_$k"
      printf -v "HO_$k" '%s' "${!defvar}"
    fi
  done
}

# ho_config_get <key>
ho_config_get() {
  local v="HO_$1"
  printf '%s' "${!v-}"
}

# ho_config_source <key>  -> flag|project|global|default
ho_config_source() {
  local v="HO_SRC_$1"
  printf '%s' "${!v-}"
}

# 콤마 목록을 줄 단위로
ho_config_list() {
  ho_config_get "$1" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' || true
}

# 핸드오프 트리는 로컬 홈 경로다. 로컬과 원격의 프로젝트 절대경로가 같아야
# 세션 파일 안의 경로가 무손실로 넘어가기 때문이다. 설정으로 바꿀 수 있다.
ho_remote_tree() { ho_config_get remote_tree; }
