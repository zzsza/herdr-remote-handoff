#!/usr/bin/env python3
"""경로 목록을 한 프로세스에서 패턴 매칭한다 (issue #1).

무시 파일이 수만 개인 프로젝트에서 파일마다 ho_is_included/ho_is_excluded
서브셸을 띄우면 스캔이 분 단위로 걸린다. stdin 의 경로들을 한 번에 받아
같은 규칙으로 거른다.

매칭 규칙은 lib/common.sh 의 ho_matches_any 와 같아야 한다:
- 패턴에 / 가 있으면 경로 전체와 글롭 비교
- 없으면 basename 과 비교하고, 경로 전체와도 한 번 더 비교
제외(exclude) 판정은 경로 성분 단위 검사를 더한다
(node_modules/foo/bar.js 는 node_modules 패턴에 걸린다).
bash 의 case 글롭과 fnmatch 는 * 가 / 도 포함해 매칭하는 점이 같다.

사용: path_filter.py <include-only|not-excluded|candidates>
패턴은 env 로 받는다: HO_PF_INCLUDE, HO_PF_EXCLUDE (줄바꿈 구분)
"""
import fnmatch
import os
import sys


def read_patterns(name):
    return [p.strip() for p in os.environ.get(name, "").splitlines() if p.strip()]


def matches_any(path, patterns):
    base = os.path.basename(path)
    for pattern in patterns:
        if "/" in pattern:
            if fnmatch.fnmatchcase(path, pattern):
                return True
        else:
            if fnmatch.fnmatchcase(base, pattern) or fnmatch.fnmatchcase(path, pattern):
                return True
    return False


def is_excluded(path, patterns):
    if matches_any(path, patterns):
        return True
    return any(
        matches_any(segment, patterns) for segment in path.split("/") if segment
    )


def main():
    if len(sys.argv) != 2:
        sys.exit("사용법: path_filter.py <include-only|not-excluded|candidates>")
    mode = sys.argv[1]
    include = read_patterns("HO_PF_INCLUDE")
    exclude = read_patterns("HO_PF_EXCLUDE")

    for line in sys.stdin:
        path = line.rstrip("\n")
        if not path:
            continue
        if mode == "include-only":
            if include and matches_any(path, include):
                print(path)
        elif mode == "not-excluded":
            if not is_excluded(path, exclude):
                print(path)
        elif mode == "candidates":
            if is_excluded(path, exclude):
                continue
            if include and matches_any(path, include):
                continue
            print(path)
        else:
            sys.exit("알 수 없는 모드: " + mode)


main()
