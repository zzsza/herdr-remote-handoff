# 새 원격 머신 세팅에서 발견한 간극

2026-08-25, 실제 세팅 중 발견. README 절차만으로 진행이 막힌 지점과 적용한 우회, 저장소에 제안하는 변경.

## 환경

| | 로컬 | 원격 |
| --- | --- | --- |
| 머신 | MacBook Pro (macOS 15.5) | Mac mini (macOS 26.4) |
| 연결 | Tailscale (`~/.ssh/config` Host 별칭) | - |
| claude / herdr 설치 위치 | - | `/opt/homebrew/bin` (brew) |

## 1. 원격 비대화형 SSH PATH 에 claude/herdr 가 없음

**증상**: bootstrap 의 "원격 claude/herdr PATH" 검사 실패. `ssh <host> 'command -v claude'` 가 빈 결과.

**원인**: `ho_ssh` 는 원격 명령 앞에 `export PATH="$HOME/.local/bin:$PATH"` 만 붙인다
(`lib/remote.sh` 의 `HO_REMOTE_PATH_PREFIX`). brew 로 설치한 claude/herdr 는
`/opt/homebrew/bin` 에 있는데, sshd 가 주는 비대화형 셸의 기본 PATH 에는
`/opt/homebrew/bin` 이 없다. 로그인 셸(`bash -lc`)에서는 보이므로 대화형 확인만으로는 놓친다.

**적용한 우회**: 원격 `~/.local/bin` 에 심링크 생성.

```sh
ssh <host> 'mkdir -p ~/.local/bin && ln -sfn /opt/homebrew/bin/claude ~/.local/bin/claude && ln -sfn /opt/homebrew/bin/herdr ~/.local/bin/herdr'
```

**제안**:
- bootstrap 이 로그인 셸에서 claude/herdr 실경로를 찾아 `~/.local/bin` 심링크를 자동 생성.
  (검사만 하고 실패로 끝내기에는 원인 파악이 어려움)
- 또는 `HO_REMOTE_PATH_PREFIX` 에 `/opt/homebrew/bin` 추가 (Apple Silicon brew 기본 경로).
- 최소한 README 전제조건 표의 "원격은 `PATH` 에 `claude`" 항목에
  **비대화형 SSH 기준**이라는 것과 `~/.local/bin` 심링크 우회를 명시.

## 2. 첫 접속 원격은 host key 미등록으로 즉시 실패

**증상**: `ssh -o BatchMode=yes <host>` 가 `Host key verification failed` 로 종료.

**원인**: `ho_ssh` 는 `BatchMode=yes` 라 known_hosts 에 없는 호스트에서 확인 프롬프트 없이 실패한다.
새 원격을 처음 붙이는 경우가 bootstrap 의 주 사용처인데, 그 경우 항상 걸린다.

**적용한 우회**: bootstrap 전에 수동으로 한 번 접속해 host key 를 등록.

```sh
ssh -o StrictHostKeyChecking=accept-new <host> true
```

**제안**: README 설치 절차에 위 한 줄 추가, 또는 bootstrap 의 "ssh 접속" 실패 메시지에
host key 미등록 가능성과 위 명령을 안내.

## 3. herdr 서버 상시 기동은 사용자 몫인데 안내가 없음

**증상 아님, 운영 간극**: handback 은 원격 herdr 서버가 응답하지 않으면 회수를 거부한다(fail-closed).
재부팅 후 서버가 자동으로 뜨지 않으면 원격에 결과물이 잠긴 채 회수만 막힌다.

**적용한 설정**: `brew services start herdr` (로그인 시 자동 시작 LaunchAgent 등록).
단, 이것도 **해당 계정이 로그인해야** 뜬다. 자동 로그인이 꺼진 headless 원격이라면 여전히 간극.

**제안**: README 전제조건의 herdr 항목에 상시 기동 요구와 `brew services start herdr` 를 명시.

## 4. 원격 pane 셸의 oh-my-zsh 업데이트 프롬프트가 기동 명령을 삼킴

**증상**: handoff 가 exit 5 (`timed out waiting for agent startup`). pane 을 읽어 보면
`[oh-my-zsh] Would you like to update? [Y/n]` 이 떠 있고, 입력된 기동 명령의 첫 글자가
그 프롬프트에 먹혀 `zsh: command not found: laude` 로 깨져 있다.

**원인**: `herdr agent start` 는 pane 셸에 명령을 타이핑하는 방식인데, 셸 rc 가 대화형
프롬프트(omz 자동 업데이트 등)를 띄우면 입력이 유실된다.

