# Avata_kor Windows 배포

## 미니PC 첫 설치 (Windows 11 x64)

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

## 자동 업데이트

[v58.17.0 서명된 앱 배포](https://github.com/crosnuu12/Avata-kor-releases/releases/tag/v58.17.0)

자동 업데이트 정보와 앱 ZIP은 기존 릴리스 주소를 계속 사용합니다.
그 릴리스에 첨부된 이름이 `Avata_kor_Setup.exe`인 파일은 최초 설치 도구입니다.
현재 수정 설치 도구는 위 **r2** 링크로 제공합니다. 기존 릴리스 자산을 교체한 것은 아닙니다.

시작할 때 최신 서명된 배포를 확인하며, 실행 중 새 배포는 업데이트 버튼으로 적용합니다.
아직 배포하지 않은 개발 파일은 자동 감지하지 않습니다. 업데이트·재시작 후 실주문은 직접 시작해야 합니다.

검증: 설치 36개, 기존 시트 설정 보존 11개, 점검 도구 17개 통과. 가상 자료로만 시험했습니다.
개인 API 키, 텔레그램 토큰, 시트 주소, 매매 원장, 서명 개인키는 배포에 포함하지 않습니다.
