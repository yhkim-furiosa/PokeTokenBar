---
summary: "Kubernetes Pod 의 Claude Code·Codex 사용량을 로컬 미러로 가져오는 스크립트 — Pod 안에서 usage 레코드만 추출하는 이유, 미러 보관 정책, 주기 실행 방법."
read_when:
  - 원격 Pod 사용량 동기화 스크립트(`scripts/sync-k8s-*.sh`)를 고치거나 새 프로바이더용을 추가할 때
  - 미러 용량·전송량·대화 내용 유출 범위를 판단해야 할 때
  - 원격 사용량이 앱에 안 잡히거나 동기화가 실패할 때
---

# 원격 Kubernetes Pod 사용량

Pod 안에서 쓴 Claude Code·Codex 토큰을 노트북 메뉴바에서 로컬 사용량과 함께 보기 위한
스크립트. Pod 의 세션 로그에서 **usage 레코드만** 뽑아 로컬 스캔 폴더로 미러링한다.

```bash
./scripts/sync-k8s-claude.sh --pod my-pod --configure
./scripts/sync-k8s-codex.sh  --pod my-pod --configure
```

첫 `--configure` 뒤에는 PokeTokenBar 를 재시작한다.

## 클러스터 경계를 넘는 것은 무엇인가

`LocalUsageReader` 가 실제로 파싱하는 필드뿐이다. 프롬프트·툴 출력·파일 내용은
tar 스트림을 만들기 **전에 Pod 안에서** 버린다.

| 프로바이더 | 남기는 것 | 거르는 도구 |
|---|---|---|
| Claude Code | `type`, `timestamp`, `requestId`, `message.{id,model,usage}` | `jq` |
| Codex | `session_meta`·`turn_context`(모델명)·`token_count` 레코드를 필드 단위로 재구성 | `jq` |

전송량만의 문제가 아니다. 세션 로그를 통째로 미러링하면 프롬프트와 붙여넣은 소스코드 전문이
다른 기기로 복사된다. 업무 코드라면 대개 이쪽이 더 큰 문제다.

Claude 로그 118 MB, Codex rollout 81 MB 인 개발 Pod 에서 실측한 값:

| | 원본 파일 미러 | usage 만 추출 |
|---|---|---|
| 최초 전체 전송(gzip) | 42.8 MB | **0.6 MB** |
| 가장 큰 세션 1개 전송 | 23.0 MB | **23 KB** |
| 로컬 미러 디스크 | 228 MB | **11 MB** |
| 노트북으로 복사되는 대화 내용 | 전부 | **없음** |
| 주기당 Pod CPU | ~0 | ~0.1 s |

추출 비용은 싸다. 118 MB Claude 트리 **전체**에 `jq` 를 돌려도 1 코어 1.34 s, 81 MB Codex 트리는
0.73 s 이고, 매 주기에는 마지막 성공 이후 수정된 파일만 훑는다.

집계 결과가 같다는 것은 확인했다 — Claude 일간 합계가 전체 미러와 동일하고,
Codex 오늘 `token_count` 합계도 필터 교체 전후로 동일(3,425,152)했다.

**필드 단위 재구성이어야 하는 이유.** 처음에는 Codex 를 `grep -E 'session_meta|"model"|token_count'`
로 걸렀다. 부분 문자열 매칭이라 그 문자열이 *내용에* 들어 있는 줄까지 통째로 통과한다 — 실측 1,472 줄이
새어 나왔고, 사용자 프롬프트·어시스턴트 메시지·툴 출력·`world_state` 의 AGENTS.md 전문이 들어 있었다.
지금은 JSON 타입으로 고르고 필요한 필드만 다시 조립한다. "대화 내용은 나가지 않는다" 가 희망이 아니라
사실이 되려면 이 방식이어야 한다.

## 동작

1주기는 `kubectl exec` **한 번**이다. Pod 측 프로그램이 마지막 동기화 이후 수정된 세션을 거르고,
현재 존재하는 세션 전체의 manifest 를 만들어 함께 tar 로 내보낸다.

```
kubectl exec ──► sh (필터 + manifest) ──► tar -czf - ──► 로컬 staging ──► rsync ──► 미러
```

manifest 가 정합성을 맡는다. Pod 에서 지워지거나 옮겨진 세션은 로컬 사본도 지워지므로
낡은 파일이 이중 집계되지 않는다. 다만 **빈 manifest 는 "전부 지워졌다" 로 해석하지 않는다** —
그렇게 하면 원격의 일시적 문제 한 번으로 미러 전체가 복구 불가능하게 날아간다. 스캔 디렉터리가
아예 없으면 주기를 실패시키고, 세션이 0 개인 정상 상태면 삭제 단계만 건너뛴다. 추출된 파일은 **원본 mtime 을 승계**한다(`touch -r`) —
앱의 증분 파싱 캐시와 로컬 보관 정리가 둘 다 mtime 을 기준으로 삼기 때문이다.

