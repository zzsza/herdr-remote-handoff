#!/usr/bin/env bash
# 원격 없이 검증 가능한 순수 로직의 회귀 테스트 (T12).
# 의존성 없음. bash + python3 만 쓴다.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/config.sh"
. "$ROOT/lib/filelist.sh"
. "$ROOT/lib/lease.sh"
. "$ROOT/lib/remote.sh"
. "$ROOT/lib/transfer.sh"
. "$ROOT/lib/cmd_bootstrap.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     기대: %s\n     실제: %s\n' "$1" "$2" "$3"; }
eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
group(){ printf '\n%s\n' "$1"; }

TMPROOT="$(mktemp -d -t handoff-tests)"
trap 'rm -rf "$TMPROOT"' EXIT

# 시간에 의존하는 검사를 위해 mtime 을 뒤로 미는 헬퍼
age_file() { touch -t "$(date -v-"$2"d +%Y%m%d%H%M 2>/dev/null || date -d "-$2 days" +%Y%m%d%H%M)" "$1"; }

new_project() {
  local d="$TMPROOT/$1"; mkdir -p "$d"; (cd "$d" && git init -q 2>/dev/null)
  printf 'node_modules/\n.env\n.env.local\nlocal.sqlite\nsettings.local.json\nbig.bin\n' > "$d/.gitignore"
  printf 'console.log(1)\n' > "$d/app.js"
  printf 'SECRET=canary-env\n' > "$d/.env"
  printf 'TOKEN=canary-env-local\n' > "$d/.env.local"
  printf '{"a":1}\n' > "$d/settings.local.json"
  printf 'sqlitedata\n' > "$d/local.sqlite"
  printf 'junk\n' > "$d/big.bin"
  mkdir -p "$d/node_modules/pkg" && printf 'dep\n' > "$d/node_modules/pkg/index.js"
  printf '%s' "$d"
}

# ---------------------------------------------------------------- 설정 3계층
group "설정 오버라이드 8항목 x 3계층 (R13/AC13)"

P="$(new_project cfg)"
export HO_GLOBAL_CONFIG="$TMPROOT/global.toml"
cat > "$HO_GLOBAL_CONFIG" <<'EOF'
remote = "globalhost"
include = "g1,g2"
exclude = "gx"
secrets = "gs"
tree_retention_days = 91
backup_retention_days = 92
size_confirm_bytes = 93
free_space_warn_gib = 94
EOF
cat > "$P/.handoffrc" <<'EOF'
remote = "projhost"
include = "p1"
exclude = "px"
secrets = "ps"
tree_retention_days = 51
backup_retention_days = 52
size_confirm_bytes = 53
free_space_warn_gib = 54
EOF

# 전역만
ho_config_reset; rm -f "$P/.handoffrc.bak"; mv "$P/.handoffrc" "$P/.handoffrc.bak"
ho_config_load "$P"
for pair in "remote globalhost" "include g1,g2" "exclude gx" "secrets gs" \
            "tree_retention_days 91" "backup_retention_days 92" "size_confirm_bytes 93" "free_space_warn_gib 94"; do
  set -- $pair
  eq "전역 적용: $1" "$2" "$(ho_config_get "$1")"
done
eq "출처=global" "global" "$(ho_config_source remote)"

# 프로젝트가 전역을 이긴다
mv "$P/.handoffrc.bak" "$P/.handoffrc"
ho_config_reset; ho_config_load "$P"
for pair in "remote projhost" "include p1" "exclude px" "secrets ps" \
            "tree_retention_days 51" "backup_retention_days 52" "size_confirm_bytes 53" "free_space_warn_gib 54"; do
  set -- $pair
  eq "프로젝트가 전역을 이김: $1" "$2" "$(ho_config_get "$1")"
done
eq "출처=project" "project" "$(ho_config_source remote)"

# 플래그가 모두를 이긴다
ho_config_reset
for pair in "remote flaghost" "include f1" "exclude fx" "secrets fs" \
            "tree_retention_days 11" "backup_retention_days 12" "size_confirm_bytes 13" "free_space_warn_gib 14"; do
  set -- $pair
  ho_config_set_flag "$1" "$2"
done
ho_config_load "$P"
for pair in "remote flaghost" "include f1" "exclude fx" "secrets fs" \
            "tree_retention_days 11" "backup_retention_days 12" "size_confirm_bytes 13" "free_space_warn_gib 14"; do
  set -- $pair
  eq "플래그가 최우선: $1" "$2" "$(ho_config_get "$1")"
done
eq "출처=flag" "flag" "$(ho_config_source remote)"

# 아무것도 없으면 기본값
ho_config_reset; rm -f "$P/.handoffrc" "$HO_GLOBAL_CONFIG"
ho_config_load "$P"
eq "기본 remote" "mini" "$(ho_config_get remote)"
eq "기본 secrets" ".env*" "$(ho_config_get secrets)"
eq "기본 트리 보존" "14" "$(ho_config_get tree_retention_days)"
eq "기본 백업 보존" "7" "$(ho_config_get backup_retention_days)"
eq "기본 용량 임계치" "524288000" "$(ho_config_get size_confirm_bytes)"
eq "기본 여유공간 임계치" "20" "$(ho_config_get free_space_warn_gib)"
eq "기본 핸드오프 트리는 로컬 홈" "$HOME" "$(ho_config_get remote_tree)"
eq "기본 트리 대상은 비어 있음(원격에서 파생)" "" "$(ho_config_get remote_tree_target)"
eq "기본 추가 차단 경로 없음" "" "$(ho_config_get deny_extra)"
eq "출처=default" "default" "$(ho_config_source remote)"

# ---------------------------------------------------------------- 전송 목록
group "전송 목록 산출 (R6/AC1/AC12)"

P="$(new_project list)"
ho_config_reset; ho_config_load "$P"
LIST="$(ho_transfer_list "$P")"

grep -qx 'app.js' <<< "$LIST" && ok "추적 파일 포함" || bad "추적 파일 포함" "app.js" "없음"
grep -qx '.env' <<< "$LIST" && ok ".env 는 gitignore에도 포함(화이트리스트)" || bad ".env 포함" ".env" "없음"
grep -qx '.env.local' <<< "$LIST" && ok ".env.local 포함" || bad ".env.local 포함" "있음" "없음"
grep -qx 'local.sqlite' <<< "$LIST" && ok "*.sqlite 포함" || bad "sqlite 포함" "있음" "없음"
grep -qx 'settings.local.json' <<< "$LIST" && ok "*.local.json 포함" || bad "local.json 포함" "있음" "없음"
grep -q 'node_modules' <<< "$LIST" && bad "node_modules 제외" "없음" "있음" || ok "node_modules 제외"
grep -qx 'big.bin' <<< "$LIST" && bad "미결정 무시파일 제외" "없음" "있음" || ok "미결정 무시파일은 전송 안 함"
grep -q '^\.git/' <<< "$LIST" && ok ".git 포함" || bad ".git 포함" "있음" "없음"

# 결정론
A="$(ho_transfer_list "$P")"; B="$(ho_transfer_list "$P")"
eq "같은 입력 같은 출력" "$A" "$B"

# .handoffignore 가 화이트리스트를 이긴다
printf '.env.local\n' > "$P/.handoffignore"
L2="$(ho_transfer_list "$P")"
grep -qx '.env.local' <<< "$L2" && bad ".handoffignore 우선" "제외됨" "포함됨" || ok ".handoffignore 가 포함목록을 이김"
rm -f "$P/.handoffignore"

