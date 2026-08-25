#!/usr/bin/env bash
# 원격 어댑터 (R4, R14, D-01, D-23, D-24).
#
# 원격의 login shell PATH 에 herdr/claude 가 없으므로 항상 PATH 를 앞에 붙인다.
# 기존 workspace 는 조회만 하고 절대 재사용하거나 닫지 않는다.

set -o pipefail

HO_REMOTE_PATH_PREFIX='export PATH="$HOME/.local/bin:$PATH";'

# ho_ssh <host> <command...>
# ssh 는 종료코드 255 를 "연결 자체가 안 됐다"는 뜻으로만 쓴다.
# 그 경우에만 한 번 더 시도한다. 일시적인 연결 실패가 "원격에 claude 가 없습니다"
# 같은 엉뚱한 사전조건 실패로 보고되어 handoff 가 중단되는 일을 실제로 겪었다.
# 원격 명령 자체가 실패한 경우(1 등)는 재시도하지 않는다. 그건 진짜 실패다.
ho_ssh() {
  local host="$1"; shift
  local rc
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "$HO_REMOTE_PATH_PREFIX $*"
  rc=$?
  if [ "$rc" = "255" ]; then
    sleep 1
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "$HO_REMOTE_PATH_PREFIX $*"
    rc=$?
  fi
  return "$rc"
}

ho_remote_alive() {
  ho_ssh "$1" 'echo ok' >/dev/null 2>&1
}

# 원격에서 그 경로가 가리킬 실제 디렉터리.
# 설정이 비어 있으면 원격 홈을 조회해 <원격 홈>/.handoff-tree 로 파생한다.
# 조회는 세션 안에서 한 번만 한다.
ho_remote_tree_target() {
  local host="$1" v
  v="$(ho_config_get remote_tree_target)"
  if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  if [ -z "${HO_REMOTE_HOME_CACHE:-}" ]; then
    HO_REMOTE_HOME_CACHE="$(ho_remote_home "$host")" || return 1
  fi
  [ -n "$HO_REMOTE_HOME_CACHE" ] || return 1
  printf '%s/.handoff-tree' "$HO_REMOTE_HOME_CACHE"
}

# 원격 홈의 실경로. 심링크가 섞여도 실제 위치를 얻는다.
ho_remote_home() {
  local h
  h="$(ho_ssh "$1" 'cd "$HOME" && pwd -P' 2>/dev/null | tr -d '\r')" || return 1
  case "$h" in /?*) printf '%s' "$h" ;; *) return 1 ;; esac
}

# herdr 서버가 응답하는가
ho_remote_herdr_alive() {
  ho_ssh "$1" 'herdr workspace list' >/dev/null 2>&1
}

# ho_remote_free_bytes <host> <path>
# 아직 만들어지지 않은 경로에는 df 가 실패한다. 존재하는 가장 가까운 조상으로 올라간다.
ho_remote_free_bytes() {
  local host="$1" path="${2:-/}"
  ho_ssh "$host" "p=$(ho_shq "$path"); while [ ! -e \"\$p\" ] && [ \"\$p\" != / ]; do p=\$(dirname \"\$p\"); done; df -k \"\$p\" | tail -1 | awk '{print \$4}'" 2>/dev/null \
    | tr -d ' ' | awk '{printf "%d", $1*1024}'
}

ho_remote_path_exists() {
  ho_ssh "$1" "test -e $(ho_shq "$2")" >/dev/null 2>&1
}

# 핸드오프 트리 심링크가 준비되었는가 (D-42, D-54)


# --- herdr workspace ---

_ho_unused_ws_ids() {
  ho_ssh "$1" 'herdr workspace list' 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
for w in d.get('result',{}).get('workspaces',[]):
    print(w.get('workspace_id',''))
"
}

# ho_remote_ws_create <host> <cwd> <label>  -> workspace_id
# 항상 새로 만든다 (D-24). 기존 것을 재사용하지 않는다.
ho_remote_ws_create() {
  local host="$1" cwd="$2" label="$3"
  ho_ssh "$host" "herdr workspace create --cwd $(ho_shq "$cwd") --label $(ho_shq "$label") --no-focus" 2>/dev/null \
  | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
r=d.get('result',{})
w=r.get('workspace') or r
print(w.get('workspace_id') or w.get('id') or '')
"
}

ho_remote_ws_close() {
  ho_ssh "$1" "herdr workspace close $(ho_shq "$2")" >/dev/null 2>&1
}

# workspace 의 첫 pane id
ho_remote_ws_pane() {
  local host="$1" ws="$2"
  ho_ssh "$host" "herdr pane list" 2>/dev/null | python3 -c "
import json,sys
ws=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
for p in d.get('result',{}).get('panes',[]):
    if p.get('workspace_id')==ws:
        print(p.get('pane_id',''))
        break
" "$ws"
}

# --- herdr agent ---