**적용한 우회**: 수동으로 프롬프트를 넘기고 재기동. 재발 방지는 원격 `~/.zshrc` 에
`zstyle ':omz:update' mode disabled` (또는 `auto`) 추가.

**제안**: 기동 실패 시 pane 내용 일부를 에러 메시지에 포함하면 원인 파악이 즉시 된다.
README 한계 절에 "원격 셸 rc 가 대화형 프롬프트를 띄우면 기동이 깨진다" 명시.
단, zstyle 은 `source oh-my-zsh.sh` **앞에** 있어야 효과가 있다 (뒤에 넣으면 그대로 재발).

## 5. 첫 실행 trust 대화상자가 자율 기동을 막음

**증상**: 원격 claude 가 떠도 `Is this a project you created or one you trust?` 폴더 신뢰
대화상자에서 멈춘다. herdr 는 `agent blocked during startup` 으로 보고하고, handoff 는
startup timeout (exit 5) 이 된다.

**원인**: bypassPermissions 도 폴더 신뢰 대화상자는 건너뛰지 않는다. 신뢰 기록은
프로젝트 경로 단위라 **새 프로젝트를 처음 handoff 할 때마다 재발**한다.

**적용한 우회**: `herdr agent send-keys <agent> enter` 로 수락 후
`herdr agent prompt` 로 지시문을 수동 주입.

**적용한 수정 (이 저장소에 구현, PR 대상)**: `lib/remote.sh` 에 `ho_remote_trust_project`
추가. 기동 전에 원격 `~/.claude.json` 의 해당 프로젝트 항목(심링크 경로와 실경로 둘 다)에
`hasTrustDialogAccepted: true` 를 기록한다. handoff 는 방금 로컬에서 전송한 트리라 신뢰
판단이 이미 성립한다. 실패 시 경고만 하고 기동은 계속한다(종전 동작으로 후퇴).
`lib/cmd_handoff.sh` 의 claude 기동 직전에 호출. 새 프로젝트 왕복으로 검증 완료,
기존 테스트 271개 통과.

## 6. deny 규칙의 `Write()` 패턴이 무시됨 (경고)

**증상**: 원격 claude 기동 시 `Permission deny rule ...: Write(...) is not matched by file
permission checks — only Edit(path) rules are. Use Edit(...) instead` 경고 3건.

**원인**: `ho_deny_rules` 가 경로마다 `Read/Edit/Write` 3종을 생성하는데, Claude Code 는
파일 편집 계열 도구(Write 포함)를 `Edit(path)` 규칙으로만 검사한다. `Write()` 규칙은
무시된다. 실효 차단은 `Read`/`Edit` 가 담당하므로 구멍은 아니고 소음이지만,
README 가 말하는 fail-open 경고 경로가 실기계에서 항상 밟힌다.

**제안**: `ho_deny_rules` 에서 `Write()` 항목 제거 (생성과 검증이 같은 함수라 한 곳만 고치면 됨).

## 7. Codex 경로에서 지시문 주입이 유실됨

**증상**: `handoff --codex` 가 exit 0 으로 성공 보고하지만, 원격 codex 입력창이 비어 있고
아무 작업도 시작되지 않는다. `herdr agent prompt --wait --until working` 도 working 을
반환하며 성공을 오보한다.

**원인**: codex 는 기동 직후 시작 화면(팁, usage 안내)을 그리는 동안 입력을 받지 못한다.
herdr 가 그 시작 화면의 스피너를 working 으로 오인해, 지시문이 실제로 들어가기 전에
성공으로 판정한다. claude 경로의 주석(`ho_remote_agent_prompt`)이 경고하는 것과 같은
유형인데, `--until working` 으로도 codex 는 못 거른다.

**적용한 수정 (이 저장소에 구현, PR 대상)**: `ho_remote_codex_start` 에서 지시문 주입 전에
`herdr agent wait --until idle --timeout 20000` 으로 입력 가능 상태를 먼저 확인한다.
확인 실패면 넣지 않고 실패를 반환한다(유실된 채 성공 보고보다 exit 5 로 드러나는 쪽이 낫다).
codex 왕복 재검증으로 확인 완료, 기존 테스트 271개 통과.

## 참고: 로컬 herdr "선택" 의 체감

README 대로 선택 사항이 맞지만, herdr pane 밖(일반 터미널)에서 띄운 Claude 세션은
매번 `HO_SESSION_UUID` 를 손으로 지정해야 한다. "로컬 herdr 없이 쓰면 세션 자동 탐지가
안 된다" 는 결과를 전제조건 표 비고에 한 줄 적어주면 설치 판단이 빨라진다.
