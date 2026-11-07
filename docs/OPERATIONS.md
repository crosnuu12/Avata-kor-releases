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

## 진단 아카이브와 시간 초과

실시간 요약 전송의 `Code`와 장기 보관의 `ArchiveCode`는 별도로 확인합니다. `Code=OK`만으로 보관까지 성공했다고 판단하지 않습니다. `ArchivePending`은 대기 중인 진단 기록 수이며 주문·체결 건수가 아닙니다. `ArchiveLastSuccessUtc`와 실제 보관함에 기록이 추가되는지도 함께 확인합니다.

1.1.11은 빈 Google Sheets 응답에서 `values`가 생략되거나 null인 경우를 신규 보관함으로 처리합니다. 기존 행의 이벤트 ID가 잘못되었거나 순서가 끊기면 계속 오류로 남기고 대기 기록을 보존합니다. 로컬 큐를 삭제하거나 원격 행을 임의로 정렬해 복구하지 않습니다.

실시간 요약을 먼저 보내고 아카이브는 실행당 최대 100건씩 처리합니다. `DIAG_ARCHIVE_CATCHING_UP`은 전송에 성공했지만 다음 실행에서 보낼 기록이 남았음을 뜻합니다. 대기량이 감소하다가 `ArchiveCode=OK` 및 `ArchivePending=0`이 되어야 밀린 전송이 끝난 것입니다. 대기 한도는 5,000건 또는 12MB이며, 한도 초과는 진단 누락 위험이 있어 별도 조치가 필요합니다.

`PERSISTENT_ERROR / TIMEOUT`은 연속 조회 실패가 경보 기준에 도달한 상태입니다. 이 이름만으로 영구 중지나 주문 거부를 뜻하지 않습니다. 관리 로그의 같은 장애에 `RECOVERED`가 기록됐는지, 최신 조회와 실주문 상태가 정상인지 확인합니다. 읽기 시간 초과 중 기존 ARMED 의도는 유지하지만 새 주문은 차단하며, 신선한 계좌 대조를 다시 충족해야 진행합니다. 주문 제출 결과가 불확실한 TIMEOUT은 별개로 REVIEW 상태에서 대조하며 자동 재전송하지 않습니다.

정확한 통신 원인은 해당 시각의 read 로그에 있는 단계·API 코드·안전한 오류 정보로 좁힙니다. 관리자 경보 한 줄만으로 특정 API, 통신사 또는 증권사 장애로 단정하지 않습니다. 이번 릴리스는 거래 승인과 주문 재시도 정책을 변경하지 않습니다.


## 작업자 중단과 후속 체결피드 경보

`WORKER_FAILED`와 `Running=false`가 먼저 나타나고 이후 `FEED_STATUS_MISSING`이 발생하면 조회 작업자 중단에 따른 후속 경보인지 확인합니다. 예전 `READ_OK`와 `LISTENING` 기록은 현재의 정상 상태를 증명하지 않습니다. `REVIEW` 또는 `DEFER_IDENTITY`에 의해 자동 재시작이 보류되면 그대로 켜 두는 것만으로 정상 복귀를 기대하지 않습니다.

1.1.12부터 `DataRoot/worker-error.json`의 `Boundary`, `ErrorType`, `HResult`, `Win32`, `SourceFile`, `Line`, `RunId`를 진단 요약과 보관 이벤트로 확인할 수 있습니다. `MANAGED_CYCLE`은 작업자 내부에서 확보한 최초 예외, `END_INVOKE`는 그 기록을 확보하지 못한 UI 측 예외입니다. 미확인 위치는 빈 파일명·0행으로 남으며 원문 메시지와 전체 경로를 전송하지 않습니다. 기존 버전에서 사라진 예외 내용은 이 업데이트로 복원되지 않습니다.

`ArchiveStateKnown=false`이면 보관 대기량과 순번을 확정할 수 없습니다. 이때 빈 값은 0건을 뜻하지 않습니다. `DIAG_ARCHIVE_EVENT`를 해결하기 위해 큐 파일을 삭제하지 마십시오. 1.1.12는 정상적인 슬래시 시작 API 경로를 허용하여 이미 순번이 배정된 큐도 재개합니다.


## 정지 요청 후 업데이트 대기가 끝나지 않을 때

`WAITING_FOR_ORDERS`만 보고 실제 미체결이 있다고 단정하지 않습니다. 구버전 호스트는 REVIEW, 계좌 대조 미완료, 조회 지연, 작업 중 상태도 같은 이름으로 표시합니다. `Live.State`, `Reconciled`, `Confirmations`, 미체결·불확실 주문, `LiveMaintenance`와 원본 시각을 함께 확인합니다.

1.1.13은 명시적인 정지 의도를 별도로 유지하여 전략 입력이 오래되어도 종료에 필요한 새 계좌 대조를 진행합니다. 정지 요청 이전의 대조 횟수는 종료 증거로 재사용하지 않습니다. 두 번의 새 대조가 완료되어야 `DISARMED`와 `QUIESCENT`에 도달하며, 그 다음 호스트가 조회 작업이 비는 시점에 전환합니다. REVIEW에서 이 경로는 주문 제출·취소를 수행하지 않습니다. 미체결·불확실 주문이나 계좌 불일치가 있으면 계속 보류합니다.

새 UI는 대기 이유와 10분 요청 만료를 표시합니다. 만료와 동시에 호스트가 이미 전환 중일 수 있으므로, 최신 호스트 상태가 전환을 진행하지 않는다고 확인한 후 재시도·복구를 허용합니다. 실주문 자동 시작을 다시 켜지 않습니다.

이미 이 결함에 막힌 구버전은 새 번들을 실행하기 전까지 바뀌지 않습니다. 계좌·주문 상태 확인 후 정상 종료하고 다시 실행하는 일회성 절차가 필요할 수 있습니다. 실제 설치 버전과 새 조회를 확인하기 전에는 복구 완료로 보고하지 않습니다. 강제 종료나 active.json·원장·신뢰 키 수동 변경으로 안전 검사를 우회하지 않습니다.

입력 문제는 1.1.13부터 `input-read-YYYYMMDD.jsonl` 진단의 `Step`, `Reason`, 안전한 오류 코드로 구분합니다. 이 이름은 로컬 `input-diagnostics/read-YYYYMMDD.jsonl`을 투영한 원격 출처이며 원본 파일 경로나 메시지는 전송하지 않습니다.
