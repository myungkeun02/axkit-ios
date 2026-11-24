# iOS 앱이 서버에 바라는 것 (PROTOCOL-REQUESTS)

iOS 앱(이 레포)이 쓰는데 ax-kit 서버(`src/channels/app/*`, `src/mobile/app-*.ts`)에 아직 없는 것들입니다.
모두 **v1에 필드·뷰·액션을 더하는 것**이라 `protocol`은 1 그대로입니다. 앱은 `capabilities`에 없는 기능·뷰를 숨기므로
하나씩 넣어도 됩니다. 그 전까지는 `dev/mock-server.mjs`가 아래 모양 그대로 가짜 데이터를 냅니다(목업이 곧 명세 예시).

표기: **[필수]** 화면이 비거나 핵심 흐름이 안 됨 · **[권장]** 없으면 그 화면만 숨김.
ax-hq(§7)에 이미 있는 것은 "ax-hq에 있음"으로 적었습니다 — 같은 모양으로 ax-kit에 옮겨 오면 됩니다.

> **진행 상태 (2026-11-19)**: ax-kit `main`에 **R1–R18이 모두** 들어갔어요(ax-kit `docs/APP-PROTOCOL.md` §8–§14, 앱과 맞는지 확인함). 등급 C, 팀 구성 하네스, 등급표 하네스도 들어갔어요.
> 서버 쪽 차이:
> - 방 id: `team-<이름>`, `meet-<묶음 id>`
> - C에 모델이 없으면 B 모델로 돌아요
> - 맥 상태 네트워크는 Tailscale만
> - 새 기능 화면: '할 수 있는 일', '이번 주 한 일'
> - 녹음 조각 1..64, Drive 카드에 `remember` 없음, 봇 그림은 OpenAI 키가 있을 때만
>
> `team:resize` 제안(resize / keep / later, 줄이면 빠진 봇은 `status:"off"`), 모델 시험 세트(결과는 `models[].note`), 공급자 사이 부하 나누기(`changes` 줄)도 들어갔어요(§15). 앱 쪽에 더 바꿀 것은 없어요.
> 루틴(§17)은 더보기 › 루틴(켜기·끄기·길게 눌러 지우기), 폰으로 받은 파일(§19)은 대화의 파일 줄(눌러서 미리 보기·공유), 파일 변경·알아 둔 방법(§19·§20)은 더보기 › 새 기능에 보여요. 메일 처리(§18)는 알림·결재로만 와요.
> 봇 역할 프롬프트(§16 `instructions`·`instructionsBy`, `setInstructions`)는 팀 설정 › 봇 › 일하는 방식에서 보고 고쳐요.

| # | 무엇 | 앱 화면 | 우선 |
|---|---|---|---|
| R1 | `bots` 뷰 + 이벤트 `channel`/`author` + `POST messages {channel}` | 홈 왼쪽 시트(봇 목록), 봇 방 | 필수 |
| R2 | 이벤트 `delegation` | 홈 대화의 "개발 봇에게 맡겼어요" | 필수 |
| R3 | 카드 `options[]`(+`detail`)·`freeText`·`card-reply` | 결재 탭(객관식 + 직접 입력) | 필수 |
| R4 | `docgraph` 뷰 | 문서 탭(우주·목록·문서 보기) | 필수 |
| R5 | `calendar` 뷰 | 캘린더 탭(일정 + 한 일) | 필수 |
| R6 | `jobs/toggle` 액션 | 더보기 › 반복 작업 켜고 끄기 | 권장 |
| R7 | `providers` 뷰 + `providers/<id>/key`·`disconnect` | 더보기 › AI 연결하기 | 권장 |
| R8 | `usage.byBot`, `hardware` 뷰 | 더보기 › 사용량, 맥 상태 | 권장 |
| R9 | 서버가 그리는 화면(`ui:"blocks"` 뷰) | 더보기 › 새 기능 | 권장 |
| R10 | `status.stopped` | 모든 탭 위 "전체 정지 중" 띠 | 권장 |
| R11 | "앞으로는 알아서" — 카드 `remember` + `autonomy` 뷰 | 결재 카드 체크 + 더보기 › 알아서 하는 일 | 필수(오너 요청) |
| R12 | `modeltiers` 뷰 + `rank`·`purpose` 액션 | 더보기 › AI 등급과 용도 | 권장 |
| R13 | 봇 캐릭터 그림 `avatar`, 상태 `status` | 봇 목록·봇 방(움직이는 캐릭터) | 권장 |
| R14 | 녹음 → 회의록 문서 → Google Drive → 개발 제안 | 홈 마이크·녹음 띠, 더보기 › 녹음과 회의록 | 필수(오너 요청) |
| R16 | 봇 팀 추가(팀장 1·직원 3·개발은 검수 1, 역할별 AI 등급) | 홈 봇 시트 › 팀 추가, 팀 설정 | 필수(오너 요청) |
| R17 | 회사마다 팀장회의 방 + 봇끼리 대화(A2A는 안에서, 보이는 건 쉬운 말) | 봇 시트 › 팀장회의, 팀 방 | 필수(오너 요청) |
| R18 | 맥미니 초기 세팅 CLI 패키징 | – (서버) | 필수(오너 요청) |
| R15 | **같은 질문 다시 묻지 않기** — 카드 `topic` + 답 기억 | 결재 전체 | 필수(오너 요청) |

