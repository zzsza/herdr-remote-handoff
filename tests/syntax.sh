#!/usr/bin/env bash
# 정적 검사 (V1): 모든 셸 스크립트가 문법을 통과하고, 실행돼야 하는 것은 실행 권한을 가진다.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAIL=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s: %s\n' "$1" "$2"; }

printf '문법 검사\n'
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if bash -n "$f" 2>/dev/null; then ok "$f"; else bad "$f" "구문 오류"; fi
done < <(find bin lib hooks tests install.sh -type f \( -name '*.sh' -o -name 'handoff' \) 2>/dev/null | LC_ALL=C sort)

printf '\n실행 권한\n'
for f in bin/handoff install.sh hooks/handoff-lease-guard.sh tests/run.sh tests/syntax.sh; do
  if [ -x "$f" ]; then ok "$f"; else bad "$f" "실행 권한 없음"; fi
done

printf '\n라이브러리 로드 (심링크 호출 포함)\n'
if bash -c '. lib/common.sh && . lib/config.sh && . lib/filelist.sh && . lib/lease.sh && ho_config_load "$PWD" && [ -n "$(ho_config_get remote)" ]' 2>/dev/null; then
  ok "직접 소싱"
else
  bad "직접 소싱" "라이브러리 로드 실패"
fi
if [ -L "$HOME/.local/bin/handoff" ]; then
  if "$HOME/.local/bin/handoff" --help >/dev/null 2>&1; then
    ok "심링크 경유 호출"
  else
    bad "심링크 경유 호출" "설치된 심링크로 실행 실패"
  fi
else
  ok "심링크 미설치 (건너뜀)"
fi

printf '\n----------------------------------------\n'
if [ "$FAIL" -eq 0 ]; then printf '정적 검사 통과\n'; else printf '정적 검사 실패 %s건\n' "$FAIL"; fi
[ "$FAIL" -eq 0 ]
