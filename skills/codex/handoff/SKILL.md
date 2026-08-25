---
name: handoff
description: |
  로컬 머신과 원격 머신 사이에서 작업환경을 넘기고 되받는다.
  사용자가 "/handoff", "/handback", "원격으로 넘겨", "저쪽에서 이어서",
  "돌아왔으니 가져와", "회수해줘", "핸드오프 상태", "원격 정리" 라고 말할 때 사용한다.
  Codex 경로는 파일과 작업환경만 넘기고 원격에서 새 Codex 세션을 시작한다.
---

# handoff (Codex)

로컬에서 하던 작업을 원격 머신으로 넘기고 되받는 도구다.

Claude 경로와 달리 **대화 히스토리는 따라가지 않는다.** Codex 세션은 sqlite 3개 테이블에
분산 저장되고 스키마 의존과 DB 손상 위험이 커서 v1에서 이관하지 않기로 했다.
대신 원격에서 새 Codex 세션을 요약 프롬프트와 함께 시작한다.

## 명령

```sh
handoff candidates           # 전송 후보 조회
handoff include|exclude <경로>  # 사용자의 선택을 기록
handoff --codex "<지시문>"   # 파일 전송 + 원격에 새 Codex 세션
handback                     # 파일 회수와 리스 반환 (런타임 공용)
handoff status               # 상태 5항목 (런타임 공용)
handoff clean                # 정리 (런타임 공용)
handoff bootstrap            # 원격 준비 (런타임 공용)
```

`handback` / `status` / `clean` / `bootstrap` 은 Claude 경로와 완전히 같다.
차이는 `handoff` 뿐이다.

## /handoff 를 부를 때

1. 요약 프롬프트를 만든다. 사용자 지시문이 본문이고, 아래 네 항목을 덧붙인다.
   각 항목은 **5줄을 넘기지 않는다.**

```
[작업 목표]
[지금까지 한 것]
[다음 할 일]
[주의사항]
```

2. **파일 내용, 시크릿, 토큰, 자격증명을 요약에 절대 넣지 마라.** 파일은 경로와 역할만 언급한다.
3. 요약을 만들 수 없으면 사용자 지시문만으로 진행하고, 요약이 빠졌다는 사실을 알려라.
   요약 실패가 handoff 실패가 되어서는 안 된다.
4. `handoff --codex "<지시문 + 요약>"` 을 실행한다. 확인을 대신 묻지 마라.
5. 종료 코드로 상황을 구분한다.
   - `0`: workspace id 와 `herdr --remote <host>`, `handback` 안내
   - `3`: 사전조건 중단(리스가 원격이면 `handback`, 부트스트랩 미완료면 `handoff bootstrap`)
   - `4`: 전송 실패. 같은 명령 재실행으로 이어진다
   - `5`: 파일은 원격에 있고 리스도 원격인데 pane 이 안 떴다. 재실행 또는 회수 안내

## /handback 을 부를 때

`handback` 을 실행한다. 미리보기 확인은 스크립트가 직접 묻는다.

Codex 경로는 대화가 따라오지 않으므로, 원격이 무엇을 했는지는 두 곳에서 확인한다.

- `herdr --remote <host>` 로 붙어서 pane 스크롤백
- 회수된 파일의 변경(`git diff` 등)

세션 갈래 하드 스톱은 Claude 경로 전용이라 Codex 회수에서는 발생하지 않는다.
다만 원격 상태 판정 불가와 작업 중 거부는 동일하게 적용된다.

## 하지 말 것

- Codex 세션 sqlite(`state_5.sqlite`, `thread_history_1.sqlite`)를 직접 읽거나 쓰지 마라. v1 비목표다
- 확인을 대신 묻거나 무확인 원칙을 우회하지 마라
- 원격에서 자신이 만들지 않은 workspace, pane, 프로세스를 건드리지 마라
- 원격의 홈 트리와 `deny_extra` 로 지정된 운영 경로를 건드리지 마라
- 시크릿을 요약, 로그, 커밋에 남기지 마라
