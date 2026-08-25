#!/usr/bin/env python3
"""프롬프트 안전 검사 (R16/AC16).

세 가지 하위 명령을 가진다.

  leak   <root> <prompt>   시크릿 파일의 값이 프롬프트에 나타나면 종료 0(누출), 아니면 1
  check  <prompt>          Codex 요약 계약(네 항목, 각 5줄 이내)을 만족하면 0
  strip  <prompt>          계약을 못 지킨 요약을 떼고 지시문만 stdout 으로

시크릿 패턴은 HO_SECRET_PATTERNS 환경변수(콤마 구분)로 받는다.
검사 대상 파일 목록은 stdin 으로 한 줄에 하나씩 받는다.
"""

import fnmatch
import json
import os
import re
import sys

SECTIONS = ["작업 목표", "지금까지 한 것", "다음 할 일", "주의사항"]
QUOTES = "\"'`"


def _secret_patterns():
    raw = os.environ.get("HO_SECRET_PATTERNS", "")
    return [p.strip() for p in raw.split(",") if p.strip()]


def _is_secret(rel, patterns):
    base = os.path.basename(rel)
    return any(fnmatch.fnmatch(base, p) or fnmatch.fnmatch(rel, p) for p in patterns)


def _candidate_values(text):
    """파일에서 '값'으로 볼 만한 문자열을 뽑는다.

    KEY=VALUE, key: value, JSON 문자열 값을 모두 훑는다.
    키 이름은 흔해서 오탐을 내므로 값 쪽만 본다.
    """
    values = []
    try:
        data = json.loads(text)
        stack = [data]
        while stack:
            cur = stack.pop()
            if isinstance(cur, dict):
                stack.extend(cur.values())
            elif isinstance(cur, list):
                stack.extend(cur)
            elif isinstance(cur, str):
                values.append(cur)
    except Exception:
        pass

    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            line = line.split("=", 1)[1]
        elif ":" in line:
            line = line.split(":", 1)[1]
        values.append(line)

    cleaned = []
    for v in values:
        v = v.strip().strip(QUOTES).strip()
        # 3자 PIN 도 시크릿이다. 임계를 낮추되 너무 흔한 값은 아래에서 거른다.
        if len(v) < 3:
            continue
        # 긴 패스프레이즈도 시크릿이다. 12단어를 넘는 것만 산문으로 본다.
        if " " in v and len(v.split()) > 12:
            continue
        cleaned.append(v)
    return cleaned


def cmd_leak(root, prompt):
    patterns = _secret_patterns()
    if not patterns or not prompt:
        return 1
    seen = set()
    for rel in sys.stdin.read().splitlines():  # 추적/미추적/무시 파일이 모두 들어온다
        rel = rel.strip()
        if not rel or rel in seen:
            continue
        seen.add(rel)
        if not _is_secret(rel, patterns):
            continue
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            continue
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for value in _candidate_values(text):
            if value in prompt:
                sys.stderr.write("누출된 값이 %s 에서 발견되었습니다\n" % rel)
                return 0
    return 1


def _section_spans(text):
    spans = []
    for name in SECTIONS:
        match = re.search(r"\[\s*" + re.escape(name) + r"\s*\]", text)
        if match is None:
            return None
        spans.append((match.start(), match.end()))
    spans.sort()
    return spans


def cmd_check(prompt):
    spans = _section_spans(prompt)
    if spans is None:
        return 1
    for index, (_, end) in enumerate(spans):
        stop = spans[index + 1][0] if index + 1 < len(spans) else len(prompt)
        body = prompt[end:stop]
        if len([line for line in body.splitlines() if line.strip()]) > 5:
            return 1
    return 0


def cmd_strip(prompt):
    first = len(prompt)
    for name in SECTIONS:
        match = re.search(r"\[\s*" + re.escape(name) + r"\s*\]", prompt)
        if match is not None:
            first = min(first, match.start())
    out = prompt[:first].strip()
    sys.stdout.write(out if out else prompt.strip())
    return 0


def main(argv):
    if len(argv) < 2:
        return 2
    action = argv[1]
    if action == "leak" and len(argv) >= 4:
        return cmd_leak(argv[2], argv[3])
    if action == "check" and len(argv) >= 3:
        return cmd_check(argv[2])
    if action == "strip" and len(argv) >= 3:
        return cmd_strip(argv[2])
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
