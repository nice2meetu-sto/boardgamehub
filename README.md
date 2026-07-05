# 🎲 보드게임 동아리 관리 웹앱

동아리원들이 모바일에서 사용하는 보드게임 관리 페이지입니다.
플레이 기록·평점·개인 통계를 관리하고, 게임 정보를 직접 입력하거나 BoardGameGeek(BGG) 연동으로 등록합니다.
(BGG 연동은 `Code.gs`의 `BGG_PROXY`에 설정된 Cloudflare Worker 프록시를 통해 동작합니다.)

- **프론트엔드**: 단일 `index.html` (vanilla JS, 프레임워크 없음) — GitHub Pages 호스팅
- **백엔드**: Google Apps Script 웹앱 (`Code.gs`, `doGet` 기반 GET-only JSON API)
- **DB**: Google Sheets (시트 4장)

---

## 📐 아키텍처 개요

```
[모바일 브라우저] ──fetch(GET)──▶ [Apps Script 웹앱 doGet] ──▶ [Google Sheets]
     index.html                        Code.gs                Players/Games/
  (GitHub Pages)                                              Ratings/PlayLogs
```

- 모든 요청은 **GET만** 사용 (CORS preflight 회피). 쓰기 작업도 GET 파라미터로 처리하며,
  복잡한 데이터는 `payload=encodeURIComponent(JSON.stringify(...))` 형태로 전달합니다.
- `google.script.run` / `HtmlService` 는 사용하지 않습니다.

---

## 1. Google Sheets 생성