# 후보 스캔
CAND="$(ho_candidate_list "$P")"
grep -q 'big.bin' <<< "$CAND" && ok "후보에 미결정 무시파일 등장" || bad "후보 스캔" "big.bin" "없음"
grep -q $'\t\.env$' <<< "$CAND" && bad "포함 확정분은 후보 아님" "없음" "있음" || ok "이미 포함된 것은 후보에서 빠짐"

# 최초 handoff 판정과 기록
ho_is_first_handoff "$P" && ok "목록 파일 없으면 최초" || bad "최초 판정" "true" "false"
ho_record_include "$P" "big.bin"; ho_record_ignore "$P" "other.bin"
ho_is_first_handoff "$P" && bad "기록 후 최초 아님" "false" "true" || ok "목록 파일 생기면 2회차"
grep -qx 'big.bin' "$P/.handoffinclude" && ok "선택분이 .handoffinclude 에 기록" || bad "선택 기록" "big.bin" "없음"
grep -qx 'other.bin' "$P/.handoffignore" && ok "거절분이 .handoffignore 에 기록" || bad "거절 기록" "other.bin" "없음"
ho_record_include "$P" "big.bin"
eq "중복 기록 안 함" "1" "$(grep -cx 'big.bin' "$P/.handoffinclude")"
ho_config_reset; ho_config_load "$P"
grep -qx 'big.bin' <<< "$(ho_transfer_list "$P")" && ok "선택분이 다음 회차에 전송됨" || bad "선택 반영" "big.bin 포함" "없음"

# ---------------------------------------------------------------- 시크릿 분류
group "시크릿 분류 (R7/AC7) - .env* 만 시크릿"

P="$(new_project sec)"; ho_config_reset; ho_config_load "$P"
ho_is_secret ".env"                        && ok ".env 는 시크릿"        || bad ".env" "시크릿" "아님"
ho_is_secret ".env.local"                  && ok ".env.local 은 시크릿"  || bad ".env.local" "시크릿" "아님"
ho_is_secret "settings.local.json"         && bad "settings.local.json" "시크릿 아님" "시크릿" || ok "settings.local.json 은 시크릿 아님"
ho_is_secret ".claude/settings.local.json" && bad ".claude/settings.local.json" "시크릿 아님" "시크릿" || ok ".claude/settings.local.json 은 시크릿 아님(패턴 충돌 해소)"
ho_is_secret "local.sqlite"                && bad "sqlite" "시크릿 아님" "시크릿" || ok "*.sqlite 는 시크릿 아님"
ho_is_secret "app.js"                      && bad "app.js" "시크릿 아님" "시크릿" || ok "평범한 파일은 시크릿 아님"
# 프로젝트가 시크릿을 넓히면 반영된다
ho_config_reset; ho_config_set_flag secrets ".env*,*.local.json"; ho_config_load "$P"
ho_is_secret "settings.local.json" && ok "설정으로 시크릿 확장 가능" || bad "시크릿 확장" "시크릿" "아님"

# ---------------------------------------------------------------- 리스
group "리스 판정과 스테일 (R8/AC8/AC10)"

P="$(new_project lease)"; ho_config_reset; ho_config_load "$P"
eq "리스 없으면 local" "local" "$(ho_lease_owner "$P")"
ho_lease_claim_remote "$P" "uuid-1" "mini" "w9"
eq "claim 후 remote" "remote" "$(ho_lease_owner "$P")"
eq "세션 uuid 기록" "uuid-1" "$(ho_lease_get "$P" session_uuid)"
eq "workspace 기록" "w9" "$(ho_lease_get "$P" workspace_id)"
[ -n "$(ho_lease_get "$P" handoff_at)" ] && ok "handoff 시각 기록" || bad "handoff 시각" "있음" "없음"

ho_lease_is_stale "$P" 1 && ok "owner=remote + pane 없음 -> stale" || bad "stale 판정" "true" "false"
ho_lease_is_stale "$P" 0 && bad "pane 있으면 stale 아님" "false" "true" || ok "pane 있으면 stale 아님"
ho_lease_is_stale "$P" 2 && bad "판정불가는 stale 아님" "false" "true" || ok "판정 불가는 stale 아님(fail-closed 대상)"

ho_lease_release_local "$P"
eq "반환 후 local" "local" "$(ho_lease_owner "$P")"
[ -f "$P/.handoff-lease" ] && ok "반환 후에도 리스 파일 유지" || bad "리스 파일 유지" "있음" "없음"
[ -n "$(ho_lease_get "$P" handback_at)" ] && ok "handback 시각 기록" || bad "handback 시각" "있음" "없음"
[ -n "$(ho_lease_get "$P" handoff_at)" ] && ok "이전 handoff 시각 보존" || bad "handoff 시각 보존" "있음" "없음"
ho_lease_is_stale "$P" 1 && bad "local 소유는 stale 아님" "false" "true" || ok "local 소유는 stale 아님"

# ---------------------------------------------------------------- 세션 갈래
group "보존 기간 계산 (R10/AC10/AC11)"

D="$TMPROOT/aged"; mkdir -p "$D"; touch "$D/f"
eq "방금 만든 것은 0일" "0" "$(ho_age_days "$D/f")"
age_file "$D/f" 20
AGE="$(ho_age_days "$D/f")"
[ "$AGE" -ge 19 ] && ok "20일 전 파일이 19일 이상으로 계산 ($AGE)" || bad "경과일" ">=19" "$AGE"
[ "$AGE" -ge 14 ] && ok "트리 14일 경계 초과 -> 정리 대상" || bad "14일 경계" "초과" "미달"
age_file "$D/f" 3
AGE="$(ho_age_days "$D/f")"
[ "$AGE" -lt 7 ] && ok "3일 전 백업은 7일 경계 미달 -> 대상 아님 ($AGE)" || bad "7일 경계" "미달" "$AGE"

# ---------------------------------------------------------------- 훅 판정
group "훅 차단 판정 (R15/AC15/SC4)"

HOOK="$ROOT/hooks/handoff-lease-guard.sh"
H="$TMPROOT/hookproj"; mkdir -p "$H"
UUID_A="11111111-1111-4111-8111-111111111111"
UUID_B="22222222-2222-4222-8222-222222222222"
# 훅은 세션 단위로 판정한다. 기본은 넘어간 세션(UUID_A) 으로 보낸다.
run_hook() { printf '{"cwd":"%s","session_id":"%s","prompt":"%s"}' "$H" "${2:-$UUID_A}" "$1" | "$HOOK" >/dev/null 2>&1; printf '%s' "$?"; }
remote_lease() { printf '{"owner":"remote","remote_host":"mini","handoff_at":"2026-08-18T01:00:00Z","workspace_id":"w9","session_uuid":"%s"}' "$UUID_A" > "$H/.handoff-lease"; }

