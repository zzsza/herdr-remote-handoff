# handoff

로컬 머신에서 하던 Claude Code 세션과 프로젝트를 원격 머신으로 통째로 넘기고, 돌아와서 되받는 CLI.

노트북을 덮고 나가야 하는데 작업은 계속 굴러가야 할 때 쓴다.
`handoff "이거 마저 마무리해줘"` 한 줄이면 파일과 대화 히스토리가 원격으로 넘어가고,
원격에서 같은 대화 컨텍스트를 이어받은 에이전트가 자율로 계속한다.
돌아와서 `handback` 을 치면 원격이 만들어낸 결과가 로컬로 돌아온다.

## 어떻게 성립하는가

두 가지 사실 위에 서 있다.

1. Claude Code 세션은 `~/.claude/projects/<cwd 절대경로의 / → - 치환>/<uuid>.jsonl` 단일 파일이고,
   `--resume` 은 같은 파일에 append 한다. 그래서 파일 하나만 옮기면 대화가 따라간다.
2. 그 파일 안에는 cwd 절대경로와 도구 결과의 경로가 그대로 들어 있다.
   경로를 변환하려 들면 깨지므로, **원격에 같은 절대경로를 만들어 맞춘다.**

그래서 원격에는 로컬 홈과 같은 이름의 심링크를 하나 만든다.
예를 들어 로컬 홈이 `/Users/alice` 이고 원격 홈이 `/Users/bob` 이면,
원격에 `/Users/alice -> /Users/bob/.handoff-tree` 를 둔다.
프로젝트 절대경로가 양쪽에서 일치하면서도, 원격 자신의 작업 트리와는 물리적으로 분리된다.

## 전제조건

이 도구는 아래가 모두 갖춰진 환경을 전제한다. 하나라도 없으면 `handoff bootstrap` 이 무엇이 빠졌는지 알려준다.

