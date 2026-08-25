#!/usr/bin/env bash
# UserPromptSubmit 훅: 이관된 프로젝트에서 로컬 작업을 막는다 (R15, SC4).
#
# 설계 원칙 세 가지.
#  1. 리스 파일이 없거나 owner 가 local 이면 아무것도 하지 않는다. 평소 작업을 방해하면 안 된다.
#  2. 넘어간 그 세션만 막는다. 같은 경로에서 다른 세션으로 별개 작업을 할 수 있어야 한다.
#  3. 회수 자체는 차단 상태에서도 가능해야 하므로 handback 관련 입력은 통과시킨다.
#  4. 어떤 오류가 나도 통과시킨다. 훅 버그가 사용자를 잠그는 일이 없어야 한다.
#
# 차단은 exit 2 + stderr 로 한다 (Claude Code UserPromptSubmit 차단 규약).

set -uo pipefail

payload="$(cat 2>/dev/null || true)"

pass() { exit 0; }

command -v python3 >/dev/null 2>&1 || pass

read -r cwd session_id prompt <<EOF
$(printf '%s' "$payload" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print('  ')
    sys.exit(0)
cwd=(d.get('cwd') or '').replace('\n',' ')
sid=(d.get('session_id') or '-').replace('\n',' ') or '-'
p=(d.get('prompt') or '').replace('\n',' ')
print(cwd, sid, p)
" 2>/dev/null)
EOF

[ -n "${cwd:-}" ] || pass
[ -d "$cwd" ] || pass

# 프로젝트 루트를 찾아 리스를 읽는다 (git 최상위 우선, 없으면 상위로 탐색)
root=""
if top="$(cd "$cwd" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"; then
  root="$top"
else
  d="$cwd"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    [ -f "$d/.handoff-lease" ] && { root="$d"; break; }
    d="$(dirname "$d")"
  done
fi
[ -n "$root" ] || pass

lease="$root/.handoff-lease"
[ -f "$lease" ] || pass

owner="$(python3 -c "
import json,sys
try: print(json.load(open(sys.argv[1])).get('owner',''))
except Exception: print('')
" "$lease" 2>/dev/null)"

[ "$owner" = "remote" ] || pass

# 넘어간 그 세션만 막는다.
# 같은 프로젝트 경로에서 다른 세션으로 별개 작업을 하는 것은 정상이므로 통과시킨다.
# 리스에 uuid 가 없거나 훅 입력에 session_id 가 없으면 판정할 수 없으니 통과시킨다.
lease_uuid="$(python3 -c "
import json,sys
try: print(json.load(open(sys.argv[1])).get('session_uuid','') or '')
except Exception: print('')
" "$lease" 2>/dev/null)"

[ -n "$lease_uuid" ] || pass
[ -n "${session_id:-}" ] && [ "$session_id" != "-" ] || pass
[ "$session_id" = "$lease_uuid" ] || pass

# 회수 경로는 막지 않는다
case "${prompt:-}" in
  *handback*|*/handback*|*회수*|*되가져*) pass ;;
esac

host="$(python3 -c "
import json,sys
try: print(json.load(open(sys.argv[1])).get('remote_host','') or 'mini')
except Exception: print('mini')
" "$lease" 2>/dev/null)"
at="$(python3 -c "
import json,sys
try: print(json.load(open(sys.argv[1])).get('handoff_at','') or '?')
except Exception: print('?')
" "$lease" 2>/dev/null)"
ws="$(python3 -c "
import json,sys
try: print(json.load(open(sys.argv[1])).get('workspace_id','') or '?')
except Exception: print('?')
" "$lease" 2>/dev/null)"

cat >&2 <<EOF
이 프로젝트는 현재 $host 로 이관되어 있습니다 (handoff: $at, workspace: $ws).

여기서 계속 작업하면 대화가 갈라져서 회수할 수 없게 됩니다.
같은 세션을 이어가려면 먼저 회수하세요:

    handback

원격 진행 상황을 보려면:

    herdr --remote $host

EOF
exit 2