eq "리스 없으면 통과" "0" "$(run_hook '뭔가 해줘')"
printf '{"owner":"local","session_uuid":"%s"}' "$UUID_A" > "$H/.handoff-lease"
eq "owner=local 통과" "0" "$(run_hook '뭔가 해줘')"
remote_lease
eq "owner=remote + 넘어간 세션은 차단" "2" "$(run_hook '뭔가 해줘')"
eq "같은 경로라도 다른 세션은 통과" "0" "$(run_hook '뭔가 해줘' "$UUID_B")"
eq "session_id 를 알 수 없으면 통과" "0" "$(printf '{"cwd":"%s","prompt":"x"}' "$H" | "$HOOK" >/dev/null 2>&1; printf '%s' "$?")"
printf '{"owner":"remote","remote_host":"mini"}' > "$H/.handoff-lease"
eq "리스에 uuid 가 없으면 통과" "0" "$(run_hook '뭔가 해줘')"
remote_lease
eq "handback 은 통과" "0" "$(run_hook 'handback 해줘')"
eq "회수 요청도 통과" "0" "$(run_hook '이제 회수해줘')"
printf 'not json' > "$H/.handoff-lease"
eq "깨진 리스는 통과(fail-open)" "0" "$(run_hook '뭔가 해줘')"
remote_lease
MSG="$(printf '{"cwd":"%s","session_id":"%s","prompt":"x"}' "$H" "$UUID_A" | "$HOOK" 2>&1 >/dev/null)"
grep -q 'handback' <<< "$MSG" && ok "차단 메시지에 회수 방법 포함" || bad "차단 안내" "handback 언급" "$MSG"

# ---------------------------------------------------------------- 제외 규칙
group "제외 규칙 경계"

P="$(new_project excl)"; ho_config_reset; ho_config_load "$P"
ho_is_excluded "$P" "node_modules/pkg/index.js" && ok "경로 성분으로 제외 판정" || bad "성분 제외" "제외" "미제외"
ho_is_excluded "$P" "src/dist/out.js"           && ok "중간 성분 dist 제외"     || bad "중간 성분" "제외" "미제외"
ho_is_excluded "$P" "src/app.js"                && bad "일반 파일" "미제외" "제외" || ok "일반 파일은 제외 안 함"
ho_is_excluded "$P" ".DS_Store"                 && ok ".DS_Store 제외"        || bad ".DS_Store" "제외" "미제외"
# 제어 상태 파일은 설정과 무관하게 항상 제외된다 (실기계에서 리스 유실로 발견)
ho_is_excluded "$P" ".handoff-lease"            && bad ".handoff-lease" "동기화 대상" "제외됨" || ok ".handoff-lease 는 동기화하되 protect 로 보호"
ho_is_excluded "$P" ".handoff-backup/20260818T000000Z/x" && ok ".handoff-backup 항상 제외" || bad ".handoff-backup" "제외" "미제외"
ho_config_reset; ho_config_set_flag exclude "nothing"; ho_config_load "$P"
ho_is_excluded "$P" ".handoff-lock"             && ok "exclude 설정을 비워도 잠금은 제외" || bad "잠금 강제 제외" "제외" "미제외"
ho_config_reset; ho_config_load "$P"

# 비-git 디렉터리는 고정 제외만 적용 (D-36)
NG="$TMPROOT/plain"; mkdir -p "$NG/node_modules/x" "$NG/sub"
printf 'a\n' > "$NG/a.txt"; printf 'b\n' > "$NG/sub/b.txt"; printf 'c\n' > "$NG/node_modules/x/c.js"
printf 'SECRET=1\n' > "$NG/.env"
ho_config_reset; ho_config_load "$NG"
NL="$(ho_transfer_list "$NG")"
grep -qx 'a.txt' <<< "$NL" && ok "비-git: 일반 파일 포함" || bad "비-git 포함" "a.txt" "없음"
grep -qx '.env' <<< "$NL" && ok "비-git: .env 포함" || bad "비-git .env" "있음" "없음"
grep -q 'node_modules' <<< "$NL" && bad "비-git: node_modules 제외" "없음" "있음" || ok "비-git: 고정 제외 적용"

# ---------------------------------------------------------------- 프롬프트 시크릿 차단
group "프롬프트 시크릿 누출 차단 (R16/AC16)"

P="$(new_project leak)"; ho_config_reset; ho_config_load "$P"
ho_prompt_leaks_secret "$P" "평범한 지시문입니다" && bad "깨끗한 프롬프트" "통과" "차단" || ok "깨끗한 프롬프트는 통과"
ho_prompt_leaks_secret "$P" "요약: TOKEN 은 canary-env-local 입니다" && ok "시크릿 값이 섞이면 차단" || bad "누출 감지" "차단" "통과"
ho_prompt_leaks_secret "$P" "[작업 목표] 검증 [주의사항] .env 파일은 건드리지 말 것" && bad "파일명 언급" "통과" "차단" || ok "파일 이름만 언급하는 것은 차단하지 않음"
ho_prompt_leaks_secret "$P" "" && bad "빈 프롬프트" "통과" "차단" || ok "빈 프롬프트는 통과"
# 시크릿이 아닌 포함 파일의 내용은 차단 대상이 아니다
ho_prompt_leaks_secret "$P" "설정은 sqlitedata 형식입니다" && bad "비시크릿 내용" "통과" "차단" || ok "비시크릿 파일 내용은 차단하지 않음"

# ---------------------------------------------------------------- 강제 우회 부재
group "기각된 우회 경로가 없는지 (F2/F3/F4)"

grep -q 'HO_FORCE' "$ROOT/lib/cmd_handback.sh" && bad "handback 의 HO_FORCE" "없음" "있음" || ok "handback 에 --force 우회 경로 없음"
grep -q 'owner 를 직접' "$ROOT/hooks/handoff-lease-guard.sh" && bad "훅의 우회 안내" "없음" "있음" || ok "훅이 우회 방법을 안내하지 않음"
grep -q 'rm -rf "\$claude_skill"' "$ROOT/install.sh" && bad "install 의 rm -rf" "없음" "있음" || ok "install 이 실제 디렉터리를 지우지 않음"
grep -q 'ho_bootstrap_check_cli' "$ROOT/lib/cmd_bootstrap.sh" && ok "사전조건에 원격 CLI 검사 포함" || bad "CLI 사전조건" "있음" "없음"
grep -q 'ho_backup_remote_session' "$ROOT/lib/cmd_handoff.sh" && ok "강제 재-handoff 전 원격 세션 백업" || bad "원격 세션 백업" "있음" "없음"

group "요약 계약 (D-44/AC16)"

SUMMARY="마무리해줘 [작업 목표] a [지금까지 한 것] b [다음 할 일] c [주의사항] d"
ho_codex_summary_ok "$SUMMARY" && ok "네 항목 5줄 이내는 계약 만족" || bad "계약" "만족" "불만족"
ho_codex_summary_ok "지시문만 있음" && bad "항목 없음" "불만족" "만족" || ok "네 항목이 없으면 계약 불만족"
LONGSUM="$(printf '지시 [작업 목표] 1\n2\n3\n4\n5\n6 [지금까지 한 것] b [다음 할 일] c [주의사항] d')"
ho_codex_summary_ok "$LONGSUM" && bad "5줄 초과" "불만족" "만족" || ok "항목이 5줄을 넘으면 계약 불만족"
eq "계약 위반 시 지시문만 남김" "마무리해줘" "$(ho_strip_summary "$SUMMARY")"

group "제외된 시크릿 파일도 검사 대상 (AC16)"

P="$(new_project leak2)"
printf '{"password": "p4ssw0rd7"}\n' > "$P/creds.json"
printf 'creds.json\n' >> "$P/.gitignore"
ho_config_reset; ho_config_set_flag secrets ".env*,creds.json"; ho_config_load "$P"
ho_prompt_leaks_secret "$P" "비번 p4ssw0rd7 로 접속" && ok "전송 목록에 없는 시크릿의 JSON 값도 감지" || bad "JSON 누출" "차단" "통과"
ho_config_reset; ho_config_load "$P"