스캔 루트는 프로바이더마다 모양이 다르고, 스크립트가 각각 맞는 값을 등록한다.

| 프로바이더 | defaults 키 | 스캔 루트 |
|---|---|---|
| Claude Code | `customScanRoots.claude_code` | 미러된 `projects` 디렉터리 자체 |
| Codex | `customScanRoots.codex` | `sessions/` 를 담은 미러 루트 |

## 미러 용량 상한

미러는 Pod 의 전체 이력이라 쓸수록 쌓인다(위 실측 기준 작업일당 약 2 MB).
`--retain-days N` 은 N 일 지난 미러 세션을 지운다.

```bash
./scripts/sync-k8s-claude.sh --pod my-pod --retain-days 90
```

정리된 파일은 다시 받아오지 않는다 — 증분 필터가 마지막 동기화 이후 수정된 세션만 보내기
때문이다. 90 일이면 미러가 무한히 자라는 대신 일정 크기에서 안정화된다. 앱이 보여주는 것은
오늘·5시간·주간·월간이라 더 오래된 세션은 필요 없다. 기본값 `0` 은 전체 보관.

**Codex 는 나이만으로 지우면 안 된다.** `expandCodexParentClosure` 가 fork 의 부모 체인을 파싱
대상에 끌어오고, 부모를 못 찾으면 `resolveCodexRollouts` 가 휴리스틱 replay count 로 후퇴한다 —
최근 fork 의 오래된 부모를 지우면 그 fork 의 토큰 수가 조용히 달라진다. 그래서 Codex 정리는
보관 대상 세션의 **조상을 나이와 무관하게 남긴다**(부모 링크를 고정점까지 따라간다).

## 주기 실행

`--watch` 는 스크립트를 상주시킨다. 노트북에서는 단발 실행을 주기적으로 도는 쪽이 대개 낫다 —
1주기가 0.5 초 남짓이고, 실패가 상주 프로세스에 남는 대신 다음 실행에서 복구되며,
kubectl 자격증명을 매번 새로 읽어 재인증이 바로 반영된다.

launchd 라면 `StartInterval` 을 쓴다(cron 과 달리 슬립 중 놓친 실행을 깨어날 때 1회 보충한다).

```xml
<key>ProgramArguments</key>
<array>
    <string>/bin/bash</string>
    <string>/path/to/scripts/sync-k8s-claude.sh</string>
    <string>--pod</string><string>my-pod</string>
    <string>--retain-days</string><string>90</string>
</array>
<!-- launchd 는 최소한의 PATH 만 넘긴다 — kubectl·rsync 를 찾을 수 있어야 한다. -->
<key>EnvironmentVariables</key>
<dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
</dict>
<key>StartInterval</key><integer>1800</integer>
<key>RunAtLoad</key><true/>
```

동기화 주기와 앱 새로고침 주기는 별개이고 직렬로 합쳐진다 — Pod 에서 쓴 사용량은
최대 (동기화 주기 + 앱 새로고침 주기) 뒤에 화면에 나타난다.

## 공식 5시간/주간 한도는 동기화가 필요 없다

한도는 계정 단위이고 `api.anthropic.com/api/oauth/usage` 와 `codex app-server` 가 알려준다.
Pod 사용량은 이미 거기 포함돼 있다. 미러가 필요한 것은 토큰 수·비용·companion 뿐이다.
단, Codex 한도는 노트북에서 `codex login` 이 되어 있어야 한다 — 노트북에서 Codex 를
실제로 쓰지 않더라도 마찬가지다.

## 요구사항과 한계

- Pod: `jq`(양쪽 프로바이더 모두 필요 — 대부분의 개발 이미지에 있다), `find`·`tar`.
  없으면 동기화는 조용히 빈 미러를 만드는 대신 exit 127 로 실패한다.
- 노트북: `kubectl`·`rsync`.
- RBAC: 지정한 Pod 에 대한 `exec`. `list pods` 는 필요 없다 — `--pod` 로 직접 지정하면 된다.
- kubectl 자격증명이 만료되면 동기화가 실패하고 로그에만 남는다. 공식 한도는 계속 동작하므로,
  증상은 "원격 토큰 수만 늘지 않는 것"으로 나타난다.
- 실험적 기능이고, `--configure` 는 `defaults` 를 쓰므로 macOS 전용이다.
