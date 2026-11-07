# 개발·검증·배포

## 수정 전 기준 고정

1. 대상 릴리스의 제품 버전, 내부 번들 버전, `release.json`의 번들 ID·파일 해시를 기록합니다.
2. 저장소의 `CURRENT_SOURCE.json`과 `tools/Prepare-Source.py`로 고정된 전체 Verification ZIP을 저장소 밖의 새 작업 폴더로 복원합니다. 공개 `source/` 발췌본을 완전한 소스로 취급하지 않습니다. 인덱스는 선택한 릴리스의 ZIP 상대 경로, 제품·번들 버전, 번들 ID, ZIP·manifest SHA256을 함께 고정합니다.
3. 사용자별 설정·원장·로그와 합성 테스트 자료를 분리합니다. `tests/original/`, `tests/stable6/`는 이전 동작 대조 자료이므로 현재 버전 번호로 일괄 치환하지 않습니다.
4. 변경할 계층과 검증할 동작을 정합니다. 표시·진단 최적화가 거래 승인·주문 수량·가격·입력 유효성에 영향을 주지 않게 경계를 확인합니다.

## 최적화 시 보존할 동작

- 증권사의 현재 시세·계좌·주문 결과가 거래 판단 근거입니다.
- 같은 주문의 분할 체결은 실제 금액을 합산하고 가중평균 체결가를 표시합니다.
- 하루 서로 다른 신규 매수 차수 3개 제한과 기존 위험·자금 검사를 유지합니다.
- 실전 입력 갱신과 화면 표시 전송은 다릅니다. 표시 주기를 늘려도 입력이 유효시간을 넘지 않아야 합니다.
- 실패한 시트 쓰기를 성공으로 기록하거나, 캐시된 장중 자산 보고를 장 마감 정산 완료로 간주하지 않습니다.
- 진단 전송은 일반 시트 갱신·전략 입력 실패와 독립적으로 동작해야 합니다.
- 공유 시트의 행·열 축소는 실사용 범위, 수식·서식·검증 규칙, 다음 쓰기 범위 확인 및 백업 이후에 수행합니다.

## 테스트 경로

전체 검증은 Windows PowerShell 5.1에서 수행합니다. PowerShell 7의 로컬 검사는 보조 확인입니다.

```powershell
powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy RemoteSigned -File .\Run-Checks.ps1
powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy RemoteSigned -File .\Test-TrayRestore.ps1 -HostedRunner
powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy RemoteSigned -File .\Test-DesktopStartup.ps1
```

| 변경 영역 | 관련 검증 |
| --- | --- |
| 표시 범위·캐시·불확정 전송 복구 | `Test-PresentationWrites.ps1` |
| 자산 표시·행 확장·캐시 복구 | `Test-AssetOptimization.ps1` |
| 시트 원장·일지 | `Test-JournalGrouping.ps1`, `Test-InputDiagnostics.ps1` |
| 진단 수집·전송 | `Test-MainPCDiagnostics.ps1`, `Test-InputDiagnosticRemote.ps1` |
| 오류 후 정지·업데이트 | `Test-UpdateQuiescence.ps1`, `Test-UpdateWaitUi.ps1` |
| 일자 전환·복구 | `Test-DayTransition.ps1`, `Test-Rollover.ps1`, `Test-HostRepair.ps1` |
| 주문 가격·차수·체결 | `Test-BuyTable.ps1`, `bundle/payload/Test-AT58.ps1` |
| 개장·마감·장애 알림 | `Test-MarketNotifications.ps1`, `Test-Alerts.ps1` |
| Telegram 승인 | `Test-TelegramStart.ps1`, `Test-TelegramWorker.ps1` |
| 시작·트레이·창 상태 | `Test-AutoStartTray.ps1`, `Test-HiddenStartup.ps1`, `Test-HiddenAutoRead.ps1`, `Test-WindowPreferences.ps1` |