group "하드닝 회귀 (위험 판정 지적)"

grep -q 'ln -sfn "$ROOT/bin/handoff"' "$ROOT/install.sh" && bad "install 의 강제 심링크" "없음" "있음" || ok "install 이 기존 bin 항목을 덮지 않음"
grep -q 'readlink' "$ROOT/lib/cmd_bootstrap.sh" && ok "부트스트랩이 심링크 대상까지 검증" || bad "심링크 대상 검증" "있음" "없음"
grep -q '리스를 반환하지 않습니다' "$ROOT/lib/cmd_handback.sh" && ok "세션·시크릿 실패 시 리스 미반환(fail-closed)" || bad "fail-closed" "있음" "없음"
grep -q '멈춘 것을 확인하지 못했습니다' "$ROOT/lib/cmd_handback.sh" && ok "정지 확인 실패 시 회수 중단" || bad "정지 확인" "있음" "없음"
grep -q '원격 여유 공간을 확인하지 못했습니다' "$ROOT/lib/cmd_handoff.sh" && ok "여유공간 미확인 시 전송 중단" || bad "여유공간 가드" "있음" "없음"
grep -q 'agent_name' "$ROOT/lib/cmd_handback.sh" && ok "Codex 는 에이전트 이름으로 상태 판정" || bad "Codex 식별" "있음" "없음"
grep -q 'os.walk' "$ROOT/lib/cmd_status_clean.sh" && ok "clean 이 트리 내 최신 파일로 나이 계산" || bad "clean 나이" "있음" "없음"
grep -q 'ho_shq' "$ROOT/lib/remote.sh" && ok "원격 명령이 안전 인용 사용" || bad "원격 인용" "있음" "없음"

group "원격 인용 안전성"

ho_is_safe_pattern ".env*" && ok "정상 패턴 허용" || bad "정상 패턴" "허용" "거부"
ho_is_safe_pattern "x; rm -rf /" && bad "세미콜론 패턴" "거부" "허용" || ok "세미콜론 패턴 거부"
ho_is_safe_pattern 'a$(id)' && bad "명령 치환" "거부" "허용" || ok "명령 치환 거부"
ho_is_safe_pattern 'a`id`' && bad "백틱" "거부" "허용" || ok "백틱 거부"
QUOTED="$(ho_shq "a'b")"
[ "$QUOTED" != "'a'b'" ] && ok "작은따옴표를 이스케이프해 인용 ($QUOTED)" || bad "인용" "이스케이프됨" "$QUOTED"

group "추가 하드닝 회귀 (위험 판정 2차)"

grep -q '핸드오프 트리(' "$ROOT/lib/cmd_handoff.sh" && ok "트리 밖 프로젝트는 전송 거부(경로 봉쇄)" || bad "경로 봉쇄" "있음" "없음"
grep -q '원격 세션이 아직 살아 있습니다' "$ROOT/lib/cmd_handoff.sh" && ok "--force 도 살아있는 원격 세션은 덮지 못함" || bad "force 하드스톱" "있음" "없음"
grep -q 'mkdir -p $(ho_shq' "$ROOT/lib/cmd_handoff.sh" && ok "원격 mkdir 안전 인용" || bad "mkdir 인용" "있음" "없음"
grep -q 'shasum' "$ROOT/lib/cmd_handoff.sh" && ok "에이전트 이름에 경로 해시 포함(동명 충돌 방지)" || bad "이름 충돌" "있음" "없음"
grep -q '리스를 기록하지 못했습니다' "$ROOT/lib/cmd_handoff.sh" && ok "리스 쓰기 실패 시 원격 기동 안 함" || bad "리스 쓰기 확인" "있음" "없음"
grep -q '원격에 전송된 시크릿은 삭제했습니다' "$ROOT/lib/cmd_handoff.sh" && ok "세션 이관 실패 시 원격 시크릿 정리" || bad "실패 경로 시크릿" "있음" "없음"
grep -q -- '-path $(ho_shq "\*/$pat")' "$ROOT/lib/transfer.sh" && ok "슬래시 든 시크릿 패턴은 -path 로 조회" || bad "슬래시 패턴" "있음" "없음"
grep -qF 'del_kind+=' "$ROOT/lib/cmd_status_clean.sh" && ok "clean 이 병렬 배열로 경로를 쪼개지 않음" || bad "clean 직렬화" "병렬 배열" "문자열"
grep -qF 'ho_record_include "$root" "$a"' "$ROOT/bin/handoff" && ok "handoff include 로 선택을 기록" || bad "선택 기록" "있음" "없음"
grep -qF 'ho_record_ignore "$root" "$a"' "$ROOT/bin/handoff" && ok "handoff exclude 로 거절을 기록" || bad "거절 기록" "있음" "없음"
grep -qF 'ho_candidate_list "$root" ;;' "$ROOT/bin/handoff" && ok "handoff candidates 로 스킬이 후보를 받음(D-09)" || bad "후보 통로" "있음" "없음"
grep -q '_ho_git_visible "$root"; } ' "$ROOT/lib/filelist.sh" && ok "누출 검사가 추적 중인 시크릿도 대상" || bad "추적 파일 검사" "있음" "없음"

group "누출 검사 경계 (위험 판정 2차)"

P="$(new_project leak3)"
printf 'PIN=1234\n' > "$P/.env"
printf 'PASSPHRASE=correct horse battery\n' >> "$P/.env"
ho_config_reset; ho_config_load "$P"
ho_prompt_leaks_secret "$P" "핀은 1234 입니다" && ok "짧은 값(4자)도 감지" || bad "짧은 값" "차단" "통과"
ho_prompt_leaks_secret "$P" "암구호는 correct horse battery 다" && ok "공백 포함 비밀번호도 감지" || bad "공백 값" "차단" "통과"
ho_prompt_leaks_secret "$P" "이 작업은 파일을 정리하고 테스트를 돌린 다음 결과를 확인하는 평범한 흐름입니다" && bad "긴 산문" "통과" "차단" || ok "긴 산문은 오탐하지 않음"

group "위험 판정 3차 하드닝"

grep -qF 'ho_codex_summary_ok "$instruction"' "$ROOT/lib/cmd_handoff.sh" && ok "Codex 요약 계약이 실제로 호출됨" || bad "요약 계약 배선" "있음" "없음"
grep -qF 'ho_strip_summary "$instruction"' "$ROOT/lib/cmd_handoff.sh" && ok "계약 위반 시 요약 제거 폴백 배선" || bad "폴백 배선" "있음" "없음"
grep -qF 'agent start $(ho_shq "$name")' "$ROOT/lib/remote.sh" && ok "agent start 의 name 안전 인용" || bad "name 인용" "있음" "없음"
grep -qF 'pwd -P' "$ROOT/lib/cmd_handoff.sh" && ok "원격 실경로가 전용 트리 안인지 확인" || bad "실경로 봉쇄" "있음" "없음"
grep -qF 'O_NOFOLLOW' "$ROOT/lib/lease.sh" && ok "리스 임시파일 심링크 공격 차단" || bad "심링크 공격" "차단" "미차단"
grep -c '원격 여유 공간을 확인하지 못했습니다' "$ROOT/lib/cmd_handoff.sh" | grep -q '^2$' && ok "후보 선택 후 전송량·여유공간 재계산" || bad "재계산" "2회 검사" "1회"

group "리스 임시파일 심링크 실측"