---

## R1. 봇과 방 (`bots` 뷰, `channel`)

오너가 하는 일(첫 문서 스캔에서 찾은 회사·생활 영역)마다 봇을 묶어 보여 줍니다. 목록은 서버가 정하므로 새 봇은 앱 업데이트 없이 나타납니다.

```
GET views/bots  →  data:
{ main: { name: "비서", subtitle?: "무엇이든 먼저 여기에 말하세요" },
  groups: [ { id, label: "한빛랩", summary?: "앱 만드는 회사", icon?,          // 두 회사를 하면 두 묶음
              bots: [ { id: "dev", name: "개발 봇", role?: "앱·서버 코드를 고쳐요",
                        channel: "dev",                                       // 방 id
                        status?: "idle"|"working"|"waiting"|"off",            // R13
                        statusText?: "로그인 화면 고치는 중",
                        avatar?: "https://…" | "files/<id>",                 // R13
                        isNew?: true } ] } ] }
```
- 이벤트에 `channel?`(없으면 비서 대화)과 봇 글이면 `author: {id, name}` — ax-hq §7.2와 같음.
- `POST messages {text, channel:"dev"}` = 그 봇에게 바로 지시. 없는 방은 `400 shape`. `GET events?channel=` 도 §7.2처럼.
- ax-hq는 `channels` 뷰(평평한 목록)가 이미 있음. 묶음(`groups`)과 `status`만 더하면 같은 화면을 씁니다.
- 뷰가 바뀌면(봇 추가·상태 변화) 앱은 `delegation` 이벤트나 당겨서 새로 고침 때 다시 읽습니다. (선택) `bots_changed` 이벤트를 보내 주면 즉시 갱신.

## R2. 맡김 이벤트 `delegation`

비서가 메인 대화의 요청을 전문 봇에게 넘긴 것을 쉽게 보여 줍니다.
```
{ type: "delegation", seq, at,
  bot: { id: "dev", name: "개발 봇" }, botChannel: "dev",
  task: "로그인 화면이 하얗게 나오는 문제 고치기",
  state: "started" | "done" | "failed",
  summary?: "느린 인터넷에서 글꼴을 기다리던 문제였어요. 고쳤어요.",
  channel?: ""     // 이 줄을 보여 줄 방(기본 비서 대화)
}
```
- 시작할 때 `started`, 끝나면 같은 `task`로 `done`/`failed` 한 번 더. 앱은 한 줄로 "개발 봇에게 맡겼어요 ›"(누르면 봇 방)로 그립니다.
- 모르는 `type`은 옛 앱이 건너뛰므로 안전합니다.

## R3. 결재 카드 = 객관식 + 직접 입력

