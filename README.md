# Avata

프로젝트 작업은 [길잡이](PROJECT_INDEX.md)에서 시작합니다. 소스 구조, 구글시트, 메인PC 실시간 진단, 검증·배포 경로를 정리했습니다.

1.1.14 / 58.17.20은 인증 재발급이 계속 거절될 때 발생하는 반복 발급과 자산 조회의 거절 토큰 재사용을 수정합니다. 재시도 간격을 제한하고 정상 조회 후 자동 복구하며, 기존 실주문 승인과 새 계좌 대조 두 번을 유지합니다. 최초 서버 거부의 원인은 미확정으로 남기고, 토큰을 노출하지 않는 진단을 추가합니다. [릴리스 설명](releases/1.1.14/RELEASE_NOTES.md)과 [검증 상태](releases/1.1.14/STATUS.md)를 확인하세요.

현재 전체 소스는 [CURRENT_SOURCE.json](CURRENT_SOURCE.json)에 고정되어 있습니다. `python tools/Prepare-Source.py --dest ../Avata-working`으로 해시를 확인한 별도 작업 사본을 만듭니다. `source/`는 변경 파일 발췌본입니다.

[최신 공개 릴리스](https://github.com/crosnuu12/Avata-kor-releases/releases/latest) · [서명된 자동업데이트 피드](https://github.com/crosnuu12/Avata-kor-releases/releases/latest/download/avata-update.json)

앱의 업데이트 버튼을 사용하면 기존 중지·미체결 확인 절차를 거쳐 적용합니다. 공개 배포 버전과 실제 설치 버전은 구분하며, 설치 여부는 메인PC 진단에서 확인합니다.

중단한 미니PC 구성은 [archive/minipc-20261105](https://github.com/crosnuu12/Avata-kor-releases/tree/archive/minipc-20261105)에 보관합니다. 이전 서명 릴리스는 복구를 위해 유지합니다. 실제 시트 식별자·개인 진단·계좌·인증키는 공개 저장소에 포함하지 않습니다.
