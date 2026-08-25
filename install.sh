#!/usr/bin/env bash
# 설치: 스크립트 심링크, 스킬 배치, 훅 등록.
#
# 멱등하다. 이미 되어 있으면 아무것도 바꾸지 않는다.
# Claude 스킬은 심링크로, Codex 스킬은 실제 파일로 둔다
# (Codex 는 심링크된 SKILL.md 를 목록에서 누락시킬 수 있다).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin"
say() { printf '%s\n' "$*" >&2; }

mkdir -p "$BIN"

# 1. 실행 파일 심링크 (handoff, handback 둘 다 같은 스크립트)
for name in handoff handback; do
  target="$BIN/$name"
  if [ -L "$target" ] && [ "$(readlink "$target")" = "$ROOT/bin/handoff" ]; then
    say "[ok] $target"
  elif [ -e "$target" ] && [ ! -L "$target" ]; then
    say "[!] $target 에 이미 실제 파일이 있습니다. 덮어쓰지 않았습니다."
    say "    직접 확인한 뒤 옮기고 다시 실행하세요."
  elif [ -L "$target" ]; then
    say "[!] $target 이 다른 곳($(readlink "$target"))을 가리킵니다. 덮어쓰지 않았습니다."
  else
    ln -s "$ROOT/bin/handoff" "$target"
    say "[+] $target -> $ROOT/bin/handoff"
  fi
done

# 2. Claude 스킬 (심링크 허용)
claude_skill="$HOME/.claude/skills/handoff"
mkdir -p "$(dirname "$claude_skill")"
if [ -L "$claude_skill" ] && [ "$(readlink "$claude_skill")" = "$ROOT/skills/claude/handoff" ]; then
  say "[ok] $claude_skill"
elif [ -e "$claude_skill" ] && [ ! -L "$claude_skill" ]; then
  # 실제 디렉터리나 파일이 있으면 지우지 않는다. 남의 스킬을 되돌릴 수 없게 날리는 일이
  # 설치 스크립트에서 일어나서는 안 된다.
  say "[!] $claude_skill 에 이미 실제 항목이 있습니다. 덮어쓰지 않았습니다."
  say "    직접 확인한 뒤 옮기거나 지우고 다시 실행하세요."
else
  ln -sfn "$ROOT/skills/claude/handoff" "$claude_skill"
  say "[+] $claude_skill"
fi

# 3. Codex 스킬 (SKILL.md 는 실제 파일이어야 한다)
codex_skill="$HOME/.codex/skills/handoff"
codex_md="$codex_skill/SKILL.md"
if [ -L "$codex_skill" ]; then
  say "[!] $codex_skill 이 심링크입니다. 덮어쓰지 않았습니다."
elif [ -e "$codex_skill" ] && [ ! -d "$codex_skill" ]; then
  say "[!] $codex_skill 이 디렉터리가 아닙니다. 덮어쓰지 않았습니다."
else
  mkdir -p "$codex_skill"
  if [ -L "$codex_md" ]; then
    # 심링크면 그 대상(예: ~/.ssh/config)을 cp 가 직접 덮어쓴다.
    say "[!] $codex_md 이 심링크입니다($(readlink "$codex_md")). 덮어쓰지 않았습니다."
  elif cmp -s "$ROOT/skills/codex/handoff/SKILL.md" "$codex_md"; then
    say "[ok] $codex_md"
  else
    if [ -f "$codex_md" ]; then
      backup="$codex_md.bak.$(date -u +%Y%m%dT%H%M%SZ)"
      cp "$codex_md" "$backup"
      say "[~] 기존 SKILL.md 를 $backup 로 백업"
    fi
    cp "$ROOT/skills/codex/handoff/SKILL.md" "$codex_md"
    say "[+] $codex_md (실제 파일)"
  fi
fi

# 4. UserPromptSubmit 훅 등록 (기존 항목은 건드리지 않고 추가만)
hook_cmd="$ROOT/hooks/handoff-lease-guard.sh"
python3 - "$HOME/.claude/settings.json" "$hook_cmd" <<'PY'
import json,os,sys
path,cmd=sys.argv[1],sys.argv[2]
if not os.path.exists(path):
    print("[!] settings.json 이 없습니다: %s" % path, file=sys.stderr); sys.exit(1)
d=json.load(open(path))
hooks=d.setdefault('hooks',{})
ups=hooks.setdefault('UserPromptSubmit',[])
for entry in ups:
    for h in entry.get('hooks',[]):
        if h.get('command')==cmd:
            print("[ok] UserPromptSubmit 훅 이미 등록됨", file=sys.stderr); sys.exit(0)
ups.append({"hooks":[{"type":"command","command":cmd,"timeout":5}]})
tmp=path+'.tmp'
# 고정 경로의 임시 파일이 심링크면 그 대상을 잘라버린다. 지우고 배타 생성한다.
if os.path.islink(tmp) or os.path.exists(tmp):
    os.unlink(tmp)
fd=os.open(tmp, os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW, 0o600)
with os.fdopen(fd,'w') as f:
    json.dump(d,f,ensure_ascii=False,indent=2)
    f.write('\n')
os.replace(tmp,path)
print("[+] UserPromptSubmit 훅 등록", file=sys.stderr)
PY

say ""
say "설치 완료. 'handoff --help' 로 확인하세요."
say "원격 준비: handoff bootstrap"