오너 결정: 결재는 "네/아니요"가 아니라 **"어떻게 할까요?"에 대한 선택지 여러 개**와 **늘 보이는 직접 입력칸**입니다.
- 카드에 `options: [{id, label, tone?: "primary"|"danger"|"neutral", detail?}]` — ax-hq §7.3에 있음. **`detail`(그 선택이 무엇을 하는지 한 줄)은 새 필드.**
  예: `{id:"beans:usual", label:"늘 사던 커피상회에서 5kg", detail:"14만 5천원 · 금요일 도착", tone:"primary"}`
- 오너 결정(3차): 결재 카드에 보이는 것은 **맥락(`note`) → 질문(`summary`) → 선택지 이름** 셋뿐입니다. `amount`·`detail`·봇 이름·마감은 그리지 않습니다.
  - `note` = **육하원칙 맥락 1~2문장**: 누가(요청한 사람·봇), 언제, 무엇을, 왜, (필요하면) 어디서·얼마.
  - **사람이 읽는 문장으로 써 주세요.** `누가: … 언제: … 어디서: …`처럼 항목 이름을 붙여 자르거나 `· 대상:` 같은 목록으로 보내지 않습니다. 예: "Mia가 오늘 아침 팀장회의에서 정한 이번 달 개발 순서예요. 개발팀은 한 번에 하나만 할 수 있어서, 고른 것부터 Leo 팀이 시작해요."
    예: "거래처 김대리님이 오늘 오전에 11월 납품 견적을 오늘 안에 보내 달라고 했어요. 견적서(1,240만원)는 문서에 준비돼 있어요."
  - `summary` = 짧은 질문 하나: "어떻게 보낼까요?"
  - 선택지 `label`은 그것만 봐도 알 수 있게 핵심을 담아 주세요("커피상회 5kg (14만 5천원)"). 추천은 `tone:"primary"`(채운 색), 하지 않기는 `tone:"danger"`(빨강).
- `POST cards/<id> {option}` / `{text}` → `{state, reply?}`, `card_closed.answer` — ax-hq §7.3(`card-reply`)과 같게. 기능 이름 `card-options`, `card-reply`.
- 버튼만 받는 카드는 `freeText:false`.
- (선택) `amount: {value, currency}`·`merchant` — 결제 카드에서 금액을 한 줄로 보여 줌.
- 현재 ax-kit 서버(카드 = 승인/거절/고치기)에서도 앱은 동작합니다: `options`가 없으면 "네, 해 주세요 / 고쳐서 다시 / 아니요"를 그리고,
  `card-reply`가 없으면 직접 입력은 `{decision:"edit"}` + 같은 방에 `"[결재 답: <요약>] <글>"` 메시지로 보냅니다(글이 사라지지 않게).

## R4. 문서 지도 `docgraph` 뷰

구조화 문서(첫 스캔 + 대화에서 배운 것)를 점·선으로(우주 보기) 또 층별 목록으로 보여 줍니다.
```
GET views/docgraph → data:
{ layers: [ { id: "company", label: "회사", summary?: "회사마다 하는 일" }, … ],
  nodes:  [ { id, title, layer, group?: "hanbit",      // group = 같은 회사/영역끼리 모여 보이게
              summary?, updatedAt?, weight?: 1..4 } ],  // weight = 점 크기(중요도·링크 수)
  links:  [ { from, to, label? } ] }

GET views/docgraph?doc=<id> → data: { document: { id, title, layer?, markdown, updatedAt?, related?: [{id, title}] } | null }
```
- 배치는 앱이 함(결정적 force layout). 서버는 좌표를 보내지 않아도 됩니다.
- 고치기는 뷰 액션 대신 대화로 보냄("[문서 고치기: 제목] …"). 원하면 `knowledge/correct`처럼 `docgraph/correct {id, text}`를 나중에.
- ax-hq: graph_nodes/edges를 이 모양으로 내보내면 같은 화면.

## R5. 캘린더 `calendar` 뷰 (일정 + 한 일)

