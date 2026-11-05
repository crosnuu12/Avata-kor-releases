# 운영과 로그 확인

## 실제 설치와 현재 상태 확인

시트의 `메인PC_진단`에서 다음 순서로 확인합니다.

1. 수집 시각과 원본 파일 시각을 함께 봅니다. 수집기가 동작해도 앱 원본 상태는 오래됐을 수 있습니다.
2. `manager-status.json`의 `BundleVersion`과 `active.json`의 버전으로 설치본을 확인합니다.
3. `status.json`의 최신 조회 결과, `Live.State`, `Live.Code`, `Reconciled`, 미체결·확인 불가 주문 수를 봅니다.
4. `sheets-status.json`, `journal-status.json`, `assets-status.json`을 각각 확인합니다. 표시 전송, 일지 반영, 자산 보고 성공은 서로 다른 증거입니다.
5. 최신 상태에서 문제가 확인되면 관련 `read-YYYYMMDD.jsonl`, `execution-YYYYMMDD.jsonl`, `manager-YYYYMMDD.jsonl` 기록으로 원인을 좁힙니다.

진단 탭은 최근 기록을 보여주는 제한된 창입니다. 전체 로그가 영구 누적되는 클라우드 원장은 아닙니다. 원본 로그는 메인PC에 남고, 채팅에서의 점검은 요청 시 조회입니다.

## 파일이 있는 위치

기본 설치의 공통 폴더 이름입니다. 실제 경로는 호스트 설정의 `DataRoot`, `ManagementRoot`를 먼저 확인합니다.

| 위치 | 내용 | 주요 파일 |
| --- | --- | --- |
| `%LOCALAPPDATA%\esbada_AT_host` | 설치 번들, 서명 피드, 전환·복구 기록 | `settings.json`, `active.json`, `trial.json`, `remote-channel/` |
| `%LOCALAPPDATA%\esbada_AT_manage` | 관리자·UI 상태, 시트·Telegram 상태 | `runtime.json`, `manager-status.json`, `state.json`, `sheets-status.json`, `journal-status.json`, `assets-status.json`, `presentation-state.json` |
| `%LOCALAPPDATA%\esbada_AT_direct` | 계좌 조회 및 전략 입력 스냅샷 | `status.json`, `snapshot.dpapi`, `strategy-input.dpapi`, `input-refresh-status.json`, `input-refresh-success.json` |
| `DataRoot\real-orders-v1` | 실전 원장과 실행 상태 | `order-book.dpapi`, `state.dpapi`, `snapshot.dpapi`, `status.json` |

`.dpapi` 파일은 해당 Windows 사용자 환경의 보호를 사용합니다. 파일명·상태만 공개 진단에 포함하고, 인증정보나 원장 내용을 공개 저장소·테스트에 옮기지 않습니다.

## 자주 보는 상태

| 상태 | 해석과 다음 확인 |
| --- | --- |
| `READ_OK` / `OK` | 해당 조회 성공. 시각이 현재인지 함께 확인 |
| `LIVE_MARKET_WAIT` | 시장 일정상 주문 대기. 장애로 단정하지 않음 |
| `DISARMED` | 실주문 승인 비활성. 자동으로 승인했다고 간주하지 않음 |
| `LIVE_INPUT_WAIT` | 전략 입력의 읽기·복호화·날짜·유효시간 확인. 입력 갱신 진단을 함께 읽음 |
| `LIVE_RECONCILE_WAIT` | 계좌·원장 대조 확인을 기다림 |
| `REVIEW` / 확인 불가 주문 존재 | 실제 주문 결과를 확인하기 전 재전송·업데이트를 강행하지 않음 |
| 업데이트 `AVAILABLE` | 새 버전 확인 완료. 앱의 업데이트 버튼으로 적용 |
| 번들 `LIVE_HOLD` | 실행 중 실주문 상태 때문에 전환을 보류. 최신 버전 공개 여부와 별개 |
| `WAITING_FOR_QUERY` | 업데이트 후 정상 조회 검증에 필요한 조회 재개를 기다림 |

## 알림

- 개장 알림: 신선한 증권사 시장 일정과 실제 실주문 활성 상태가 확인될 때 하루 한 번 대기열에 넣습니다.
- 마감 알림: 장 마감 이후 계좌 대조, 미체결 확인, 일지 반영, 새 자산 내역 조회·반영이 완료되어야 합니다.
- 관리자 `state.json`은 알림 대기열과 당일 발송 대상 표시를 함께 저장합니다. 기기 재시작 때 이 파일을 임의 삭제하면 중복 방지 근거도 사라집니다.
- Telegram 전송·연결 상태는 메시지 수신과 별도입니다. 코드 검증을 통과했다는 사실만으로 실제 전달 완료를 주장하지 않습니다.

## 미니PC 자료

현재 운영과 로그 수집은 메인PC 기준입니다. 미니PC 공개 소스·설치 파일은 `archive/minipc-20261105` 브랜치, 개인 진단 백업과 기기 정리 도구는 비공개 백업에 분리합니다. 공유 매매일지·계좌 원장은 미니PC를 중단한다는 이유로 삭제하지 않습니다.

## 1.1.6 전송량과 캐시 상태 읽기

`sheets-status.json`과 `assets-status.json`의 `WrittenRanges`·`WrittenCells`는 이번 실행에서 보낸 값 범위와 셀 수이며, `SkippedRanges`는 값이 같아 생략한 범위 수입니다. `FullRefresh=true`는 전체 값 재전송을 뜻합니다. 자산 상태의 `WriteRequests`에는 값 이외에 필요한 서식·행 확장 요청도 포함됩니다. 진단 탭은 이 수치와 `Cached`·`PublishedUtc`를 허용 목록으로 전달합니다.

`Code=OK`이면서 `WrittenRanges=0`일 수 있습니다. 이는 유효한 기존 표시 캐시와 값이 같아 HTTP 쓰기를 생략한 실행입니다. 자산의 `Cached=true` 역시 재전송 생략을 뜻하며, `PublishedUtc`는 마지막 실제 전송 성공 시각입니다. `SnapshotUtc`·원장 조회 완료 시각과 함께 읽어 최신 조회와 이전 표시 성공을 구분합니다.

표시 캐시를 거래 원장으로 사용하지 않습니다. 초기 실행·캐시 무효·대상 변경·전송 결과 미확정·5분 경과 시의 전체 재전송은 정상 복구 동작입니다. 같은 범위가 매번 전체 전송되거나 미확정 상태가 반복되면 캐시를 무조건 지우기보다 최신 `sheets-status.json`·`assets-status.json`의 오류와 네트워크 응답부터 확인합니다.
