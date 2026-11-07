# Avata

프로젝트 작업은 [길잡이](PROJECT_INDEX.md)에서 시작합니다. 소스 구조, 구글시트, 메인PC 실시간 진단, 검증·배포 경로를 정리했습니다.

1.1.10 / 58.17.16은 **거부 주문 확인 후 복구** 버튼을 제공합니다. 메리츠 앱과 시트 확인 후 새 계좌 조회 두 번과 체결일지 반영 증거를 대조하고, 실주문이 꺼진 상태로 복구합니다. 별도의 실주문 시작이 필요하며, 새 거부·불확실 주문은 계속 차단합니다. [릴리스 설명](releases/1.1.10/RELEASE_NOTES.md)과 [검증 상태](releases/1.1.10/STATUS.md)를 확인하세요.

현재 전체 소스는 [CURRENT_SOURCE.json](CURRENT_SOURCE.json)에 고정되어 있습니다. `python tools/Prepare-Source.py --dest ../Avata-working`으로 해시를 확인한 별도 작업 사본을 만듭니다. `source/`는 변경 파일 발췌본입니다.

[최신 공개 릴리스](https://github.com/crosnuu12/Avata-kor-releases/releases/latest) · [서명된 자동업데이트 피드](https://github.com/crosnuu12/Avata-kor-releases/releases/latest/download/avata-update.json)

앱의 업데이트 버튼을 사용하면 기존 중지·미체결 확인 절차를 거쳐 적용합니다. 공개 배포 버전과 실제 설치 버전은 구분하며, 설치 여부는 메인PC 진단에서 확인합니다.

중단한 미니PC 구성은 [archive/minipc-20261105](https://github.com/crosnuu12/Avata-kor-releases/tree/archive/minipc-20261105)에 보관합니다. 이전 서명 릴리스는 복구를 위해 유지합니다. 실제 시트 식별자·개인 진단·계좌·인증키는 공개 저장소에 포함하지 않습니다.