```
GET views/calendar?month=YYYY-MM → data:
{ month, timezone?,
  days: [ { date: "YYYY-MM-DD",
            events: [ { id, title, start, end?, allDay?, place? } ],
            done:   [ { id, title, at, bot?: {id, name}, detail? } ] } ] }   // 한 일 = 봇·비서 작업 기록
```
- 그달의 모든 날을 넣어 주세요(비어도).
- 일정 추가(오너 요청): 액션 `add` — `POST views/calendar/add {title, allDay, start, end?, place?}`
  (`allDay`면 `start`는 `YYYY-MM-DD`, 아니면 ISO 시각; `end ≥ start`) → `{id}`. 오너 자신의 캘린더에 쓰는 되돌릴 수 있는 `write`.
  다른 사람을 초대하는 일정(보내기)은 앱에서 만들지 않고 대화·결재로. `done`은 작업 기록(ax-hq org_tasks, ax-kit 감사 기록·잡 실행)에서.

## R6. 반복 작업 켜고 끄기

`jobs` 뷰(§7.8)에 액션 `toggle`: `POST views/jobs/toggle {id, enabled}` → `{id, enabled}`.
- 잡 항목에 `toggleable?: false`(launchd·GitHub 등 보기만)면 앱이 스위치를 숨깁니다. 없으면 `source:"ax"`만 켜고 끔.
- 새 반복 작업은 앱에서 만들지 않음 — 비서에게 말로 부탁(오너 결정).

## R7. AI 연결하기

```
GET views/providers → data:
{ providers: [ { id: "deepseek", label: "DeepSeek",
                 kind: "api_key" | "subscription" | "local",
                 connected: bool, status?: "ok"|"error"|"off", detail?: "잘 되고 있어요",
                 keyHint?: "…a91", help?: "platform.deepseek.com 에서 키를 만들 수 있어요.", models?: [..] } ] }

POST providers/<id>/key        {apiKey}  → {ok:true}     // 맥 Keychain에만 저장, 다시 돌려주지 않음
POST providers/<id>/disconnect {}        → {ok:true}     // 키 지우기
```
- **뷰 액션이 아닌 별도 경로**로 둔 이유: 비밀값이 뷰 응답·로그·감사 기록 본문에 섞이지 않게. 서버는 키를 기록하지 말고 `keyHint`(끝 3자)만.
- 키 확인(작은 호출 1번) 후 `status`를 채워 주면 좋음. `subscription`(Claude Code 로그인 등)·`local`(Ollama)은 앱에서 설명만.

## R8. 사용량(봇별)·맥 상태

- `usage`(§5.2)에 `byBot: [{botId, name, calls, costUsd}]` 추가.
- `GET views/hardware`:
```
{ checkedAt, machine: { name, model?, os?, uptimeSec? },
  cpuPercent?, memory?: {used, total, unit:"GB"}, disk?: {used, total, unit:"GB"},
  thermal?: "nominal"|"fair"|"serious"|"critical", power?: "전원 연결됨",
  network?: { tailscale: "연결됨 (mac-mini)", internet: "좋음" },   // 키·값 모두 사람이 읽는 글
  server?:  { version: "ax-kit 0.9.0", uptime: "3일 2시간", stop: "켜짐" },
  summary?: "맥미니가 건강해요. 저장 공간도 넉넉해요." }
```
  앱은 15초마다 다시 읽습니다(화면이 열려 있을 때만).

## R9. 서버가 그리는 화면 (`ui:"blocks"`)

에이전트가 새 능력을 얻을 때 앱 업데이트 없이 화면이 생기게 합니다.
- `capabilities.views[]` 항목에 `title`, `icon`(SF Symbol 이름), `ui: "blocks"`를 더하면 앱이 더보기 › **새 기능**에 줄을 만듭니다.
- `GET views/<name>` → `{ title, blocks: [ … ] }`, 블록:
  `{kind:"text", text}` · `{kind:"stat", title, value}` · `{kind:"list", title?, rows:[{title, detail?, trailing?}]}` · `{kind:"note", text}` ·
  `{kind:"ask", title, message}` — `ask`는 **대화에 `message`를 보낼 뿐**(효과 있는 일은 늘 비서·결재를 거침).
- 모르는 `kind`는 앱이 건너뜀.

## R10. 전체 정지 스위치 상태

`GET status`에 `stopped: bool`. 켜져 있으면 앱이 홈·결재 위에 "전체 정지 중이에요. 보내기·결제·삭제는 맥에서 막혀 있어요." 띠를 보입니다.

