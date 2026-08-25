#!/usr/bin/env bash
# 리스 모델 (R8, R10, D-13, D-26, D-43, D-49).
#
# .handoff-lease 는 JSON 이며 소유자가 반환된 뒤에도 삭제하지 않는다.
# 파일 리스는 승인 시 강제 가능하고, 세션 리스는 하드 스톱이다.

set -o pipefail

ho_lease_file() { printf '%s/.handoff-lease' "$1"; }

# ho_lease_get <root> <key>
ho_lease_get() {
  local file
  file="$(ho_lease_file "$1")"
  [ -r "$file" ] || return 1
  python3 - "$file" "$2" <<'PY' 2>/dev/null
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
v=d.get(sys.argv[2])
if v is None: sys.exit(1)
print(v)
PY
}

# 소유자. 리스 파일이 아예 없으면 local (아직 한 번도 안 넘긴 상태).
# 파일은 있는데 읽을 수 없거나 owner 가 없으면 'unknown' 이다.
# 이걸 local 로 퉁치면 원격 에이전트가 도는데도 handoff 가 그냥 진행된다.
ho_lease_owner() {
  local root="$1" file v
  file="$(ho_lease_file "$root")"
  if [ ! -e "$file" ]; then printf 'local'; return; fi
  if v="$(ho_lease_get "$root" owner 2>/dev/null)" && [ -n "$v" ]; then
    printf '%s' "$v"
  else
    printf 'unknown'
  fi
}

# ho_lease_set <root> <key=value> ...
ho_lease_set() {
  local root="$1"; shift
  local file
  file="$(ho_lease_file "$root")"
  python3 - "$file" "$@" <<'PY'
import json,os,sys
path=sys.argv[1]
d={}
if os.path.exists(path):
    try: d=json.load(open(path))
    except Exception: d={}
for kv in sys.argv[2:]:
    k,_,v=kv.partition('=')
    d[k]=v
tmp=path+'.tmp'
# 임시 파일이 심링크면 open(...,'w') 이 그 대상(예: ~/.ssh/config)을 먼저 잘라버린다.
# 남아 있는 것은 지우고 O_NOFOLLOW 로 배타 생성한다.
if os.path.islink(tmp) or os.path.exists(tmp):
    os.unlink(tmp)
fd=os.open(tmp, os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW, 0o600)
with os.fdopen(fd,'w') as f:
    json.dump(d,f,ensure_ascii=False,indent=2,sort_keys=True)
    f.write('\n')
os.replace(tmp,path)
PY
}

ho_lease_claim_remote() {
  local root="$1" session="$2" host="$3" ws="$4"
  # 이때 쓰인 시크릿 정책을 함께 남긴다. handback 때 설정이 바뀌었거나
  # --secrets 오버라이드가 사라지면 지워야 할 파일을 놓친다.
  ho_lease_set "$root" \
    "secrets_policy=$(ho_config_get secrets)" \
    "owner=remote" \
    "handoff_at=$(ho_now_iso)" \
    "session_uuid=$session" \
    "remote_host=$host" \
    "workspace_id=$ws"
}

ho_lease_release_local() {
  local root="$1"
  ho_lease_set "$root" \
    "owner=local" \
    "handback_at=$(ho_now_iso)" \
    "workspace_id="
}

# 스테일 판정 (D-43): owner=remote 인데 원격에 그 workspace/pane 이 없다.
# pane 존재 여부는 호출부가 판정해 넘긴다: 0=존재, 1=없음, 2=판정불가
# ho_lease_is_stale <root> <pane_state_code>
ho_lease_is_stale() {
  local root="$1" pane_code="$2"
  [ "$(ho_lease_owner "$root")" = "remote" ] || return 1
  [ "$pane_code" = "1" ] || return 1
  return 0
}


# 이관 직후 기준선을 기록한다.
ho_lease_record_session_bytes() {
  local root="$1" session_file="$2" size
  [ -f "$session_file" ] || return 0
  size="$(wc -c < "$session_file" | tr -d ' ')"
  ho_lease_set "$root" "session_bytes=$size"
}

# 원격 pane 이 없을 때, 정상 완료인지 비정상 stale 인지 구분한다.
# -p 모드 자율 실행은 작업을 마치면 에이전트가 종료되므로 pane 이 사라지는 것이 정상이다.
# 원격 세션 파일이 이관 시점보다 커졌으면 작업이 실제로 진행된 뒤 끝난 것이다.
# 반환 0 = 정상 완료, 1 = 판단 불가(비정상 stale 로 취급)
ho_remote_session_advanced() {
  local host="$1" root="$2" uuid="$3" baseline="$4" slug remote_size
  [ -n "$uuid" ] || return 1
  [ -n "$baseline" ] && [ "$baseline" -gt 0 ] 2>/dev/null || return 1
  # 리스는 프로젝트가 만질 수 있는 파일이다. uuid 를 그대로 원격 셸에 넣으면
  # 조작된 리스로 임의 명령을 실행할 수 있다. 형식을 강제하고 인용한다.
  case "$uuid" in
    *[!0-9a-fA-F-]*|'') return 1 ;;
  esac
  slug="$(ho_session_slug "$root")"
  remote_size="$(ho_ssh "$host" "wc -c < $(ho_shq "\$HOME/.claude/projects/$slug/$uuid.jsonl")" 2>/dev/null | tr -d ' \r')"
  [ -n "$remote_size" ] || return 1
  [ "$remote_size" -gt "$baseline" ] 2>/dev/null
}
