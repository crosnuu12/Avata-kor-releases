# Avata

프로젝트 작업은 [길잡이](PROJECT_INDEX.md)에서 시작합니다. 소스 구조, 구글시트, 메인PC 실시간 진단, 검증·배포 경로를 정리했습니다.

1.1.6 / 58.17.12는 시트 표시 데이터의 변경분 전송, 자산 서식 반복 갱신 제거, 필요한 만큼 행 확장을 적용합니다. 전략 입력과 거래 판단 주기는 유지합니다. [릴리스 설명](releases/1.1.6/RELEASE_NOTES.md)과 [검증 상태](releases/1.1.6/STATUS.md)를 확인하세요.

현재 전체 소스는 [CURRENT_SOURCE.json](CURRENT_SOURCE.json)에 고정되어 있습니다. `python tools/Prepare-Source.py --dest ../Avata-working`으로 해시를 확인한 별도 작업 사본을 만듭니다. `source/`는 변경 파일 발췌본입니다.

[최신 공개 릴리스](https://github.com/crosnuu12/Avata-kor-releases/releases/latest) · [서명된 자동업데이트 피드](https://github.com/crosnuu12/Avata-kor-releases/releases/latest/download/avata-update.json)

앱의 업데이트 버튼을 사용하면 기존 중지·미체결 확인 절차를 거쳐 적용합니다. 공개 배포 버전과 실제 설치 버전은 구분하며, 설치 여부는 메인PC 진단에서 확인합니다.

중단한 미니PC 구성은 [archive/minipc-20261105](https://github.com/crosnuu12/Avata-kor-releases/tree/archive/minipc-20261105)에 보관합니다. 이전 서명 릴리스는 복구를 위해 유지합니다. 실제 시트 식별자·개인 진단·계좌·인증키는 공개 저장소에 포함하지 않습니다.
