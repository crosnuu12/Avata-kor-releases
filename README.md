# Avata_kor Windows 배포

## 최신 업데이트: 58.17.2

[58.17.2 릴리스 및 다운로드](https://github.com/crosnuu12/Avata-kor-releases/releases/tag/v58.17.2)

날짜 전환 후 입력 갱신, 예탁금이용료 현금 대조, 매매 없는 날의 자산내역 갱신을 수정했습니다.
서명된 앱 ZIP과 Windows 적용 도구를 제공합니다. 소스와 가상 데이터 검사도 ZIP에 포함합니다.

- 기존 프로그램은 시작할 때 서명된 업데이트를 확인합니다.
- 실행 중에는 최대 약 5분 간격으로 확인하며, 기존 호스트 설정에 따라 업데이트 버튼 조작이 필요합니다.
- 계좌 대조가 안 되었거나 주문 상태가 불명확하면 실행 중 적용을 미룹니다.
- 앱 ZIP은 앱 코드만 갱신합니다. 적용 도구는 호스트와 실행 중 자동 적용 설정도 갱신합니다.
- 재시작 후 실주문은 꺼져 있습니다. 사용자가 계좌 대조를 확인하고 별도로 승인해야 합니다.

검증: Windows PowerShell 5.1 가상 데이터 검사 181건. 공개 배포 직전에 GitHub Actions에서 같은 검사를 다시 수행합니다.
실제 PC의 적용 완료, 장중 운용, 자정 연속 운전은 별도 확인 대상입니다.

개인 API 키, 텔레그램 토큰, 시트 주소, 매매 원장, 실행 로그, 서명 개인키는 배포하지 않습니다.

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