## R11. "앞으로는 알아서" (결재 줄이기) — 오너 요청

오너: "AI가 최대한 알아서 일해야 한다. 결재를 자주 받으면 안 된다. 처음 한 번 결재하면서 '앞으로는 알아서 할까요?'를 물어보자."
- 카드에 `remember?: { label, detail? }` — **서버가 문구와 범위를 정함**. 예:
  `{label:"앞으로 15만원 이하 원두 주문은 알아서 할게요", detail:"늘 사던 곳·같은 원두일 때만. 주문하면 알려 드려요."}`
- 앱이 체크하고 고르면 `POST cards/<id> {option, remember:true}`. 서버는 고른 선택지 + 범위로 **상설 규칙**을 만들고, 같은 종류의 다음 일은 카드 없이
  하고 끝나면 알림(캘린더 '한 일'에도). 거절(`danger`)·직접 입력에는 `remember`를 붙이지 않습니다.
- 확인 정책과의 관계: 보내기·결제·삭제 같은 효과도 **오너가 이 체크로 만든 규칙의 범위 안에서만** 자동이 됩니다(금액 상한·받는 사람·가맹점 등 서버가 `label`에 적은 그대로).
  범위를 벗어나면 다시 카드. 전체 정지 스위치는 규칙보다 우선.
- `GET views/autonomy` → `{ rules: [{id, label, detail?, since?, uses?}], alwaysAsk?: ["처음 보는 사람에게 보내기", …] }`,
  `POST views/autonomy/revoke {id}` → 그 규칙 삭제(다음부터 다시 묻기).

## R12. AI 등급과 용도

오너: "클로드·지피티를 연결했을 때 각각 어떤 용도로 쓰는지 설정이 필요하고, 모델마다 랭크 시스템이 필요하다."
```
GET views/modeltiers → data:
{ tiers: [ { id: "S", label: "S 등급", summary?: "가장 똑똑해요 · 비싸요",
             models: [ { id, label, provider, note?, available?: false } ] } ],   // 위에서부터 먼저 씀
  purposes: [ { id: "dev", label: "개발 봇", detail?, tier: "S", calls7d? } ] }

POST views/modeltiers/rank    {tier, order: [model id…]}   // 등급 안 순서 바꾸기(같은 모델 집합이어야 함)
POST views/modeltiers/purpose {id, tier}                    // 용도마다 등급 정하기
```
- ax-kit `models` 뷰(§5.8, deep/standard/fast)와 ax-hq `models`(§7.10, S/A/B/C)가 읽기 전용으로 비슷한 것을 이미 냄. 쓰기 두 개를 더하고
  설정 `llm.routes`에 저장하면 됩니다. 용도 목록은 봇(R1)도 포함.

## R13. 봇 캐릭터

오너: 봇마다 3D 캐릭터 이미지, 일할 때 움직이게.
- `bots[].avatar`: 캐릭터 그림(정사각 PNG, 512px 권장). 맥이 봇을 만들 때 이미지 모델로 생성해 `files/<id>`(토큰 필요, 앱이 받아 캐시) 또는 https로.
- `bots[].status:"working"`이면 앱이 캐릭터를 통통 튀게 움직임(동작 줄이기 설정이면 멈춤). 그림이 없으면 앱이 이름으로 정한 둥근 캐릭터를 그림.
- (선택) 나중에 움직이는 그림(APNG/Lottie)을 `avatarAnimated`로.

## R14. 녹음 → 회의록 → Google Drive → 제안 — 오너 요청

오너: "녹음 내용 기반으로 자동으로 문서가 만들어지고 Google Drive에도 저장되고, 이 문서 기반으로 '뭔가 개발해 볼까요?' 같은 제안도."
앱은 AAC 모노 16kHz·24kbps(시간당 약 11MB)로 녹음해 **4MB 조각**으로 올립니다(12MB 업로드 상한 아래, 끊기면 이어서).

