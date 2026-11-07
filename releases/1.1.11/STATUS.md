# 릴리스 상태

상태: 공개 및 자동 업데이트 검증 완료

- 버전: 1.1.11 / 58.17.17
- Windows PowerShell 5.1 전체 24개 회귀 테스트 스크립트: 통과
- 진단 보관 초기화·오류 격리·큐 보존·분할 전송: 29개 통과
- 읽기 TIMEOUT 복구·새 계좌 대조·불확실 주문 재전송 차단: 27개 통과
- 거부 주문 복구 73개·실제 복구 창 32개·트레이 18개·시작 4개: 통과
- 소스 복원 도구 10개·기존 공개키 서명·패키지·체크섬·전체 소스 일치: 통과
- 58.17.12/.13/.14/.15/.16 기준 버전별 공개 업데이트 및 최신 피드 다운로드 검증: 통과
- 공개 배포: 완료 (2026-11-07 12:35 KST)
- 사용자 PC 설치 및 실제 대기 로그 소진: 미확인

[최종 Windows 검증 및 공개 배포](https://github.com/crosnuu12/Avata-kor-releases/actions/runs/42334506945) · [릴리스](https://github.com/crosnuu12/Avata-kor-releases/releases/tag/v1.1.11) · [PR #19](https://github.com/crosnuu12/Avata-kor-releases/pull/19)

거래 승인·전략·주문 처리 런타임은 변경하지 않았습니다. 테스트는 합성 자료로 수행했으며 실계좌·실주문·실제 Telegram 메시지를 사용하지 않았습니다. PC 적용 후 실제 설치 버전과 ArchivePending 감소, 최종 ArchiveCode=OK 및 ArchivePending=0을 따로 확인해야 합니다. 공개 배포만으로 현장 큐가 비워졌다고 판단하지 않습니다.