LP="$TMPROOT/leasesym"; mkdir -p "$LP"
VICTIM="$TMPROOT/victim.txt"; printf 'keep-me\n' > "$VICTIM"
ln -s "$VICTIM" "$LP/.handoff-lease.tmp"
ho_config_reset; ho_config_load "$LP"
ho_lease_set "$LP" "owner=remote" 2>/dev/null
eq "심링크 대상이 보존됨" "keep-me" "$(cat "$VICTIM")"
eq "리스는 정상 기록됨" "remote" "$(ho_lease_owner "$LP")"

group "위험 판정 4차 하드닝"

DENY="$(ho_deny_rules /Users/someone)"
printf '%s' "$DENY" | grep -qF 'Write(/Users/someone/**)' && ok "deny 가 원격 홈에서 파생" || bad "원격 홈 deny" "있음" "없음"
printf '%s' "$DENY" | grep -qF 'Read(~/Library/LaunchAgents/**)' && ok "deny 에 launchd 항목 차단" || bad "launchd deny" "있음" "없음"
printf '%s' "$DENY" | grep -qF 'Bash(launchctl:*)' && ok "deny 에 launchctl 차단" || bad "launchctl deny" "있음" "없음"
ho_config_reset; ho_config_set_flag deny_extra "/opt/prod"; ho_config_load "$TMPROOT"
printf '%s' "$(ho_deny_rules /Users/someone)" | grep -qF 'Write(/opt/prod/**)' && ok "deny_extra 가 규칙에 반영" || bad "deny_extra" "있음" "없음"
ho_config_reset; ho_config_load "$TMPROOT"
grep -qF 'ho_deny_rules "$remote_home"' "$ROOT/lib/cmd_bootstrap.sh" && ok "생성과 검증이 같은 목록을 쓴다" || bad "단일 출처" "있음" "없음"
grep -qF 'ho_verify_deny_rules "$host" "$remote_home"' "$ROOT/lib/cmd_bootstrap.sh" && ok "설정 내용까지 검증(존재만 보지 않음)" || bad "설정 내용 검증" "있음" "없음"
grep -qF -- '-type f -o -type l' "$ROOT/lib/transfer.sh" && ok "시크릿 삭제가 심링크도 대상" || bad "심링크 시크릿" "있음" "없음"
grep -qF -- '--protect-args' "$ROOT/lib/transfer.sh" && ok "rsync 경로 보호(--protect-args)" || bad "rsync 보호" "있음" "없음"
grep -qF 'ho_config_validate' "$ROOT/lib/config.sh" && ok "설정 값 타입·메타문자 검증" || bad "설정 검증" "있음" "없음"
grep -qF '.git -prune -print' "$ROOT/lib/cmd_status_clean.sh" && ok "clean 이 .git 기준으로 프로젝트 루트 탐지" || bad "clean 탐지" "있음" "없음"

group "설정 인젝션 차단"

CT="$TMPROOT/cfginject"; mkdir -p "$CT"
printf 'free_space_warn_gib = 20; touch %s/PWNED\n' "$TMPROOT" > "$CT/.handoffrc"
rm -f "$TMPROOT/PWNED"
ho_config_reset; ho_config_load "$CT" 2>/dev/null
[ -f "$TMPROOT/PWNED" ] && bad "산술 인젝션" "차단" "실행됨" || ok "산술 인젝션 차단"
eq "잘못된 숫자는 기본값 복귀" "20" "$(ho_config_get free_space_warn_gib)"
printf 'secrets = ".env*; rm -rf /"\n' > "$CT/.handoffrc"
ho_config_reset; ho_config_load "$CT" 2>/dev/null
eq "메타문자 패턴은 기본값 복귀" ".env*" "$(ho_config_get secrets)"
printf 'tree_retention_days = 30\n' > "$CT/.handoffrc"
ho_config_reset; ho_config_load "$CT" 2>/dev/null
eq "정상 숫자는 그대로 적용" "30" "$(ho_config_get tree_retention_days)"
ho_config_reset

group "위험 판정 5차 하드닝과 편차 해소"

grep -qF -- '--dangerously-bypass-approvals-and-sandbox' "$ROOT/lib/remote.sh" && ok "Codex 도 승인 프롬프트 없이 자율 실행(편차 해소)" || bad "Codex 무확인" "있음" "없음"
grep -qF 'ho_remote_session_advanced' "$ROOT/lib/cmd_status_clean.sh" && ok "정상 완료와 stale 을 구분해 표시(편차 해소)" || bad "완료/stale 구분" "있음" "없음"
grep -qF '부분 전송된 시크릿은 삭제했습니다' "$ROOT/lib/cmd_handoff.sh" && ok "전송 실패 시 부분 전송 시크릿 정리" || bad "부분전송 시크릿" "있음" "없음"
grep -qF '경로 구성요소가 바뀌었을 수 있어 회수를 진행하지 않습니다' "$ROOT/lib/cmd_handback.sh" && ok "handback 도 실경로 봉쇄 검사 수행" || bad "handback 봉쇄" "있음" "없음"
grep -qF '원격 핸드오프 트리가 기대한 심링크가 아닙니다. 정리를 진행하지 않습니다' "$ROOT/lib/cmd_status_clean.sh" && ok "clean 이 트리 심링크 확인 후 진행" || bad "clean 봉쇄" "있음" "없음"
grep -qF 'O_NOFOLLOW' "$ROOT/install.sh" && ok "install 임시파일 심링크 차단" || bad "install 임시파일" "있음" "없음"
grep -qF 'rm -f $(ho_shq "$tree/.handoff/claude-settings.json")' "$ROOT/lib/cmd_bootstrap.sh" && ok "설정 파일을 심링크 위에 쓰지 않음" || bad "설정 심링크" "있음" "없음"

group "위험 판정 6차 하드닝"

grep -qF '핸드오프 트리 루트 자체는 넘길 수 없습니다' "$ROOT/lib/cmd_handoff.sh" && ok "트리 루트 자체는 전송 거부(홈 전체 전송 차단)" || bad "루트 거부" "있음" "없음"
grep -qF '백업·세션 포함' "$ROOT/lib/cmd_handoff.sh" && ok "여유공간에 백업·세션 여유 반영" || bad "여유공간 여유분" "있음" "없음"
grep -qF 'workspace 식별자를 리스에 기록하지 못했습니다' "$ROOT/lib/cmd_handoff.sh" && ok "두 번째 리스 쓰기도 확인" || bad "리스 2차 쓰기" "있음" "없음"
grep -qF 'ho_lock_acquire' "$ROOT/lib/cmd_handoff.sh" && grep -qF '.handoff-lock' "$ROOT/lib/common.sh" && ok "프로젝트 잠금으로 동시 handoff 차단" || bad "잠금" "있음" "없음"
grep -qF '.handoff-lock' "$ROOT/lib/filelist.sh" && ok "잠금 디렉터리는 전송 대상 아님" || bad "잠금 제외" "있음" "없음"
grep -qF 'HO_PROTECTED_CONTROL' "$ROOT/lib/filelist.sh" && ok "제어 파일 보호 목록 정의" || bad "보호 목록" "있음" "없음"
grep -qF -- '--filter=protect' "$ROOT/lib/transfer.sh" && ok "rsync protect 필터로 제어 파일 보호" || bad "protect 필터" "있음" "없음"
eq "최초 handoff 확인은 한 줄" "1" "$(grep -c '이대로 전송할까요' "$ROOT/lib/cmd_handoff.sh")"
grep -qF '후보를 자동으로 거절 목록에 넣지 않는다' "$ROOT/lib/cmd_handoff.sh" && ok "미결정 후보를 임의로 거절하지 않음(D-50)" || bad "자동 거절 금지" "있음" "없음"

