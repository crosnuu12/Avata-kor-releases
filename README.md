# Avata_kor Windows 배포

## 최신 버전: 1.1.1

[1.1.1 릴리스 및 다운로드](https://github.com/crosnuu12/Avata-kor-releases/releases/tag/v1.1.1)
· [메인PC 실행 준비 파일](https://github.com/crosnuu12/Avata-kor-releases/releases/download/v1.1.1/Avata_MainPC_1.1.1.zip)

메인PC와 미니PC의 실주문·자동 시작·시트·텔레그램·자동 업데이트 기능은 동일합니다.
상단 **트레이 사용**으로 PC마다 화면 방식을 설정하며, 업데이트 후에도 유지합니다.
프로그램 표시는 **1.1.1**, 자동 업데이트 내부 빌드는 **58.17.7**입니다.

메인PC 준비 ZIP을 압축 해제하고 Avata_MainPC_1.1.1.cmd를 실행하면 일반 창 모드로 설정하고 기존 실행 도구를 엽니다.
최소화하면 작업표시줄에 남으며, 실주문 시작과 자동 시작은 기존과 동일하게 사용할 수 있습니다.
미니PC는 기존 업데이트 경로를 사용하면 트레이 설정이 유지됩니다.

자동 실주문 시작은 해당 PC·계좌·종목에 대한 사용자 선택이며, 설정 도구가 동의를 새로 만들지 않습니다.
운용 PC를 바꿀 때는 기존 PC의 실주문 중지와 증권사 주문 상태를 확인한 뒤 새 PC에서 계좌 대조를 거쳐 시작하세요.

알림 오경보, 트레이 복원, 날짜 전환, 예탁금이용료 대조 수정이 포함돼 있습니다.
Windows PowerShell 5.1 기본 검사 266건과 격리된 Windows UI 검사 22건으로 검증합니다.
개인 API 키, 텔레그램 토큰, 시트 주소, 계좌 원장, 실행 로그, 서명 개인키는 배포하지 않습니다.

## 기존 첫 설치 도구

### 미니PC 첫 설치 (Windows 11 x64)

앱 **58.17.0**, 설치 도구 **1.0.1.0**. 시트 연결 복구 수정이 반영된 설치 파일입니다.

- [미니PC 설치·점검 묶음 내려받기](https://github.com/crosnuu12/Avata-kor-releases/raw/refs/heads/main/Avata_kor_MiniPC_58.17.0_r2.zip)
- [설치 EXE만 내려받기](https://github.com/crosnuu12/Avata-kor-releases/raw/refs/heads/main/Avata_kor_Setup_58.17.0_r2.exe)
- [SHA-256](MINIPC_SHA256.txt)

`Avata_kor_Setup_58.17.0_r2.exe`를 내려받아 실행하고 **새 PC에 설치**를 누릅니다.
설치 후 바탕화면 `Avata_kor`로 실행하고 개인 인증정보와 시트를 등록합니다.
`Avata_MiniPC_Check.cmd`는 설치·연결 상태를 읽어 같은 폴더에 점검 결과를 저장합니다.
점검은 주문이나 PC 설정을 변경하지 않습니다. 자세한 순서는 묶음 안 `MINIPC_INSTALL.txt`에 있습니다.

기존 계좌를 옮길 때는 원장 이전과 계좌 대조가 별도로 필요합니다.
기존 PC의 암호화 파일을 단순 복사해도 다른 Windows 사용자/PC에서 해독되지 않습니다.
같은 계좌의 두 PC에서 실주문을 동시에 실행하지 마세요.
실제 미니PC의 AnyDesk·모니터 없는 운용·재부팅은 현장에서 확인해야 합니다.