# 세션 uuid 로 에이전트 레코드를 찾는다. 없으면 비어 있는 출력.
# ho_remote_agent_by_session <host> <session_uuid> -> "<status>\t<pane_id>\t<workspace_id>"
# 조회 자체가 실패하면 빈 출력을 내지 말고 실패를 반환해야 한다.
# 빈 출력은 "에이전트 없음" 으로 읽혀 stale 판정과 파괴적 회수로 이어진다.
ho_remote_agent_by_session() {
  local host="$1" uuid="$2" raw
  raw="$(ho_ssh "$host" 'herdr agent list' 2>/dev/null)" || return 2
  [ -n "$raw" ] || return 2
  printf '%s' "$raw" | python3 -c "
import json,sys
uuid=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit(2)
for a in d.get('result',{}).get('agents',[]):
    s=(a.get('agent_session') or {}).get('value')
    if s==uuid:
        print('%s\t%s\t%s'%(a.get('agent_status',''),a.get('pane_id',''),a.get('workspace_id','')))
        break
" "$uuid"
}

# pane 상태 코드 (D-43, D-52):
#   0 = 존재하고 상태를 알아냄 (stdout 에 working|idle|... )
#   1 = 원격은 응답하는데 해당 에이전트가 없음 -> stale 후보
#   2 = 판정 불가 (SSH 불통 또는 herdr 무응답) -> fail-closed
ho_remote_agent_state() {
  local host="$1" uuid="$2" row rc
  ho_remote_alive "$host" || return 2
  ho_remote_herdr_alive "$host" || return 2
  row="$(ho_remote_agent_by_session "$host" "$uuid")"; rc=$?
  [ "$rc" -eq 2 ] && return 2   # 조회·파싱 실패는 판정 불가
  [ -n "$row" ] || return 1
  printf '%s' "${row%%$'\t'*}"
  return 0
}

# 폴더 신뢰 선기록.
# bypassPermissions 도 첫 실행의 폴더 신뢰 대화상자는 건너뛰지 않아서, 새 프로젝트의
# 첫 handoff 마다 자율 기동이 trust 프롬프트에 막혀 startup timeout(exit 5)이 된다.
# 방금 로컬에서 전송한 트리라 신뢰 판단은 이미 성립했으므로, 기동 전에 원격
# ~/.claude.json 에 수락을 기록한다. 수락 기록은 실경로 키로 남지만(세션은 심링크
# 경로로 뜬다) 확실하게 둘 다 기록한다.
# 실패해도 기동은 계속한다. 그 경우 종전처럼 trust 대화상자에서 멈출 뿐이다.
ho_remote_trust_project() {
  local host="$1" path="$2"
  ho_ssh "$host" "python3 - $(ho_shq "$path") <<'PY'
import json, os, sys
path = sys.argv[1]
cfg = os.path.expanduser('~/.claude.json')
d = {}
if os.path.exists(cfg):
    with open(cfg) as f:
        d = json.load(f)
projects = d.setdefault('projects', {})
for p in {path, os.path.realpath(path)}:
    projects.setdefault(p, {})['hasTrustDialogAccepted'] = True
tmp = cfg + '.handoff-tmp'
# 고정 경로의 임시 파일이 심링크면 그 대상을 잘라버린다. 지우고 배타 생성한다.
if os.path.islink(tmp) or os.path.exists(tmp):
    os.unlink(tmp)
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
with os.fdopen(fd, 'w') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
os.replace(tmp, cfg)
PY"
}

# 자율 세션 기동 (D-17, D-18, D-41).
# ho_remote_agent_start <host> <pane_id> <name> <session_uuid> <settings_path> <prompt>
# -p 로 띄우면 안 된다. 헤드리스 1회 실행이라 끝나면 대화가 남지 않고,
# 원격에 붙어도 볼 것이 없으며 이어서 지시할 수도 없다.
# 대화형으로 띄운 뒤 지시문을 프롬프트로 넣는다. 그러면 실제 창이 뜨고,
# herdr --remote 로 붙어 그대로 보고 이어서 대화할 수 있다.
ho_remote_agent_start() {
  local host="$1" pane="$2" name="$3" uuid="$4" settings="$5" prompt="$6"
  ho_ssh "$host" "herdr agent start $(ho_shq "$name") --kind claude --pane $(ho_shq "$pane") -- \
    --resume $(ho_shq "$uuid") --permission-mode bypassPermissions --settings $(ho_shq "$settings")" || return 1
  ho_remote_agent_prompt "$host" "$name" "$prompt"
}