P="$(new_project lockx)"; ho_config_reset; ho_config_load "$P"
ho_is_excluded "$P" ".handoff-lock" && ok ".handoff-lock 항상 제외" || bad "잠금 제외" "제외" "미제외"

group "실사용에서 드러난 결함 (tetris 사례)"

# 1. 프로젝트 모음 디렉터리 거부
CONT="$TMPROOT/container"; mkdir -p "$CONT/a" "$CONT/b"
(cd "$CONT/a" && git init -q); (cd "$CONT/b" && git init -q)
ho_project_root_is_sane "$CONT" && bad "프로젝트 모음" "거부" "통과" || ok "git 레포 2개 이상인 상위 폴더는 거부"
ho_project_root_is_sane "$CONT/a" && ok "git 레포 자체는 통과" || bad "git 레포" "통과" "거부"
PLAIN="$TMPROOT/plainproj"; mkdir -p "$PLAIN/sub"; printf 'x' > "$PLAIN/a.txt"
ho_project_root_is_sane "$PLAIN" && ok "평범한 비-git 폴더는 통과" || bad "평범한 폴더" "통과" "거부"
grep -qF '프로젝트 모음으로 보입니다' "$ROOT/lib/cmd_handoff.sh" && ok "handoff 가 모음 디렉터리를 거부하고 안내" || bad "모음 거부 배선" "있음" "없음"

# 2. 전송량 계산이 파일당 프로세스를 띄우지 않는다
grep -qF 'wc -c < "$root/$f"' "$ROOT/lib/filelist.sh" && bad "용량 계산" "일괄" "파일당 프로세스" || ok "전송량 계산이 일괄 처리(대형 트리에서 멈추지 않음)"

# 3. 상위에서 시작된 세션을 감지해 안내
grep -qF 'ho_session_cwd_elsewhere' "$ROOT/lib/cmd_handoff.sh" && ok "상위 디렉터리 세션을 감지해 원인 안내" || bad "세션 위치 진단" "있음" "없음"

group "위험 판정 8차 하드닝"

grep -qF 'raw="$(ho_ssh "$host" '"'"'herdr agent list'"'"' 2>/dev/null)" || return 2' "$ROOT/lib/remote.sh" && ok "에이전트 조회 실패는 판정 불가(rc=2)로 처리" || bad "조회 실패 처리" "rc=2" "rc=1"
grep -qF '[ "$rc" -eq 2 ] && return 2' "$ROOT/lib/remote.sh" && ok "파싱 실패도 stale 로 오판하지 않음" || bad "파싱 실패" "판정 불가" "없음"
grep -qF '*[!0-9a-fA-F-]*' "$ROOT/lib/lease.sh" && ok "리스의 session_uuid 형식 검증(원격 인젝션 차단)" || bad "uuid 검증" "있음" "없음"
grep -qF '_ho_clean_pane_state' "$ROOT/lib/cmd_status_clean.sh" && ok "트리·백업이 같은 pane 판정 헬퍼 사용" || bad "판정 통일" "있음" "없음"
grep -qF '소유 프로젝트의 리스가 원격' "$ROOT/lib/cmd_status_clean.sh" && ok "백업도 리스 보호 규칙 적용" || bad "백업 리스 보호" "있음" "없음"
grep -qF '소유 프로젝트의 pane 이 살아 있거나 판정 불가' "$ROOT/lib/cmd_status_clean.sh" && ok "백업도 pane 보호 규칙 적용" || bad "백업 pane 보호" "있음" "없음"

# uuid 형식 검증 실측
LU="$TMPROOT/uuidcheck"; mkdir -p "$LU"
ho_config_reset; ho_config_load "$LU"
ho_remote_session_advanced nonexistent-host "$LU" 'abc$(touch /tmp/HO_PWNED)' 100 2>/dev/null
[ -f /tmp/HO_PWNED ] && bad "uuid 인젝션" "차단" "실행됨" || ok "조작된 uuid 로 명령이 실행되지 않음"
rm -f /tmp/HO_PWNED

group "위험 판정 9차 하드닝"

grep -qF '"$real_tree"/?*' "$ROOT/lib/cmd_handback.sh" && ok "handback 봉쇄도 트리 루트 자체를 거부" || bad "handback 루트 거부" "있음" "없음"
grep -qF '원격 실경로가 트리 루트 자체입니다: $real_remote. 회수를 진행하지 않습니다' "$ROOT/lib/cmd_handback.sh" && ok "handback 이 루트 회수를 명시 거부" || bad "handback 루트 메시지" "있음" "없음"
grep -qF 'real_target="$(ho_ssh "$host" "cd $(ho_shq "$want")' "$ROOT/lib/cmd_bootstrap.sh" && ok "심링크 대상의 실경로까지 검증" || bad "대상 실경로" "있음" "없음"
grep -qF '[ "$real_target" = "$real_home" ] && return 1' "$ROOT/lib/cmd_bootstrap.sh" && ok "트리 대상이 원격 홈이면 거부" || bad "홈 대상 거부" "있음" "없음"
grep -qF '이 심링크입니다($(readlink "$codex_md"))' "$ROOT/install.sh" && ok "install 이 Codex SKILL.md 심링크를 덮지 않음" || bad "codex 심링크" "있음" "없음"
grep -qF '[ -L "$codex_skill" ]' "$ROOT/install.sh" && ok "install 이 Codex 스킬 디렉터리 심링크도 확인" || bad "codex 디렉터리 심링크" "있음" "없음"

# handoff/handback 봉쇄 규칙이 같은지
eq "두 경로가 같은 봉쇄 패턴 사용" "2" "$(grep -c '"$real_tree"/?\*' "$ROOT/lib/cmd_handoff.sh" "$ROOT/lib/cmd_handback.sh" | awk -F: '{sum+=$2} END{print sum}')"

group "위험 판정 10차 하드닝"

grep -qF 'ho_elapsed_since' "$ROOT/lib/cmd_handback.sh" && ok "실행 중 거부 메시지에 경과 시간 표시(AC14)" || bad "경과 시간" "있음" "없음"
grep -qF 'ho_is_valid_uuid "$uuid"' "$ROOT/lib/cmd_handoff.sh" && ok "handoff 가 세션 uuid 형식 검증" || bad "handoff uuid" "있음" "없음"
grep -qF 'ho_is_valid_uuid "$uuid"' "$ROOT/lib/cmd_handback.sh" && ok "handback 이 세션 uuid 형식 검증" || bad "handback uuid" "있음" "없음"
grep -qF 'ho_backup_path_is_safe' "$ROOT/lib/transfer.sh" && ok "백업 경로 심링크 검증 함수 존재" || bad "백업 검증" "있음" "없음"
grep -qF 'ho_backup_path_is_safe "$root" "$host" "$remote_path"' "$ROOT/lib/cmd_handoff.sh" && ok "handoff 가 백업 경로 검증" || bad "handoff 백업" "있음" "없음"
grep -qF 'ho_backup_path_is_safe "$root" "$host" "$remote_path"' "$ROOT/lib/cmd_handback.sh" && ok "handback 이 백업 경로 검증" || bad "handback 백업" "있음" "없음"