- 기능 `recordings`와 뷰 `recordings`를 `capabilities`에 넣으면 앱이 홈 마이크 버튼·더보기 › 녹음과 회의록을 보입니다.
- `POST recordings/<id>/chunks/<index>` — 본문 = 오디오 바이트(`Content-Type: audio/mp4`), 헤더 `X-Chunk-Total`, `X-Started-At`(ISO), `X-Duration-Sec`.
  `<id>`는 앱이 만든 `r_[a-z0-9-]{1,40}`. 응답 `{received, complete}` — `received` = 0번부터 빠짐없이 받은 조각 수(앱은 여기서부터 이어 보냄),
  `complete` = 다 받음. 같은 조각을 다시 보내도 됨(덮어쓰기). 다 받으면 서버가 처리 시작. 녹음 하나는 2시간(약 22MB, 6조각)까지 권장.
- `GET views/recordings` → `{recordings:[{id, title?, startedAt, durationSec, status:"receiving"|"transcribing"|"summarizing"|"done"|"failed", statusText?, documentId?, driveUrl?}]}` (최신순).
- 처리(서버):
  1. 받아쓰기(로컬 Whisper 또는 연결된 AI, 등급표 R12의 용도 `transcribe`) → 요약(누가·언제·정한 것·할 일, 육하원칙) → 구조화 문서 하나(`docgraph` 노드, 관련 회사·사람·프로젝트 문서와 링크).
     원본 오디오·전문은 맥에만. 채팅에는 "회의록을 정리했어요: <제목>" 한 줄.
  2. Google Drive 저장: **처음 한 번만** 결재 카드(`topic:"drive:save:meeting-notes"`, 폴더 선택지, `remember` 제안). 승인·규칙이 있으면 이후엔 묻지 않고 저장 후 알림 한 줄.
     Drive 연결은 맥에서(OAuth 토큰은 맥 Keychain). Drive가 연결 안 됐으면 카드 대신 "Drive를 연결하면 저장할 수 있어요" 알림 한 번.
  3. 제안: 회의록에서 할 만한 일이 보이면 결재 카드(맥락 = 어느 회의에서 무슨 말이 나왔는지, 질문 = "이걸로 개발해 볼까요?", 선택지 = 봇에게 맡기기·설계만 먼저·나중에·안 함).
     `topic`은 **아이디어 키**(R15). 맡기면 `delegation` 이벤트(R2)로 해당 봇에게.
- 앱은 업로드가 끝난 녹음 파일을 아이폰에서 지웁니다.

## R15. 같은 질문을 다시 묻지 않기 — 오너 요청

오너: "같은 질문을 여러 번 하게끔 하면 절대 안 됨."
- 카드에 `topic?: string` — 무엇에 대한 질문인지의 안정된 키(예: `drive:save:회의록`, `dev:suggest:<문서 id>`, `order:beans`).
  문구가 달라도 같은 결정이면 같은 `topic`.
  제안은 **문서가 아니라 아이디어**로 키를 잡습니다(`dev:suggest:payment-export`): 회의 두 번에서 같은 말이 나와도 한 번만 제안.
- 서버는 `topic`별로 오너의 마지막 답을 기억하고(거절·"나중에"·직접 입력 포함), **같은 `topic`의 카드를 다시 열지 않습니다.**
  - 승인·선택 → 그 답대로 처리. 같은 일이 또 생기면 `remember` 규칙(R11)이 있으면 그대로, 없으면 이전 답을 따르고 알림만.
  - 거절 → 근거(문서·금액·받는 사람 등)가 실제로 바뀌기 전에는 다시 제안하지 않음.
  - "나중에" → 오너가 정한 때(또는 기본 다음 날 아침 브리핑) **한 번만** 다시 꺼냄.
  - 열린 카드가 있는 `topic`으로 또 물어야 하면 새 카드 대신 같은 `cardId`로 내용을 갱신(§7.3처럼 같은 id 재전송).
- 앱도 막습니다: 열린 카드 중 `topic`(없으면 맥락+질문 글)이 같은 것은 가장 새 것 하나만 결재 탭·대화에 보입니다.


## R16. 봇 팀 추가 — 오너 요청