# 기동된 대화형 에이전트에 지시문을 넣는다.
#
# --wait 없이 보내면 안 된다. 기동 직후에는 아직 입력을 받을 준비가 안 돼서
# 텍스트가 유실되는데, CLI 는 그것을 감지하지 못하고 종료코드 0 과
# agent_prompted 로 성공을 오보한다(실기계에서 재현 확인: state_change_seq 불변).
#
# --until working 을 쓴다. 지시문이 실제로 들어가 에이전트가 일을 시작한 것까지만
# 확인하고 돌아온다. 완료를 기다리지 않는 이유는, handoff 는 넘기고 끝나는 것이고
# 진행은 원격에서 이어지기 때문이다.
ho_remote_agent_prompt() {
  local host="$1" name="$2" prompt="$3"
  ho_ssh "$host" "herdr agent prompt $(ho_shq "$name") $(ho_shq "$prompt") \
    --wait --until working --timeout 20000"
}

# Codex 새 세션 (D-35, D-44)
# Codex 는 처음 보는 디렉터리에서 신뢰 확인을 띄워 자율 실행을 멈춘다.
# --dangerously-bypass-approvals-and-sandbox 가 Claude 의 bypassPermissions 에 대응하며,
# 승인된 무확인 자율 실행(D-16/D-17) 을 Codex 경로에서도 성립시킨다.
# Claude 경로와 같은 이유로 지시문을 인자로 넣지 않는다.
# 대화형으로 띄운 뒤 프롬프트로 넣어야 원격에서 창을 보고 이어서 대화할 수 있다.
ho_remote_codex_start() {
  local host="$1" pane="$2" name="$3" prompt="$4"
  ho_ssh "$host" "herdr agent start $(ho_shq "$name") --kind codex --pane $(ho_shq "$pane") -- \
    --dangerously-bypass-approvals-and-sandbox" || return 1
  # Codex 는 기동 직후 시작 화면을 그리는 동안 입력을 받지 못하는데, herdr 는 그
  # 스피너를 working 으로 오인한다. 그래서 --until working 만으로는 지시문 유실을
  # 못 거른다(실기계에서 재현: agent_prompted 성공 보고 뒤 입력창이 비어 있음).
  # 입력 가능(idle)을 먼저 확인한 뒤에 넣는다. 확인 실패면 넣지 않고 실패를 반환한다 -
  # 유실된 채 성공 보고하는 것보다 exit 5 로 드러나는 쪽이 낫다.
  ho_ssh "$host" "herdr agent wait $(ho_shq "$name") --until idle --timeout 20000" >/dev/null 2>&1 \
    || return 1
  ho_remote_agent_prompt "$host" "$name" "$prompt"
}

# 강제 회수 전 정지 (D-21). kill 이 아니라 인터럽트 키를 보낸다.
# 정지시키고 실제로 멈췄는지 확인한다. 확인되지 않으면 실패를 반환한다 -
# 멈추지 않은 에이전트가 쓰는 도중에 회수하면 일관성 보장이 깨진다.
# 반환 0 = 멈춤 확인, 1 = 확인 실패.
ho_remote_agent_stop() {
  local host="$1" target="$2" i state rc
  for i in 1 2 3; do
    ho_ssh "$host" "herdr agent send-keys $(ho_shq "$target") esc" >/dev/null 2>&1 || true
    ho_ssh "$host" "herdr agent wait $(ho_shq "$target") --until idle --timeout 10000" >/dev/null 2>&1 || true
    state="$(ho_remote_agent_state "$host" "$target")"; rc=$?
    # 세션 uuid 로 못 찾으면 이름으로 다시 본다
    if [ "$rc" = "1" ]; then
      state="$(ho_remote_agent_state_by_name "$host" "$target")"; rc=$?
    fi
    case "$rc" in
      1) return 0 ;;            # 에이전트가 사라짐 = 더 이상 쓰지 않음
      0) [ "$state" != "working" ] && return 0 ;;
      2) return 1 ;;            # 관측 불가
    esac
  done
  return 1
}

# 이름으로 에이전트를 조회한다 (Codex 경로는 세션 uuid 가 없다).
# 반환 규약은 ho_remote_agent_state 와 같다.
ho_remote_agent_by_name() {
  local host="$1" name="$2" raw
  raw="$(ho_ssh "$host" 'herdr agent list' 2>/dev/null)" || return 2
  [ -n "$raw" ] || return 2
  printf '%s' "$raw" | python3 -c "
import json,sys
name=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit(2)
for a in d.get('result',{}).get('agents',[]):
    if a.get('name')==name:
        print('%s\\t%s\\t%s'%(a.get('agent_status',''),a.get('pane_id',''),a.get('workspace_id','')))
        break
" "$name"
}

ho_remote_agent_state_by_name() {
  local host="$1" name="$2" row rc
  ho_remote_alive "$host" || return 2
  ho_remote_herdr_alive "$host" || return 2
  row="$(ho_remote_agent_by_name "$host" "$name")"; rc=$?
  [ "$rc" -eq 2 ] && return 2
  [ -n "$row" ] || return 1
  printf '%s' "${row%%$'\t'*}"
  return 0
}