# 경과 시간과 uuid 검증 실측
ho_is_valid_uuid "51f667f0-895e-4bd1-a9ba-590df90ebec3" && ok "정상 uuid 통과" || bad "정상 uuid" "통과" "거부"
ho_is_valid_uuid "../../etc/passwd" && bad "경로 탈출" "거부" "통과" || ok "경로 탈출 uuid 거부"
ho_is_valid_uuid 'abc$(id)' && bad "명령 치환" "거부" "통과" || ok "명령 치환 uuid 거부"
[ -n "$(ho_elapsed_since 2026-01-01T00:00:00Z)" ] && ok "경과 시간이 계산됨" || bad "경과 계산" "값" "빈값"
eq "잘못된 시각은 안내 문구" "알 수 없음" "$(ho_elapsed_since 'not-a-time')"

# 백업 심링크 감지 실측
BS="$TMPROOT/backupsym"; mkdir -p "$BS"; ln -s "$TMPROOT" "$BS/.handoff-backup"
ho_backup_path_is_safe "$BS" "" "" 2>/dev/null && bad "백업 심링크" "거부" "통과" || ok "로컬 백업 심링크 거부"
rm -f "$BS/.handoff-backup"
ho_backup_path_is_safe "$BS" "" "" 2>/dev/null && ok "심링크 아니면 통과" || bad "정상 백업" "통과" "거부"

group "위험 판정 11차 하드닝"

grep -qF "printf 'unknown'" "$ROOT/lib/lease.sh" && ok "깨진 리스는 unknown 으로 구분(fail-open 아님)" || bad "리스 unknown" "있음" "없음"
grep -qF '리스 파일을 읽을 수 없습니다' "$ROOT/lib/cmd_handoff.sh" && ok "handoff 가 깨진 리스에서 중단" || bad "handoff 리스" "있음" "없음"
grep -qF '리스 파일을 읽을 수 없습니다' "$ROOT/lib/cmd_handback.sh" && ok "handback 이 깨진 리스에서 중단" || bad "handback 리스" "있음" "없음"
grep -qF '회수 직전 원격 실경로가 달라졌습니다' "$ROOT/lib/cmd_handback.sh" && ok "파괴적 pull 직전 봉쇄 재확인" || bad "재확인" "있음" "없음"
grep -qF '무엇이 바뀔지 모르는 채로 진행하지 않습니다' "$ROOT/lib/cmd_handback.sh" && ok "dry-run 실패를 변경 없음으로 오인하지 않음" || bad "dry-run 실패" "있음" "없음"
grep -qF 'ho_backup_target_is_safe' "$ROOT/lib/transfer.sh" && ok "백업 타임스탬프 경로까지 심링크 검사" || bad "백업 대상" "있음" "없음"

# 리스 상태 판정 실측
LX="$TMPROOT/leasestate"; mkdir -p "$LX"
ho_config_reset; ho_config_load "$LX"
eq "리스 없으면 local" "local" "$(ho_lease_owner "$LX")"
printf 'not json at all' > "$LX/.handoff-lease"
eq "깨진 리스는 unknown" "unknown" "$(ho_lease_owner "$LX")"
printf '{"note":"no owner"}' > "$LX/.handoff-lease"
eq "owner 없는 리스도 unknown" "unknown" "$(ho_lease_owner "$LX")"
printf '{"owner":"remote"}' > "$LX/.handoff-lease"
eq "정상 리스는 그대로" "remote" "$(ho_lease_owner "$LX")"

# 백업 대상 심링크 감지
BT="$TMPROOT/backuptarget"; mkdir -p "$BT/.handoff-backup"
ln -s "$TMPROOT" "$BT/.handoff-backup/20260101T000000Z"
ho_backup_target_is_safe "$BT" "" "" ".handoff-backup/20260101T000000Z" 2>/dev/null && bad "백업 대상 심링크" "거부" "통과" || ok "백업 타임스탬프 심링크 거부"
ho_backup_target_is_safe "$BT" "" "" ".handoff-backup/20260102T000000Z" 2>/dev/null && ok "없는 경로는 통과" || bad "정상 백업 대상" "통과" "거부"

group "실사용 회귀: rsync 호환성과 잠금"

grep -qF 'ho_rsync_protect_args' "$ROOT/lib/transfer.sh" && ok "--protect-args 지원 여부를 감지" || bad "protect-args 감지" "있음" "없음"
grep -qF 'ho_remote_path_is_shell_safe' "$ROOT/lib/transfer.sh" && ok "미지원 환경에서는 경로 안전성으로 대체" || bad "대체 경로" "있음" "없음"
grep -qF 'ho_lock_acquire' "$ROOT/lib/cmd_handoff.sh" && ok "handoff 가 stale 인식 잠금 사용" || bad "handoff 잠금" "있음" "없음"
grep -qF 'ho_lock_acquire' "$ROOT/lib/cmd_handback.sh" && ok "handback 도 stale 인식 잠금 사용" || bad "handback 잠금" "있음" "없음"
grep -qF 'trap ho_lock_release EXIT' "$ROOT/lib/cmd_handoff.sh" && ok "trap 이 전역 잠금 경로를 씀(unbound variable 방지)" || bad "trap 전역" "있음" "없음"
grep -qF 'HO_LOCK_DIR' "$ROOT/lib/common.sh" && ok "잠금 경로를 전역에 보관" || bad "전역 보관" "있음" "없음"

# 경로 안전성 판정
ho_remote_path_is_shell_safe "/Users/alice/projects/demo" && ok "평범한 경로는 안전" || bad "평범 경로" "안전" "거부"
ho_remote_path_is_shell_safe "/Users/alice/projects/bad name" && bad "공백 경로" "거부" "통과" || ok "공백 든 경로 거부"
ho_remote_path_is_shell_safe '/Users/alice/p;rm -rf /' && bad "세미콜론 경로" "거부" "통과" || ok "세미콜론 경로 거부"
ho_remote_path_is_shell_safe '/Users/alice/p$(id)' && bad "치환 경로" "거부" "통과" || ok "명령 치환 경로 거부"

# stale 잠금 회수
LK="$TMPROOT/lockproj"; mkdir -p "$LK/.handoff-lock"
printf '999999\n' > "$LK/.handoff-lock/pid"     # 존재하지 않는 PID
ho_lock_acquire "$LK" 2>/dev/null && ok "죽은 PID 의 잠금은 회수됨" || bad "stale 잠금" "회수" "거부"
ho_lock_release
[ -d "$LK/.handoff-lock" ] && bad "해제 후 잠금" "없음" "있음" || ok "해제하면 잠금이 지워짐"
mkdir -p "$LK/.handoff-lock"; printf '%s\n' "$$" > "$LK/.handoff-lock/pid"   # 살아있는 PID
ho_lock_acquire "$LK" 2>/dev/null && bad "살아있는 잠금" "거부" "회수함" || ok "살아있는 PID 의 잠금은 존중"
rm -rf "$LK/.handoff-lock"

group "프로젝트 파일에 쓰는 프로세스 사전조건"