1. [Google Sheets](https://sheets.new)에서 새 스프레드시트를 만듭니다. (이름 예: `보드게임동아리DB`)
2. **시트 4장**과 헤더를 만들어야 합니다. 아래 두 가지 방법 중 하나를 선택하세요.

### 방법 A — 자동 생성 (권장)
Apps Script를 먼저 연결(2단계)한 뒤, 편집기에서 `setupSheets` 함수를 1회 실행하면
아래 4개 시트와 헤더가 자동으로 생성됩니다.

### 방법 B — 수동 생성
아래 시트를 만들고 **1행에 헤더**를 그대로 입력합니다. (컬럼 순서는 바뀌어도 되지만 헤더명은 정확히 일치해야 합니다.)

**`Players`**
```
player_id | name | pin_hash | pin | role | joined_at
```
> `pin`은 관리자가 시트에서 직접 확인할 수 있는 **평문 PIN**입니다(회원이 PIN을 잊었을 때 안내용).
> 로그인 검증은 `pin_hash`(SHA-256)로 하고, `pin`은 조회 편의를 위한 보조 컬럼입니다.
> 동아리 내부용 4자리 숫자라 노출해도 무방하지만, 시트 공유 범위는 관리자로 제한하세요.

**`Games`**
```
game_id | name_kr | name_en | bgg_id | category | min_players | max_players | playtime_min | weight | bgg_rating | summary_kr | image_url | source | created_by | created_at
```

**`Ratings`**
```
player_id | game_id | rating | memo | updated_at
```

**`Categories`** (선택 — 게임 분류 목록을 앱에서 관리)
```
category
전략
마피아
트릭테이킹
...
```
> `Categories` 탭의 A열에 분류를 한 줄에 하나씩 적으면, 게임 추가/수정 화면의 분류 선택지가
> 이 목록으로 채워집니다(코드 수정 불필요). 1행 헤더 `category`는 있어도 없어도 됩니다.
> 탭 이름은 `Categories` / `분류` / `카테고리` 중 아무거나 가능하며, 탭이 없으면 기본 목록을 사용합니다.
> (`setupSheets` 실행 시 기본 분류가 채워진 `Categories` 탭이 자동 생성됩니다.)

**`PlayLogs`**
```
record_id | session_id | play_date | game_id | duration_min | player_id | score | is_win | created_at
```

> 💡 날짜 컬럼(`joined_at`, `play_date` 등)은 **서식을 '일반' 또는 '텍스트'** 로 두면
> 시트의 자동 날짜 변환을 피할 수 있습니다. 백엔드는 `getDisplayValues()`로 읽어 안전하게 처리합니다.

---

## 2. Apps Script 연결 & 코드 붙여넣기

1. 스프레드시트 상단 메뉴에서 **확장 프로그램 → Apps Script** 클릭
2. 기본 `Code.gs` 내용을 지우고, 이 저장소의 **`Code.gs` 전체**를 붙여넣습니다.
3. 저장(💾).
4. (방법 A를 쓴다면) 함수 선택 드롭다운에서 `setupSheets`를 골라 **실행 ▶** → 최초 권한 승인.

> `SHEET_ID` 상수는 비워두면 됩니다(컨테이너 바운드 스크립트라 활성 스프레드시트를 자동 사용).
> 별도 스프레드시트를 쓰려면 `Code.gs` 상단 `SHEET_ID`에 스프레드시트 ID를 넣으세요.

---

## 3. 플레이어(계정) 등록 — 셀프 가입

별도 계정 발급 없이, 앱의 **MY → 가입하기** 탭에서 **닉네임 + 숫자 4자리 PIN**만 입력하면
바로 가입·로그인됩니다. PIN은 시트에 평문이 아닌 **SHA-256 해시**로만 저장됩니다.

- **닉네임**은 로그인 아이디로 쓰이므로 중복되면 가입이 거부됩니다.
- **가장 먼저 가입한 사람이 자동으로 관리자(`admin`)** 가 됩니다.
  (게임 세부정보 수정 권한 보유. 이후 가입자는 모두 `member`)
- 즉, 동아리 대표가 앱을 열어 먼저 가입하면 관리자가 되고, 나머지 회원은 각자 가입하면 됩니다.

> 필요하면 Apps Script 편집기에서 `addPlayerManual('P001','홍길동','1234','admin')`
> 함수로 수동 등록하거나, `Players` 시트의 `role` 값을 직접 `admin`으로 바꿔
> 추가 관리자를 지정할 수도 있습니다.

---

## 4. 웹앱으로 배포

1. Apps Script 편집기 우측 상단 **배포 → 새 배포**
2. 유형 선택(⚙️) → **웹 앱**
3. 설정:
   - **설명**: 아무거나 (예: v1)
   - **실행 계정(Execute as)**: **나(me)**
   - **액세스 권한(Who has access)**: **모든 사용자(Anyone)**
4. **배포** → 권한 승인 → **웹 앱 URL** 복사
   (형식: `https://script.google.com/macros/s/......../exec`)

> 코드 수정 후에는 **배포 → 배포 관리 → 편집(연필) → 버전: 새 버전 → 배포** 로 갱신해야
> 변경 사항이 반영됩니다. (URL은 유지됩니다.)

---

## 5. HTML에 API URL 연결

`index.html` 상단의 상수 한 곳만 바꾸면 됩니다.

```js
// index.html <script> 최상단
const API_URL = "여기에_배포_URL";   // ← 4단계에서 복사한 웹앱 URL(.../exec)로 교체
```

예:
```js
const API_URL = "https://script.google.com/macros/s/AKfyc.../exec";
```

---


## 6. GitHub Pages 배포

1. 이 저장소를 GitHub에 푸시합니다. (`index.html`이 루트에 있어야 합니다.)
2. 저장소 **Settings → Pages**
3. **Source**: `Deploy from a branch`, **Branch**: 배포 브랜치 / `/(root)` 선택 → Save
4. 잠시 후 발급되는 `https://<사용자>.github.io/<저장소>/` 주소로 접속합니다.

> 모바일에서 접속 후 "홈 화면에 추가"하면 앱처럼 사용할 수 있습니다.

---

## 7. 사용 방법

| 탭 | 설명 |
|---|---|
| **플레이** | 전체 플레이 기록을 최신순으로. 상단에 이번 달/누적/최다 플레이 요약 |
| **게임** | 등록된 모든 게임을 우리동아리평점 내림차순 카드로. 분류·인원수 필터 + 이름 검색. 카드 탭 시 요약 펼침 |
| **MY** | 닉네임+PIN 가입/로그인 → 개인 통계(플레이 기록) & 내가 참가한 게임 평점/메모(게임 기록) |
| **+ 버튼** | 게임 추가(BGG 연동 또는 직접입력·사진 촬영/업로드) · 플레이 결과 추가 |

- 로그인 정보는 `sessionStorage`에 유지됩니다(탭을 닫으면 해제).
- 쓰기 작업(평점·플레이·게임 추가/수정) 시 본인 확인용 PIN을 한 번 입력합니다.

---

## 8. API 스펙 요약 (`doGet` action)

| action | 파라미터 | 동작 |
|---|---|---|
| `login` | name, pin | PIN SHA-256 대조, 성공 시 `{player_id, name, role}` |
| `signup` | name, pin | 닉네임 중복·PIN(숫자 4자리) 검증 후 신규 등록. 첫 가입자는 `admin` |
| `getGames` | - | 전체 게임 + `club_rating`, `rating_count`, `play_count` |
| `getPlays` | - | 세션 단위 그룹핑된 전체 플레이 기록(최신순) |
| `getPlayerStats` | playerId | 개인 통계(총 플레이/승수/승률, 월별, 게임별 승률) |
| `getMyRatings` | playerId | 내 평점·메모 목록 |
| `getPlayers` | - | 플레이어 목록(참가자 선택용) |
| `getCategories` | - | `Categories` 탭의 분류 목록(없으면 기본값) |
| `searchBgg` | query | BGG 검색 후보 `[{bgg_id, name_en, year}]` |
| `addGame` | payload(JSON) | bgg_id가 있으면 BGG 상세 수집·번역, 없으면 수동 입력 저장 |
| `saveRating` | playerId, pin, gameId, rating, memo | 본인 인증 후 upsert |
| `addPlay` | payload(JSON) | 세션 생성 후 참가자별 행 추가 |
| `updateGame` | playerId, pin, payload | **admin만** 게임 세부정보 수정 |

공통 응답: `{ ok: true, data: ... }` 또는 `{ ok: false, error: "메시지" }`

---

## 9. 계산 로직

- **승률** = `is_win=TRUE` 행 수 ÷ 전체 참가 행 수 × 100 (소수 1자리)
- **우리동아리평점** = 게임별 `Ratings.rating` 평균 (소수 1자리, 평가 0건이면 `-`)
- **게임별 개인 승률** = 그 게임에서의 승수 ÷ 참가 수

---

## 10. 트러블슈팅

| 증상 | 원인/해결 |
|---|---|
| 첫 응답이 2~3초 느림 | Apps Script 콜드스타트. 정상이며 로딩 스피너가 표시됩니다. |
| `Unknown action` / 가입(signup) 안 됨 | 편집기의 `Code.gs`를 **최신으로 교체** 후 **배포 관리 → 편집 → 버전: 새 버전 → 배포**. (API_URL만 바꾸고 백엔드를 재배포 안 하면 새 기능이 반영되지 않습니다) |
| 로그인 실패 | 닉네임·PIN 확인. 처음이면 **가입하기** 탭으로 먼저 가입 |
| PIN 분실 | `Players` 시트의 `pin` 컬럼에서 평문 PIN 확인 후 안내 |
| 관리자 지정 | 첫 가입자가 자동 admin. 이후 `Players` 시트 `role`을 `admin`으로 바꿔 추가 지정 |
| 게임 수정 버튼 안 보임 | `admin` 계정으로 로그인해야 노출됩니다 |
| CORS/401 오류 | 배포 시 **액세스: 모든 사용자**, **실행: 나** 설정 확인 |

---

## 파일 구성

```
index.html   # 단일 파일 프론트엔드 (CSS/JS 인라인)
Code.gs      # Apps Script 백엔드 (doGet 라우팅 + 시트 읽기/쓰기)
README.md    # 이 문서
```