| 항목 | 로컬 | 원격 | 비고 |
| --- | --- | --- | --- |
| macOS | 필요 | 필요 | 경로 규약과 `launchctl` 차단 규칙이 macOS 전제 |
| bash, python3, rsync | 필요 | 필요 | macOS 기본 제공 |
| SSH 무암호 접속 | 필요 | - | `~/.ssh/config` 에 Host 별칭과 키 인증 |
| [Claude Code](https://claude.com/claude-code) | 필요 | 필요 | 원격은 `PATH` 에 `claude` 가 있어야 함 |
| [herdr](https://github.com/herdrdev/herdr) | 선택 | **필수** | 아래 참고 |

### herdr 이 원격에서 필수인 이유

herdr 은 코딩 에이전트용 터미널 멀티플렉서다. 이 도구에서 herdr 은 단순한 터미널 편의가 아니라
**원격 에이전트의 제어면**이다. 구체적으로 이런 일을 herdr 이 한다.

- 핸드오프 전용 workspace 와 pane 생성 (`herdr workspace create`, `herdr pane list`)
- 원격 자율 세션 기동과 지시문 주입 (`herdr agent start`, `herdr agent prompt --wait`)
- 원격 에이전트가 지금 작업 중인지 관측 (`herdr agent list`)
- 강제 회수 전 정지와 정지 확인 (`herdr agent send-keys`, `herdr agent wait`)
- `handoff clean` 이 지워도 되는 트리인지 판정

`handback` 은 rsync `--delete` 로 파괴적 동기화를 한다.
원격이 아직 작업 중인데 회수하면 그 결과가 사라지므로, **원격 상태를 관측할 수 없으면 회수를 거부한다**(fail-closed).
herdr 이 없으면 이 관측이 불가능해서, 안전장치가 없는 rsync 래퍼가 된다.
그래서 herdr 없이 쓰는 경로는 제공하지 않는다.

로컬 herdr 은 선택이다. 있으면 현재 세션 uuid 를 자동으로 찾고, 없으면 `HO_SESSION_UUID` 로 직접 지정하면 된다.

## 설치

```sh
git clone https://github.com/yansfil/herdr-remote-handoff.git
cd herdr-remote-handoff
./install.sh
```

`install.sh` 는 멱등하고, 이미 되어 있는 것은 건드리지 않는다. 하는 일은 넷이다.

1. `~/.local/bin/handoff` 와 `~/.local/bin/handback` 심링크 생성
2. Claude 스킬을 `~/.claude/skills/handoff` 에 심링크
3. Codex 스킬을 `~/.codex/skills/handoff/SKILL.md` 에 실제 파일로 복사
   (Codex 는 심링크된 `SKILL.md` 를 목록에서 누락시킬 수 있다)
4. `~/.claude/settings.json` 에 `UserPromptSubmit` 훅 등록
   (넘어간 세션에서 프롬프트를 제출하면 차단하는 리스 가드)

기존 파일이 있으면 덮어쓰지 않고 경고만 하므로, 충돌이 나면 직접 확인한 뒤 다시 실행한다.

그다음 원격을 준비한다.

```sh
handoff --to <host> bootstrap
```

`bootstrap` 은 SSH 접속, 원격 홈 조회, 핸드오프 트리 심링크, 원격 `claude`/`herdr` 존재,
권한 설정 파일 배치, herdr 서버 응답을 순서대로 검사하고 자동으로 할 수 있는 것만 수행한다.
심링크 생성은 `/Users` 가 root 소유라 관리자 권한이 필요해서, 명령을 출력만 하고 사람이 직접 실행한다.

```
mkdir -p /Users/bob/.handoff-tree && sudo ln -s /Users/bob/.handoff-tree /Users/alice
```

## 사용

```sh
handoff "리팩터링 마저 하고 테스트 통과시켜줘"   # 넘기기. 확인 없이 끝까지 진행
handback                                          # 되받기. 미리보기 확인을 받는다
handoff status                                    # 현재 프로젝트 상태
handoff clean                                     # 보존 기간 지난 원격 트리와 백업 정리
handoff candidates                                # gitignore된 전송 후보 목록
handoff include <경로> / exclude <경로>           # 그 후보의 전송 여부를 굳힘
handoff bootstrap                                 # 원격 준비 상태 검사와 미완료분 수행
```

Claude Code 나 Codex 안에서는 동봉된 `handoff` 스킬이 이 명령들을 대신 부른다.
`/handoff`, `/handback` 이라고 말하면 된다.

`--codex` 를 붙이면 파일과 작업환경만 넘기고 원격에서 새 Codex 세션을 시작한다.
Codex 세션은 sqlite 여러 테이블에 분산 저장돼서 대화 히스토리는 따라가지 않고, 대신 요약 프롬프트가 들어간다.

## 설정

우선순위는 CLI 플래그 > 프로젝트 `.handoffrc` > 전역 `~/.config/handoff/config.toml` > 기본값이다.
`.handoffrc` 와 `config.toml` 은 같은 `key = value` 문법을 쓴다.

| 키 | 플래그 | 기본값 | 뜻 |
| --- | --- | --- | --- |
| `remote` | `--to` | `mini` | 원격 SSH 대상. `~/.ssh/config` 의 Host 별칭 |
| `remote_tree` | `--remote-tree` | 로컬 `$HOME` | 핸드오프 트리 절대경로. 로컬과 원격이 공유하는 이름 |
| `remote_tree_target` | `--remote-tree-target` | (비움) | 원격에서 그 경로가 가리킬 실제 디렉터리. 비우면 원격 홈을 조회해 `<원격 홈>/.handoff-tree` 로 파생 |
| `deny_extra` | `--deny-extra` | (비움) | 원격 자율 세션에서 추가로 차단할 경로. 콤마 구분 |
| `include` | `--include` | `.env*,*.local.json,.claude/settings.local.json,*.sqlite,*.db` | gitignore 돼도 전송할 패턴 |
| `exclude` | `--exclude` | `node_modules,.venv,venv,__pycache__,.pytest_cache,.mypy_cache,.ruff_cache,.tox,.nox,.eggs,.ipynb_checkpoints,.cache,.turbo,.parcel-cache,.pnpm-store,coverage,target,.gradle,.bundle,Pods,DerivedData,Carthage,.build,_build,.stack-work,zig-cache,zig-out,.terraform,dist,build,.next,.nuxt,.svelte-kit,.DS_Store` | 항상 제외할 패턴 |
| `secrets` | `--secrets` | `.env*` | 회수 직후 원격에서 지울 패턴 |
| `tree_retention_days` | `--tree-retention` | `14` | 원격 트리 보존 일수 |
| `backup_retention_days` | `--backup-retention` | `7` | 백업 보존 일수 |
| `size_confirm_bytes` | `--size-confirm` | `524288000` | 확인을 요구할 전송량 임계치 |
| `free_space_warn_gib` | `--free-warn` | `20` | 원격 여유 공간 경고 임계치 |

경로 설정은 절대경로여야 하고, 모든 설정값은 셸 메타문자가 섞이면 거부되고 기본값으로 되돌아간다.
설정 파일이 곧 명령 실행 통로가 되지 않게 하기 위해서다.

전역 설정 예시:

```toml
# ~/.config/handoff/config.toml
remote = "workhorse"
deny_extra = "/opt/production,~/.myservice"
```

## 원격 자율 세션의 권한

넘어간 세션은 `--permission-mode bypassPermissions` 로 뜬다. 확인 없이 끝까지 진행하는 것이 이 도구의 요구사항이라 그렇다.
대신 `--settings` 로 별도 설정 파일을 주입해 아래를 차단한다.

- `~/Library/LaunchAgents/**` 의 읽기/편집/쓰기
- **원격 홈 트리 전체**의 읽기/편집/쓰기 (핸드오프 트리는 다른 이름의 심링크라 이 규칙에 걸리지 않는다)
- `deny_extra` 로 지정한 경로
- `launchctl` 실행

이 규칙 목록은 생성과 검증이 같은 함수(`ho_deny_rules`)를 쓴다. 두 곳에 적으면 한쪽만 고쳐져
검증은 통과하는데 실제 규칙은 다른 상태가 만들어지기 때문이다.

**알아둘 것**: 파일 배치 격리는 프로세스 권한 격리가 아니다.
그 거부 규칙이 `bypassPermissions` 에서 무력한 것으로 확인되면 경고만 출력하고 실행을 계속한다(fail-open).
원격이 운영 중인 머신이라면 `deny_extra` 로 지켜야 할 경로를 명시하고, 그래도 남는 위험을 감수할지 판단해야 한다.

## 안전 규칙

이 도구는 rsync `--delete` 로 양방향 파괴적 동기화를 한다. 그래서 봉쇄가 여러 겹이다.

- **리스**: 프로젝트마다 owner 가 local 이거나 remote 다. 원격에 있으면 다시 넘기지 않는다.
- **경로 봉쇄**: 핸드오프 트리 밖 프로젝트, 트리 루트 자체, git 레포가 여러 개인 모음 디렉터리는 전송을 거부한다.
- **실경로 검증**: 원격 트리가 기대한 심링크가 아니거나 대상이 원격 홈이면 중단한다.
- **쓰기 중인 프로세스**: 프로젝트 파일에 쓰기로 열린 파일 기술자가 있으면 중단한다.
  최선 노력이지 보증이 아니다. 열고-쓰고-닫는 순간적인 쓰기는 구조적으로 놓친다.
- **관측 불가 시 fail-closed**: 원격 상태를 판정할 수 없으면 회수하지 않는다. 우회 플래그는 없다.
- **시크릿**: `secrets` 패턴에 걸리는 파일은 회수 직후 원격에서 지운다.
- **세션 단위 훅**: 넘어간 그 세션에서 프롬프트를 제출하면 차단된다. 같은 경로의 다른 세션은 막지 않는다.

## 종료 코드

| 코드 | 뜻 |
| --- | --- |
| `0` | 성공 |
| `1` | 사용 오류 |
| `3` | 사전조건 중단 |
| `4` | 전송 실패. **같은 명령을 다시 실행하면 이어진다** |
| `5` | 리스는 넘어갔지만 원격 pane 기동 실패. 상태는 보존됨 |
| `6` | 정리 부분 실패 |

## 한계

- macOS 전용이다. 경로 규약과 `launchctl` 차단이 macOS 전제다.
- 실행 중인 프로세스는 따라가지 않는다. 파일과 세션만 넘어간다.
- 원격에서 직접 시작한 세션을 로컬로 당겨오는 역방향은 지원하지 않는다. 경로 변환 문제가 되돌아오기 때문이다.
- 홈 설정(`~/.claude/skills` 등)은 동기화하지 않는다.

## 개발

```sh
./tests/syntax.sh   # 문법, 실행 권한, 라이브러리 로드
./tests/run.sh      # 단위/계약 테스트
```

외부 의존성은 없다. bash, python3, rsync, ssh 만 쓴다.