1.1.6 / 58.17.12 최적화안은 기존 회귀 검증에 표시·자산 보고 캐시 검증을 추가합니다. 최종 검증 수와 Windows 결과는 해당 릴리스의 실제 실행 결과를 기록합니다. 실제 계좌·주문·Telegram 메시지는 회귀 검증에 사용하지 않습니다.

소스 복원 도구의 검증은 공개 저장소 루트에서 별도로 실행합니다. 합성 ZIP만 사용하며 실제 설정·원장·키가 필요하지 않습니다. 경로 이탈, ZIP·파일시스템 링크, 해시 불일치, Windows 경로 별칭, 불완전한 소스, 저장소 내부 대상 및 기존 폴더 덮어쓰기를 차단하는지 확인합니다.

```powershell
python .\tools\Test-Prepare-Source.py
```

`Prepare-Source.py`는 추출 전 모든 파일을 검증합니다. 이후 디스크 쓰기 오류가 발생하면 부분 생성 폴더를 임의로 삭제하지 않으므로, 오류 원인을 확인하고 다른 새 폴더로 재시도합니다. 이 도구는 네트워크 다운로드, 코드 실행, 런타임 전환이나 서명 개인키 접근을 수행하지 않습니다.

## 배포 절차와 파일

| 단계 | 파일 / 확인 항목 |
| --- | --- |
| 소스 묶음 생성 | `Package-Candidate.py`, `bundle/release.json` |
| 업데이트 패키지·피드 생성 | `releases/<제품버전>/Build-Assets.py` |
| 서명·해시·크기·소스 일치 검증 | `Verify-Assets.py`, `SHA256SUMS.txt` |
| Windows 검증 | 해당 릴리스의 `.github/workflows/` 작업 |
| 검증 후 공개·최신 채널 전환 | `Publish.ps1` |
| 실제 공개 경로 확인 | 버전별·최신 피드를 실제 업데이터로 내려받아 서명과 패키지 검증 |
| 현재 소스 인덱스 확정 | `CURRENT_SOURCE.json`의 버전·ZIP 경로·번들 ID·두 SHA256을 실제 검증 결과로 갱신 |
| 완료 기록 | `RELEASE_NOTES.md`, `STATUS.md`, 루트 `README.md`, `PROJECT_INDEX.md` |

서명 개인키는 로컬의 비공개 보관 위치에서만 사용합니다. 저장소에는 공개 검증키만 둡니다. 이미 공개한 서명 패키지·피드는 수정하지 않고 새 버전을 만듭니다. CI 통과, 공개 배포 완료, 사용자 PC 설치 완료를 각각 구분해서 보고합니다.

## 다음 작업자가 재현할 수 있게 남길 것

- 기준 릴리스·커밋과 변경 목적.
- 수정한 함수·설정·시트 범위 및 실제 쓰기량 변화.
- 회귀 검증 결과와 한계. 모바일 로딩 시간은 실제 단말 측정 없이 개선 수치로 단정하지 않음.
- 릴리스·CI 링크, 설치 확인 시각과 확인한 버전.
- 복구 가능한 코드·시트 백업 위치. 개인 백업 식별자는 공개 문서 대신 비공개 운영 기록에 보관.

소스 인덱스는 아카이브 생성·검증 후 채웁니다. `ArchiveSha256`은 Verification ZIP 원본 바이트, `ManifestSha256`은 그 ZIP 내부 `bundle/release.json` 원본 바이트의 SHA256입니다. 별도로 다시 직렬화한 JSON의 해시를 쓰지 않습니다. 인덱스가 새 버전을 가리키기 전에 복원 도구로 그 정확한 아카이브를 읽어 전체 소스를 재현하는지 확인합니다. 기존 릴리스 파일을 복제해 새로운 기준 폴더를 늘리지 않고, 이 작은 인덱스만 최신 검증본을 가리키게 유지합니다.