grep -qF 'ho_live_processes' "$ROOT/lib/cmd_handoff.sh" && ok "handoff 가 쓰는 프로세스를 조회" || bad "조회" "있음" "없음"
grep -qF '넘길 수 없습니다' "$ROOT/lib/cmd_handoff.sh" && ok "경고가 아니라 중단" || bad "중단 문구" "있음" "없음"
_blk=$(awk '/프로젝트 파일에 쓰고 있는 프로세스는 사전조건 실패다/,/^  fi$/' "$ROOT/lib/cmd_handoff.sh")
printf '%s' "$_blk" | grep -q 'exit 3' && ok "사전조건 실패로 exit 3" || bad "종료코드" "exit 3" "없음"
printf '%s' "$_blk" | grep -q 'force\|yes' && bad "우회 경로" "없음" "있음" || ok "우회 플래그 없이 항상 실패"
_w=$(grep -n 'ho_live_processes' "$ROOT/lib/cmd_handoff.sh" | head -1 | cut -d: -f1)
_t=$(grep -n 'ho_transfer_list' "$ROOT/lib/cmd_handoff.sh" | head -1 | cut -d: -f1)
[ "$_w" -lt "$_t" ] && ok "검사가 전송보다 먼저" || bad "검사 순서" "전송 이전" "이후"

PROC="$TMPROOT/procdir"; mkdir -p "$PROC"

# 파일을 계속 쓰는 프로세스: 잡아야 한다
python3 -c "
import sys,time
f=open(sys.argv[1],'w'); f.write('x'); f.flush(); time.sleep(40)
" "$PROC/live.log" >/dev/null 2>&1 &
_writer=$!
# cwd 만 걸친 프로세스: 잡으면 안 된다 (에이전트의 셸 도구가 이 모양이다)
( cd "$PROC" && exec sleep 40 ) >/dev/null 2>&1 &
_idler=$!
sleep 1.2
_found="$(ho_live_processes "$PROC")"

printf '%s' "$_found" | grep -q "^$_writer	" && ok "파일에 쓰는 프로세스는 감지" || bad "쓰기 감지" "pid $_writer" "$_found"
printf '%s' "$_found" | grep -q "^$_idler	" && bad "cwd 만 걸친 프로세스" "무시" "감지됨" || ok "cwd 만 걸친 프로세스는 무시"
printf '%s' "$_found" | grep -q 'live.log' && ok "어떤 파일을 쓰는지 함께 보고" || bad "파일 경로" "있음" "없음"
printf '%s' "$_found" | grep -q 'awk\|sort\|lsof' && bad "자기 파이프라인" "제외" "포함됨" || ok "자기 파이프라인은 감지하지 않음"
printf '%s' "$_found" | grep -q "^$$	" && bad "자기 자신" "제외" "포함됨" || ok "자기 자신과 조상은 제외"
kill "$_writer" "$_idler" 2>/dev/null || true

EMPTY="$TMPROOT/emptydir"; mkdir -p "$EMPTY"
[ -z "$(ho_live_processes "$EMPTY")" ] && ok "쓰는 프로세스 없으면 조용함" || bad "빈 트리" "출력 없음" "출력 있음"

group "회수는 로컬 세션을 건드리지 않는다"

grep -qF 'ho_pull_session' "$ROOT/lib/cmd_handback.sh" && bad "세션 회수" "안 함" "함" || ok "원격 세션을 가져오지 않음"
grep -qF 'ho_session_diverged' "$ROOT/lib/cmd_handback.sh" && bad "갈래 판정" "안 함" "함" || ok "갈래 판정을 하지 않음"
grep -qF '.local-' "$ROOT/lib/cmd_handback.sh" && bad "세션 백업" "없음" "있음" || ok "세션 백업을 만들지 않음"
grep -qF '우회 경로가 없다' "$ROOT/lib/cmd_handback.sh" && bad "하드 스톱" "없음" "있음" || ok "갈래 하드 스톱이 없음"
grep -qF '로컬 세션은 그대로입니다' "$ROOT/lib/cmd_handback.sh" && ok "세션을 안 건드린다고 알림" || bad "안내" "있음" "없음"
grep -qF '원격이 무엇을 했는지는' "$ROOT/lib/cmd_handback.sh" && ok "원격 대화 위치를 안내" || bad "원격 안내" "있음" "없음"
# 파일 회수와 시크릿 삭제는 그대로여야 한다
grep -qF 'ho_rsync_pull' "$ROOT/lib/cmd_handback.sh" && ok "파일 회수는 유지" || bad "파일 회수" "있음" "없음"
grep -qF 'ho_remote_purge_secrets' "$ROOT/lib/cmd_handback.sh" && ok "시크릿 삭제는 유지" || bad "시크릿 삭제" "있음" "없음"

group "원격 에이전트는 대화형으로 뜬다"

grep -v '^ *#' "$ROOT/lib/remote.sh" | grep -q -- ' -p ' && bad "헤드리스 -p" "없음" "남아있음" || ok "claude 를 -p 로 띄우지 않음"
_cs=$(awk '/^ho_remote_agent_start\(\)/,/^}/' "$ROOT/lib/remote.sh")
printf '%s' "$_cs" | grep -q 'ho_remote_agent_prompt' && ok "claude: 기동 후 프롬프트" || bad "claude 프롬프트" "있음" "없음"
_xs=$(awk '/^ho_remote_codex_start\(\)/,/^}/' "$ROOT/lib/remote.sh")
printf '%s' "$_xs" | grep -q 'ho_remote_agent_prompt' && ok "codex: 기동 후 프롬프트" || bad "codex 프롬프트" "있음" "없음"
printf '%s' "$_xs" | grep -q 'shq "$prompt")"$' && bad "codex 인자 전달" "없음" "있음" || ok "codex 도 지시문을 인자로 넣지 않음"

group "SSH 재시도"

grep -q '255' "$ROOT/lib/remote.sh" && ok "연결 실패 코드를 구분" || bad "255 판정" "있음" "없음"
_ss=$(awk '/^ho_ssh\(\)/,/^}/' "$ROOT/lib/remote.sh")
printf '%s' "$_ss" | grep -q 'rc" = "255"' && ok "255 일 때만 재시도" || bad "재시도 조건" "255 한정" "다름"
# 실제 실행 검증: 명령 실패(1)는 재시도하지 않고, 연결 실패(255)만 재시도한다.
if ho_ssh mini 'echo ok' >/dev/null 2>&1; then
  ho_ssh mini 'exit 1' >/dev/null 2>&1; _rc1=$?
  eq "명령 실패는 그대로 1 로 반환(재시도 안 함)" "1" "$_rc1"
  _t0=$(date +%s)
  ho_ssh mini 'exit 3' >/dev/null 2>&1; _rc3=$?
  _t1=$(date +%s)
  eq "다른 실패 코드도 그대로 반환" "3" "$_rc3"
  [ $(( _t1 - _t0 )) -lt 3 ] && ok "실패 명령에 재시도 지연이 붙지 않음" || bad "지연" "3초 미만" "$(( _t1 - _t0 ))초"
  ho_ssh nonexistent-host-for-test-xyz 'echo hi' >/dev/null 2>&1; _rc255=$?
  eq "연결 불가 호스트는 255 반환" "255" "$_rc255"
else
  ho_say "  --   SSH 재시도 실행 검증 건너뜀 (mini 에 접속할 수 없음)"
fi

group "원격 프롬프트 전달 보증"

_pf=$(awk '/^ho_remote_agent_prompt\(\)/,/^}/' "$ROOT/lib/remote.sh")
printf '%s' "$_pf" | grep -q -- '--wait' && ok "전달을 기다려 확인" || bad "--wait" "있음" "없음"
printf '%s' "$_pf" | grep -q -- '--until working' && ok "완료가 아니라 착수까지만 기다림" || bad "--until" "working" "없음"
printf '%s' "$_pf" | grep -q -- '--timeout' && ok "무한 대기하지 않음" || bad "--timeout" "있음" "없음"

printf '\n%s\n' "----------------------------------------"
printf 'pass %s / fail %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
