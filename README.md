# ax-kit iOS 앱

서버는 [ax-kit](https://github.com/myungkeun02/axkit) 레포에 있어요(앱 프로토콜: `docs/APP-PROTOCOL.md`). 맥 데스크톱 앱은 `ax-kit-desktop` 레포.

집 맥에서 도는 ax-kit 비서와 이야기하는 아이폰 앱입니다. SwiftUI, iOS 17+, 아이폰 우선.

| 탭 | 하는 일 |
|---|---|
| 홈 | 비서와 대화. 왼쪽 방 목록은 회사별 최근 활동 순(마지막 글·안 읽은 점), 방 안은 그룹 대화처럼(작성자·답글 접기·날짜 줄). 맥이 받아쓰기(§30)를 알리면 입력칸 오른쪽 마이크로 **말로 입력**: 누르면 녹음(소리 크기 막대), 다시 누르면 맥이 글로 바꿔 입력칸에 넣어요(자동으로 보내지 않음, 최대 3분, 1초 미만·무음은 보내지 않음, 녹음은 바로 지움). 비서나 봇이 뒤에서 하는 일이 있으면 입력칸 위에 **하는 중 N개 · 맨 위 항목** 한 줄이 보이고, 누르면 아래에서 **작업 시트**(§31)가 올라와요: 하는 중(하위 작업은 맡긴 일 아래 들여쓰기)과 최근 끝난 5개, 누르면 그 일을 맡은 봇 방이나 비서 대화로 가요. 메인 대화에서 `@`를 치면 봇 이름이 떠서 골라 넣을 수 있어요. 화면을 오른쪽으로 밀면(또는 왼쪽 위 버튼) 뒤에 깔린 **봇 목록 시트**가 나와요. 회사·생활 영역별로 묶인 봇에게 바로 지시할 수 있어요. 비서가 봇에게 맡기면 "개발 봇에게 맡겼어요 ›" 한 줄이 생겨요. |
| 결재 | 비서·봇이 물어본 것. "어떻게 할까요?" 객관식 + 늘 보이는 직접 입력칸, "앞으로는 알아서" 체크. |
| 문서 | 최근 고친 문서와 분야별 목록(분야 → 문서). 찾기는 제목·분야·내용까지, 띄어쓰기 무시·첫소리(ㄱㅈ)로도, 찾은 곳 표시. |
| 캘린더 | 일정(파랑)과 비서·봇이 한 일(초록)을 한 달력에. |
| 더보기 | 설정 및 연결, **녹음해서 회의록 만들기**(녹음 → 맥이 받아 적고 회의록 문서로 → Drive 저장은 처음 한 번만 물음 → 할 만한 일은 결재로 제안), 알아서 하는 일, 반복 작업, 지출 관리, 봇·AI 사용량, AI 연결하기, AI 등급과 용도, 맥 상태, 서버가 보낸 새 기능. |

오른쪽 위 버튼은 탭마다 달라요: 홈 **오늘**(오늘 일정·할 일·결재 수), 결재 **자동 승인**(묻지 않고 하는 일 목록), 문서 **찾기**, 캘린더 **오늘로**·**＋(일정 추가)**. 설정은 더보기 맨 위, 연결이 끊기면 홈 위에 띠가 떠요.

봇 캐릭터: 매끈한 점토 덩어리에 눈만 있어요. 표정은 눈 모양(평소 ●●, 기쁨 ^^, 집중 ><, 걱정, 졸림 ‒‒ + z), 일할 땐 통통 튀어요. 서버가 `avatar` 그림을 보내면 그걸 써요.

스크린샷: `docs/screenshots/`.

## 구조

```
ax-kit-ios/
  project.yml                 XcodeGen 설정 (AxKit.xcodeproj는 만들어 쓰고 커밋하지 않음)
  Config/Base.xcconfig        번들 id·팀 기본값. 내 것은 Config/Local.xcconfig(커밋 안 함)
  AxKit/                      앱 (App: 상태·연결, Screens: 탭 화면, Design: 공용 모양)
  Packages/AxKitCore/         핵심 로직 Swift 패키지 + 테스트
     Events / APIClient / EventStream(SSE) / Timeline / Outbox / Pairing / CredentialStore(Keychain) / Views / GraphLayout / Format
  dev/mock-server.mjs         가짜 맥 (의존성 없음, Node만)
  PROTOCOL-REQUESTS.md        앱이 서버에 바라는 것 (R1~R13)
```

- 토큰(기기 토큰, Cloudflare Access 서비스 토큰)은 **키체인에만** 저장합니다(이 기기 전용, 첫 잠금 해제 후).
- 오프라인에 쓴 메시지는 `Outbox`가 파일에 두었다가 연결되면 순서대로 보냅니다(`clientId`로 중복 없이). 인증번호처럼 보이는 글은 10분 지나면 버립니다.
- 스트림(`GET stream`)은 앱이 앞에 있을 때만 열고, 끊기면 2초부터 60초까지 늘려 가며 다시 붙고, 돌아오면 `events?after=`로 빈 곳을 채웁니다.
- 서버가 보내 주는 목록(봇, 뷰, 선택지, 새 기능 화면)으로 그리므로 새 봇·기능은 앱 업데이트 없이 나타납니다.
- 녹음은 AAC 모노(시간당 약 11MB), 4MB 조각으로 올리고 끊기면 이어서 보내요(`RecordingQueue`). 다 보내면 아이폰에서 지워요. 녹음 중에는 모든 탭 제목 아래에 빨간 띠가 떠요.
- 같은 질문은 한 번만: 열린 결재 중 `topic`(없으면 맥락+질문)이 같은 건 가장 새 것 하나만 보여요(R15).
- 끌기(스와이프·스크롤) 중에는 결재 선택지·대화 버튼이 눌리지 않게 했습니다(`SafeTap`).

## 빌드와 실행

필요: Xcode 26+, XcodeGen(`brew install xcodegen`), Node 20+.

```bash
xcodegen
```

```bash
cd Packages/AxKitCore && swift test
```

시뮬레이터에서 가짜 맥과 함께:

```bash
node dev/mock-server.mjs
```

```bash
xcodebuild -project AxKit.xcodeproj -scheme AxKit -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath build/dd build
```

앱을 열고 첫 화면의 **개발용 가짜 맥에 연결**(Debug 빌드에만 있음)을 누르면 끝입니다. 또는 링크로:

```bash
xcrun simctl openurl booted 'axkit://pair?u=http%3A%2F%2F127.0.0.1%3A47790&n=dev&c=123456'
```

실제 맥의 응답으로 모든 화면 보기(읽기만): `AX_BASE=… AX_TOKEN=… node dev/capture-snapshot.mjs snap.json`으로 맥의 이벤트·뷰·첨부를 녹화하고
`node dev/snapshot-server.mjs snap.json`(포트 47792)으로 재생해요. 녹화 파일에는 실제 데이터가 있으니 저장소에 넣지 마세요.
화면 바로 열기 링크: `axkit://open/room?id=<방>`, `axkit://open/rooms`, `axkit://open/today`, `axkit://open/docs?q=<찾을 말>`, `axkit://open/doc?id=<문서>`, `axkit://open/more?v=<jobs|usage|health|…>`.

가짜 맥에서 일을 만들어 보기: `curl -s http://127.0.0.1:47790/dev/card`(새 결재), `curl -s 'http://127.0.0.1:47790/dev/notice?text=hi'`.
`/dev/digest`(번호 버튼이 붙은 저녁 정리). 가짜 맥 환경 변수: `SHARE_ROOMS=off`(방에서 첨부 숨김), `MODELS=none`(봇 모델 없는 옛 맥),
`LOCATION=off`(위치를 `POST location` 대신 휴대폰 신호 `/m/v1/ingest`로), `CALENDARS=one|limited`, `PEOPLE=none`, `WORK=none`, `DICTATION=off|empty|fail`.
가짜 맥은 "앱/버그", "주문/사줘", "매일/마다", "인스타" 같은 말에 반응해 봇에게 맡기기·결재·반복 작업을 흉내 냅니다.
키체인의 연결 정보를 지우고 처음부터 보려면 앱을 `-resetPairing` 인자로 실행하세요.

## 진짜 맥과 연결하기

1. 맥: `ax-kit phone pair --app --platform ios` → QR과 `axkit://pair?...` 링크가 나와요(10분, 한 번만).
2. 아이폰: **QR 찍기**(VisionKit) 또는 **연결 링크 붙여넣기**.
3. 주소 규칙: `https`(Tailscale Funnel `*.ts.net`, Cloudflare 터널) 또는 사설 주소의 `http`(Tailscale `100.64/10`, 집 와이파이, localhost)만 받습니다.
   집 밖에서 사설 주소를 쓰려면 아이폰에서 Tailscale을 켜 두세요. QR에 `ci`/`cs`(Cloudflare Access)가 있으면 키체인에 두고 매 요청에 붙입니다.
4. 연결 끊기: 더보기 › 설정 및 연결 › 연결 끊기(맥에서도 즉시 폐기).

내 아이폰에 설치하려면 `Config/Local.xcconfig.example`를 `Config/Local.xcconfig`로 복사해 번들 id와 팀을 넣고 Xcode에서 실행하세요.

## 휴대폰 신호

더보기 › 휴대폰 신호: 위치(크게 움직일 때·도착/출발, "항상" 허용), 배터리(20·10·5% 아래, 충전 중 제외), 걸음(건강 앱, 하루 한 번 어제 합계)을
켜 둔 것만 `POST /m/v1/ingest`(앱 토큰)로 보내요. 맥이 `location` 기능을 알리면 위치는 지금처럼 `POST location`. 문자·다른 앱 알림은 iOS에서
읽을 수 없어 단축어 자동화가 그대로 맡아요. 걸음 때문에 앱에 HealthKit 권한(읽기만)이 들어 있어요.

## 푸시·공유·위젯

- **푸시 알림**(§7.7): 맥에 APNs 키가 있으면(`capabilities.features`에 `push`) 연결 직후 알림 허락을 묻고 `push/register`로 토큰을 보내요.
  결재 알림을 길게 누르면 **승인/거절**(잠금 해제 필요), 알림을 누르면 결재 탭이나 그 방이 열려요. 앱 아이콘 숫자 = 기다리는 결재 수.
  시뮬레이터 시험: `xcrun simctl push booted dev.axkit.app 알림.json`(`category: "AX_CARD"`, `cardId`, `decision: true`).
- **공유 시트**(`AxKitShare`): 다른 앱의 공유에서 "ax-kit" → 글·링크·사진·파일을 비서에게 바로 보내요. 맥에 닿지 않으면 앱 그룹 폴더에 두었다가 앱이 열릴 때 보내요.
- **위젯**(`AxKitWidget`, 작게·중간): 기다리는 결재 수와 첫 질문, 오늘 일정. 앱이 쓴 스냅숏만 읽고 맥에 직접 접속하지 않아요.
- 시뮬레이터 빌드에 `CODE_SIGNING_ALLOWED=NO`를 붙이지 마세요. 서명이 없으면 키체인을 아예 못 써서 연결이 "잠깐 문제가 생겼어요"로 끝나요(로그: `-34018`). 팀이 없으면 `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=`로 빌드해요.
- 연결 정보는 키체인 공유 그룹(`<팀>.dev.axkit.app.shared`)에 있어 공유 시트도 써요. 팀 서명이 없는 시뮬레이터 빌드는 공유 그룹을 못 쓰므로 앱 전용 키체인을 써요(이때 공유 시트는 "앱에서 먼저 연결해 주세요").
- 내 아이폰에 올릴 때는 `Config/Local.xcconfig`에 팀을 넣고, Apple 개발자 사이트에서 같은 번들 id로 Push Notifications·App Groups를 켜 주세요.

## 터미널 (SSH)

더보기 › 맥 › 터미널. 아이폰이 Tailscale을 타고 맥에 바로 SSH로 들어가요(AX 서버를 거치지 않아요).

- 열쇠: 처음 열 때 Ed25519 열쇠를 만들어 이 기기 Keychain에만 둬요. 첫 화면의 공개키 한 줄을 각 맥의 `~/.ssh/authorized_keys`에 넣어요.
- 맥 목록: 이 폰에만 저장돼요. 처음부터 넣어 둘 맥은 `Config/Local.xcconfig`의 `AX_SSH_HOSTS = 이름=사용자@주소[:포트], …`로 정해요(한 번만 들어가고, 지운 건 다시 안 생겨요).
- 호스트 키: 처음 본 맥의 열쇠를 기억하고, 나중에 바뀌면 연결을 멈추고 물어봐요.
- 앱이 백그라운드로 가면 끊고, 돌아오면 다시 붙어요.
- 라이브러리: SwiftTerm 1.11.2(고정, 1.12부터는 Metal 도구가, 1.19부터는 빌드 플러그인 허락이 필요해요), Citadel 0.12.1(+ Citadel이 쓰는 swift-nio-ssh 포크 Wellz26/swift-nio-ssh).
- swift-nio가 Span을 써서 `ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES = YES`예요. 이게 없으면 iOS 17·18에서 앱이 켜지자마자 꺼져요.

## 아직 안 한 것

- `PROTOCOL-REQUESTS.md`의 서버 쪽 추가(R1~R13). 그 전에는 진짜 서버에서 봇 시트·문서·캘린더 등 일부 화면이 숨겨집니다.
- 봇 캐릭터는 지금 앱이 그린 둥근 캐릭터입니다. 서버가 `avatar` 그림을 보내면 그걸 씁니다(R13).
