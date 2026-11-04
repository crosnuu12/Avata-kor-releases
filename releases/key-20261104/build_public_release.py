"""Sign an exact validated candidate locally; only public artifacts enter GitHub."""
import argparse
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import sys
import zipfile

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

KEY_FINGERPRINT = '70c8289ed2e4727725e36c9016e201f287e8f9665fa8ea520f2df4e149a334ac'
RECOVERY = 'Avata_Update_Key_Recovery_1.1.2.zip'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def zip_public(directory, target):
    with zipfile.ZipFile(target, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for p in sorted(directory.rglob('*')):
            if p.is_file():
                info = zipfile.ZipInfo(p.relative_to(directory).as_posix(), (2026, 11, 4, 0, 0, 0))
                info.create_system = 3
                info.external_attr = 0o100644 << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                z.writestr(info, p.read_bytes(), compresslevel=9)


def build(candidate, key_path, output, base_packager):
    source = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location('verified_base_packager', base_packager)
    base = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(base)
    kit_bytes, _, old_public = base.verified_candidate(candidate)
    public = serialization.load_pem_public_key((source / 'public-key.pem').read_bytes())
    fingerprint = sha(public.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo))
    base.require(isinstance(public, rsa.RSAPublicKey) and fingerprint == KEY_FINGERPRINT, 'ROTATION_PUBLIC_KEY_CHANGED')
    key = base.read_private(key_path.read_bytes(), None, public.public_numbers())
    base.build(candidate, output)
    payload_path = output / 'UNSIGNED-update-payload.json'
    payload = payload_path.read_bytes()
    signature = key.sign(payload, padding.PKCS1v15(), hashes.SHA256())
    public.verify(signature, payload, padding.PKCS1v15(), hashes.SHA256())
    envelope = {'Schema': 'AVATA-UPDATE-SIGNED-1', 'Payload': base64.b64encode(payload).decode(),
                'Signature': base64.b64encode(signature).decode()}
    (output / 'avata-update.json').write_bytes(base.json_bytes(envelope))
    payload_path.unlink()
    recovery = output / 'recovery'
    (recovery / 'verifier').mkdir(parents=True)
    new_xml = (source / 'public-key.xml').read_bytes()
    base.require(base.public_from_updater("function Up-PublicKey { return '" + new_xml.decode() + "' }") == public.public_numbers(), 'PUBLIC_XML_MISMATCH')
    variants = []
    with zipfile.ZipFile(candidate) as z:
        for name in ('tests/original/At58.Update.ps1', 'host/At58.Update.ps1'):
            raw = z.read(name)
            old_xml = re.search(rb"function Up-PublicKey\s*\{\s*return\s*'(<RSAKeyValue>.*?</RSAKeyValue>)'", raw).group(1)
            base.require(raw.count(old_xml) == 1, 'TRUST_ANCHOR_COUNT')
            changed = raw.replace(old_xml, new_xml)
            row = {'Before': sha(raw), 'After': sha(changed), 'Source': name}
            if row['Before'] not in {v['Before'] for v in variants}:
                variants.append(row)
            if name.startswith('host/'):
                (recovery / 'verifier/At58.Update.ps1').write_bytes(changed)
        (recovery / 'verifier/At58.Ops.ps1').write_bytes(z.read('host/At58.Ops.ps1'))
    (recovery / 'old-public-key.xml').write_bytes(old_xml)
    (recovery / 'public-key.xml').write_bytes(new_xml)
    for name in ('avata-update.json', base.PACKAGE):
        shutil.copyfile(output / name, recovery / name)
    manifest = {'Schema': 'AVATA-TRUST-RECOVERY-1', 'KeyId': 'avata-update-20261104',
                'PublicKeySha256': fingerprint, 'Updaters': variants,
                'Files': [{'Name': p.relative_to(recovery).as_posix(), 'Sha256': sha(p.read_bytes())}
                          for p in sorted(recovery.rglob('*')) if p.is_file()]}
    manifest_raw = base.json_bytes(manifest)
    (recovery / 'recovery.json').write_bytes(manifest_raw)
    template = (source / 'Recover-Update-Key.template.ps1').read_text(encoding='utf-8')
    installer = template.replace('__MANIFEST_HASH__', sha(manifest_raw))
    (recovery / 'Recover-Update-Key.ps1').write_bytes(installer.replace('\r\n', '\n').replace('\n', '\r\n').encode('utf-8-sig'))
    cmd = '@echo off\r\ncd /d "%~dp0"\r\n"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Recover-Update-Key.ps1"\r\necho.\r\npause\r\n'
    (recovery / 'Apply_New_Update_Key.cmd').write_bytes(cmd.encode('ascii'))
    readme = ('Avata 업데이트 키 복구 (1회 적용)\n\n'
              '1. 아바타에서 실주문을 정지하고 프로그램을 완전히 종료합니다.\n'
              '2. 이 ZIP을 압축 해제합니다.\n'
              '3. Apply_New_Update_Key.cmd를 더블클릭합니다.\n'
              '4. 완료 문구를 확인한 뒤 기존 Avata_kor를 실행합니다.\n'
              '5. 1.1.2 업데이트와 계좌 조회 상태를 확인하고 필요한 경우 실주문을 직접 재개합니다.\n\n'
              '아바타가 설치된 각 PC에서 한 번씩 적용하세요.\n'
              '계좌 인증정보, 시트 설정, 매매 원장, 주문 설정은 수정하지 않습니다.\n'
              '이 도구는 프로그램이나 실주문을 자동으로 시작하지 않습니다.\n'
              '교체 전 업데이트 파일은 설치 폴더의 trust-key-backups에 자동 보관합니다.\n'
              '개인키는 포함되지 않습니다. 설치 PC에 개인키를 입력할 필요가 없습니다.\n'
              '실패하면 진단 코드만 전달하세요. 설정을 지우거나 재설치하지 마세요.\n\n'
              '공개키 SHA-256: ' + fingerprint + '\n')
    (recovery / 'README_KO.txt').write_bytes(readme.encode('utf-8-sig'))
    zip_public(recovery, output / RECOVERY)
    sums = ''.join(f'{sha(p.read_bytes())}  {p.name}\n' for p in sorted(output.iterdir())
                   if p.is_file() and p.name != 'SHA256SUMS.txt')
    (output / 'SHA256SUMS.txt').write_text(sums, encoding='ascii')
    # Explicitly inspect the complete outgoing allowlist, including ZIP members.
    forbidden = (b'-----BEGIN PRIVATE KEY-----', b'-----BEGIN RSA PRIVATE KEY-----', b'<P>', b'<D>')
    for p in output.iterdir():
        if not p.is_file():
            continue
        if p.suffix == '.zip':
            with zipfile.ZipFile(p) as z:
                for member in z.namelist():
                    if any(marker in z.read(member) for marker in forbidden):
                        # Existing test code mentions PEM headers as rejection patterns;
                        # actual generated key bytes are always forbidden everywhere.
                        base.require(key_path.read_bytes().strip() not in z.read(member), 'PRIVATE_KEY_IN_OUTPUT')
        base.require(key_path.read_bytes().strip() not in p.read_bytes(), 'PRIVATE_KEY_IN_OUTPUT')
    return {'Version': base.VERSION, 'PublicKeySha256': fingerprint,
            'RecoverySha256': sha((output / RECOVERY).read_bytes()), 'PrivateKeyPublished': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--candidate', required=True, type=Path)
    parser.add_argument('--key-file', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--base-packager', type=Path, default=Path(__file__).resolve().parent.parent / '1.1.2/package_release.py')
    args = parser.parse_args()
    try:
        print(json.dumps(build(args.candidate, args.key_file, args.output, args.base_packager)))
    except Exception as exc:
        code = str(exc) if isinstance(exc, ValueError) and re.fullmatch('[A-Z0-9_]+', str(exc)) else 'ROTATED_RELEASE_BUILD_FAILED'
        print(code, file=sys.stderr)
        sys.exit(1)