오너: "봇을 추가할 때는 어떤 봇이든 시스템상 구조가 팀장 봇 1, 하위 직원 봇 3, 개발 쪽은 검수 봇 1. 모델은 직원 B–C, 팀장 A, 검수 S처럼 본인이 원하는 대로 지정 가능해야 한다. 자동으로 생기는 봇은 알아서."
- `views/bots`에 더함(모르는 필드 무시라 호환):
  - `groups[].meetingChannel?` (R17)
  - `groups[].teams?: [{id, name, purpose?, channel, kind?:"dev"|"general", members:[botId…]}]`
  - `bots[].rank?: "lead"|"staff"|"reviewer"`, `bots[].team?`, `bots[].tier?: "S"|"A"|"B"|"C"`
- 기능 `bot-teams`, 뷰 액션:
  - `POST views/bots/createTeam {group | newGroupLabel, name, purpose?, kind:"dev"|"general", staffCount 1..6, reviewerCount 0..3, tiers:{lead, staff, reviewer?}}` → `{teamId, channel}`
    - `group`이 없으면 `newGroupLabel`로 새 묶음(회사)을 만듦
    - 인원과 등급은 **오너가 처음부터 직접 정함**. 앱 기본값은 직원 3, 개발팀이면 검수 1, 팀장 A·직원 B·검수 S
    - 또는 `{…, auto:true}` = AI에게 맡기기(아래 하네스)
    - 봇 이름·역할 문구는 서버가 정함("디자인 팀장", "디자인 직원 1"…)
  - `POST views/bots/setTiers {teamId, tiers:{lead?, staff?, reviewer?}}` → 역할별 등급 바꾸기(R12 등급표의 S/A/B/C)
- `views/bots` 팀 항목에 `decidedBy?: "owner"|"ai"`, `reason?`.
- **팀 구성 하네스(오너 요청)**: 자동으로 생기는 팀(문서 스캔·대화에서 "이런 팀 필요해")과 `auto:true`는 AI가 구성을 정함.
  1. 입력: 팀이 할 일(`purpose`), 예상 일의 양·난이도, 위험도(코드·돈·대외 발송이면 검수 필요), 최근 7일 사용량과 예산
  2. 출력: 구조화된 JSON `{staffCount 1..6, reviewerCount 0..3, tiers{lead,staff,reviewer}, reason}`
     - 규칙으로 검증: 범위 밖이면 고침. 코드·결제·대외 발송을 다루면 검수 ≥ 1, 검수 등급 ≥ 팀장 등급. 예산을 넘으면 한 단계 낮춤
  3. 결과를 팀에 `decidedBy:"ai"`, `reason`(쉬운 말 한 줄)으로 저장
     - 앱의 팀 설정 맨 위에 "AI가 정한 구성이에요 — <reason>"이 보임
     - 오너가 바꾸면 `decidedBy:"owner"`, 그 뒤로 AI가 다시 바꾸지 않음
  4. 운영 중 조정(선택): 일이 계속 밀리거나 실패가 잦으면 구성 변경을 **결재로 한 번 제안**(R15 `topic: team:resize:<id>`)

## R17. 팀장회의 방과 봇끼리 대화 — 오너 요청

오너: "회사마다 팀장회의 채널이 있어서 팀장 봇들끼리 회의 가능해야(디스코드에서 쓰던 것). 각 봇 채널 안에서는 서로 대화하는 것 같은 UI. 내부적으론 A2A, 보이는 건 누구나 이해하기 쉬운 말."
- 묶음(회사)마다 방 하나: `groups[].meetingChannel`(예 `meeting:hanbit`). 오너는 `POST messages {channel}`로 끼어들 수 있고, `POST views/bots/meeting {group, topic}`으로 회의를 열 수 있음.
- 팀 방(`teams[].channel`)과 회의 방에 봇끼리 주고받는 말을 `message` 이벤트로 올림:
  - `author {id, name}`, 그리고 새 필드 `to?: {id, name}`(누구에게 한 말인지)
  - `text`는 사람이 읽기 쉬운 한두 문장으로 서버가 바꿔 씀. A2A 원문(JSON·도구 호출)은 앱에 보내지 않음.
  - 회의가 끝나면 비서 대화에 "한빛랩 팀장회의 결론: …" 한 줄.

## R18. 맥미니 초기 세팅 CLI — 오너 요청

