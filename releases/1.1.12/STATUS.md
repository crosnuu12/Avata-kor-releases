# 릴리스 상태

상태: 공개 및 자동 업데이트 검증 완료

- 버전: 1.1.12 / 58.17.18
- Windows PowerShell 5.1 전체 25개 회귀 테스트 스크립트: 통과
- 진단 아카이브 46개 · 진단 요약 및 정보 필터링 40개 · 작업자 오류 기록 17개: 통과
- TIMEOUT 복구 27개 · 거부 주문 복구 73개: 통과
- 실제 복구 창 32개 · 트레이 18개 · 데스크톱 시작 4개: 통과
- 소스 복원 도구 10개, 서명·체크섬·전체 소스와 런타임 일치: 통과
- 공개 배포 및 버전별·최신 피드 다운로드 검증: 완료 (2026-11-07 20:16 KST)
- 58.17.12/.13/.14/.15/.16 및 실제 설치 기준 58.17.17에서 새 업데이트 검증: 통과
- 사용자 PC 설치 및 실제 로그 큐 소진: 미확인
- 최초 WORKER_FAILED 원인: 미확정

[Windows 브랜치 검증](https://github.com/crosnuu12/Avata-kor-releases/actions/runs/42366990511) · [최종 검증 및 공개 배포](https://github.com/crosnuu12/Avata-kor-releases/actions/runs/42367267399) · [PR #21](https://github.com/crosnuu12/Avata-kor-releases/pull/21) · [릴리스](https://github.com/crosnuu12/Avata-kor-releases/releases/tag/v1.1.12)

정상 API 경로 보관 결함을 수정하고 이후 작업자 예외의 안전한 발생 위치를 기록합니다. 기존 WORKER_FAILED의 최초 원인을 해결했다는 의미는 아닙니다. 주문 승인·재전송·자동 재시작 정책은 유지합니다. 테스트는 합성 자료와 격리한 Windows 환경으로 수행했으며 실계좌·실주문·실제 Telegram 전송은 사용하지 않았습니다.

실제 설치 버전과 신선한 조회·runtime·체결수신 상태를 확인해야 운영 복구로 판단할 수 있습니다. 큐 보관은 ArchiveStateKnown=true, ArchiveCode=OK, ArchivePending=0 및 실제 보관 행 추가로 별도 확인합니다. ArchiveStateKnown=false인 빈 대기량은 0건을 뜻하지 않습니다.