오너: "에이전트 기능 전반이 안 보인다. 초기 세팅을 CLI로 편하게 할 수 있게 패키징."
- 명령 하나로 설치 → 대화형 세팅(`ax-kit setup`). 이미 한 단계는 건너뛰고 몇 번 실행해도 안전.
- 다루는 것:
  - AI 연결(키는 Keychain)
  - 등급표 기본값
  - 캘린더(쓰기 포함)·Google Drive·메일 연결
  - 받아쓰기 엔진(로컬 Whisper 등)
  - APNs 키
  - Tailscale
  - 앱 짝 맞추기 QR
  - launchd 상시 실행
  - 첫 문서 스캔 → 회사별 묶음·팀 자동 생성(R16)
- 끝에 "켜진 기능 / 꺼진 기능과 켜는 법" 표.
  앱은 `capabilities`에 있는 것만 보이므로, 이 표가 "앱에 왜 안 보이는지"의 답이 됨.
- 배포: `brew install`이나 `npm i -g` 중 쉬운 것, 업데이트는 `ax-kit update`.

---

## 확인한 것 / 남은 것
- 앱·목업은 위 모양으로 동작 확인(시뮬레이터, `docs/screenshots/`). 실제 ax-kit 서버와는 오늘 있는 것(chat·cards 승인/거절·events·stream·today·usage·spending·jobs·models)만 맞물립니다.
- 푸시(§7.7)는 이번 앱에 아직 넣지 않았습니다(서버는 준비됨). 다음 단계: `push/register` + 알림의 결재 버튼.

## 2026-11-20 앱이 맞춘 것과 서버에 남은 바람 (APP-PROTOCOL §21)

앱이 맞춘 것: `thread`(첫 줄 아래 답글로 접기), `reaction`·`read` 이벤트, `POST read`(read-sync), `views/knowledge?q=` 검색(결과 먼저, 앱이 읽은 문서로 보탬),
`views/channels`의 `group`·`lead`. 옛 `notice`와 "💬 A → B · …" 머리말, 디스코드 문법·내부 id·`key: value` 메타데이터·`<knowledge_…>` 맥락은 앱이 그려도 안 깨지게 정리함.
읽기 전용 알림 채널(결재·브리핑·장애·로그·알림)은 오너 요청으로 방 목록에 넣지 않음(결재는 결재 탭에서).

서버에 바라는 것:
- `views/knowledge?doc=` 응답의 `document`에 `id`도(지금은 `name`만 — 앱은 둘 다 읽음).
- `views/health`의 `summary`가 문장이면 좋겠음(지금은 `{ok,warn,fail}` 숫자 — 앱이 직접 문장을 만듦), 상태 `fail` 대신 `error`.
- 브리핑·장애처럼 읽기 전용 방의 글을 오너가 꼭 봐야 하면 비서 대화(`channel` 없음)로도 한 줄 보내 주기(앱은 그 방을 목록에서 뺐음).
- `views/docgraph`의 `tree`는 다음 앱 업데이트에서 관련 항목 칩으로 씀(지금은 문서 화면의 '관련 문서').

## 2026-11-20 §17·§19·§20·§22 (서버 a1ac844)

앱이 맞춘 것: §22 브라우저 화면 넘겨받기(`views/browser-live`·`start`·`tap`·`type`·`key`·`scroll`·`back`·`done`, `browser-live/stream`, 안 되면 `browser-live/frame` 2초마다),
대화에 "앱의 브라우저 화면…" 문장이 오면 '브라우저 화면 열기' 버튼, 더보기 › 비서가 챙기는 것 › 브라우저 화면 넘겨받기. §17 루틴·§16 봇 일하는 방식(400 `message` 그대로)·§19 첨부 파일(30일)·
`file-changes`·`ways`(블록 화면, 새 기능 칸에 저절로)는 이미 있던 화면으로 맞음.

서버에 바라는 것:
- `ways`에 사이트 지우기 액션(예: `POST views/ways/forget {host}`). 지금 앱은 사이트를 길게 누르면 "…는 이제 잊어 줘"를 대화로 보내 `ways.forget_site`가 돌게 함.
- 블록 `list` 줄에 `id`가 있으면 앱이 줄마다 액션을 붙이기 쉬움.
