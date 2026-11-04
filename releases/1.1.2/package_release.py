"""Build the verified update; sign only with the existing installed trust key."""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET
import zipfile

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

CANDIDATE_SHA256 = '82d52ac404ca2929c718ccc0a5015790f5e09252b3bdbd9d68f6532d4d7b7f32'
MANIFEST_SHA256 = '062c855b611296d1a5d5998a836422c8bdf6f824ccf6cbfb3abc4c040693ca8e'
BUNDLE_ID = 'bundle-5d6e0eb02f86ac466df09cea'
VERSION = '58.17.8'
PACKAGE = 'Avata_kor-58.17.8.zip'
VERIFY_KIT = 'Avata_58.17.8_Verification.zip'
PACKAGE_URL = 'https://github.com/crosnuu12/Avata-kor-releases/releases/download/v58.17.8/' + PACKAGE
FILES = {
    'At58.Manager.ps1', 'At58.Ops.ps1', 'At58.Repair.ps1', 'At58.Telegram.ps1',
    'At58.Sheets.ps1', 'At58.SheetsJwt.ps1', 'At58.SheetWorker.ps1',
    'payload/At58.Core.ps1', 'payload/At58.Log.ps1',
    'payload/esbada_Merits_AT_v58.ps1', 'payload/Test-AT58.ps1',
    'payload/Test-AT58LogViewer.ps1',
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def require(ok, code):
    if not ok:
        raise ValueError(code)


def json_bytes(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode('utf-8')


def xml_int(root, name):
    value = root.findtext(name)
    require(bool(value), 'SIGNING_KEY_INVALID')
    return int.from_bytes(base64.b64decode(value, validate=True), 'big')


def public_from_updater(text):
    match = re.search(r'function Up-PublicKey\s*\{\s*return\s*\x27(<RSAKeyValue>.*?</RSAKeyValue>)\x27', text)
    require(match is not None, 'PINNED_PUBLIC_KEY_MISSING')
    root = ET.fromstring(match.group(1))
    return rsa.RSAPublicNumbers(xml_int(root, 'Exponent'), xml_int(root, 'Modulus'))


def read_private(data, password, expected):
    try:
        clean = (data.decode('utf-16').encode('utf-8') if data.startswith((b'\xff\xfe', b'\xfe\xff'))
                 else data.removeprefix(b'\xef\xbb\xbf')).strip()
        if clean.startswith(b'<RSAKeyValue>'):
            require(password is None, 'SIGNING_KEY_INVALID')
            root = ET.fromstring(clean)
            key = rsa.RSAPrivateNumbers(
                xml_int(root, 'P'), xml_int(root, 'Q'), xml_int(root, 'D'),
                xml_int(root, 'DP'), xml_int(root, 'DQ'), xml_int(root, 'InverseQ'),
                rsa.RSAPublicNumbers(xml_int(root, 'Exponent'), xml_int(root, 'Modulus')),
            ).private_key()
        else:
            key = serialization.load_pem_private_key(clean, password=password)
        require(isinstance(key, rsa.RSAPrivateKey), 'SIGNING_KEY_INVALID')
        require(key.key_size == 3072 and key.public_key().public_numbers() == expected,
                'SIGNING_KEY_DOES_NOT_MATCH_INSTALLED_APP')
        return key
    except ValueError as exc:
        if str(exc) == 'SIGNING_KEY_DOES_NOT_MATCH_INSTALLED_APP':
            raise
        raise ValueError('SIGNING_KEY_INVALID') from None
    except Exception:
        raise ValueError('SIGNING_KEY_INVALID') from None


def verified_candidate(path):
    data = path.read_bytes()
    require(digest(data) == CANDIDATE_SHA256, 'CANDIDATE_HASH')
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), 'DUPLICATE_ARCHIVE_ENTRY')
        manifest_data = archive.read('bundle/release.json')
        require(digest(manifest_data) == MANIFEST_SHA256, 'MANIFEST_HASH')
        manifest = json.loads(manifest_data)
        require(manifest['Id'] == BUNDLE_ID and manifest['Version'] == VERSION and
                manifest['HostProtocol'] == 2 and manifest['Mode'] == 'CONTROLLED_LIVE',
                'BUNDLE_IDENTITY')
        require({f['Name'] for f in manifest['Files']} == FILES and
                len(manifest['Files']) == len(FILES), 'BUNDLE_FILE_LIST')
        content = {'release.json': manifest_data}
        for item in manifest['Files']:
            raw = archive.read('bundle/' + item['Name'])
            require(digest(raw) == item['Hash'] and len(raw) == item['Size'], 'BUNDLE_FILE_HASH')
            content[item['Name']] = raw
        pinned = public_from_updater(archive.read('tests/original/At58.Update.ps1').decode('utf-8-sig'))
        current = public_from_updater(archive.read('host/At58.Update.ps1').decode('utf-8-sig'))
        require(pinned == current, 'PINNED_PUBLIC_KEY_CHANGED')
    return data, content, pinned


def build(candidate, output, signing_data=None, password=None):
    kit, content, pinned = verified_candidate(candidate)
    # Validate the private key before any signed artifacts can be emitted.
    key = read_private(signing_data, password, pinned) if signing_data else None
    require(not output.exists() or not any(output.iterdir()), 'OUTPUT_MUST_BE_EMPTY')
    output.mkdir(parents=True, exist_ok=True)
    package_path = output / PACKAGE
    with zipfile.ZipFile(package_path, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in sorted(content):
            info = zipfile.ZipInfo(name, date_time=(2026, 11, 4, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, content[name], compresslevel=9)
    package_bytes = package_path.read_bytes()
    payload = {
        'Schema': 'AVATA-UPDATE-1', 'App': 'Avata_kor', 'Version': VERSION,
        'Id': BUNDLE_ID, 'ManifestHash': MANIFEST_SHA256, 'PackageUrl': PACKAGE_URL,
        'PackageBytes': len(package_bytes), 'PackageSha256': digest(package_bytes),
        'PublishedUtc': dt.datetime.now(dt.timezone.utc).isoformat().replace('+00:00', 'Z'),
    }
    payload_bytes = json_bytes(payload)
    if key:
        signature = key.sign(payload_bytes, padding.PKCS1v15(), hashes.SHA256())
        pinned.public_key().verify(signature, payload_bytes, padding.PKCS1v15(), hashes.SHA256())
        require(len(signature) == 384, 'SIGNATURE_SIZE')
        envelope = {'Schema': 'AVATA-UPDATE-SIGNED-1',
                    'Payload': base64.b64encode(payload_bytes).decode('ascii'),
                    'Signature': base64.b64encode(signature).decode('ascii')}
        (output / 'avata-update.json').write_bytes(json_bytes(envelope))
    else:
        # This filename is deliberately not the production update-feed filename.
        (output / 'UNSIGNED-update-payload.json').write_bytes(payload_bytes)
    (output / VERIFY_KIT).write_bytes(kit)
    hashes_text = ''.join(f'{digest(p.read_bytes())}  {p.name}\n'
                          for p in sorted(output.iterdir()) if p.is_file())
    (output / 'SHA256SUMS.txt').write_text(hashes_text, encoding='ascii')
    return {'Version': VERSION, 'Signed': key is not None,
            'PackageSha256': payload['PackageSha256'], 'PackageBytes': payload['PackageBytes'],
            'CandidateSha256': CANDIDATE_SHA256, 'ManifestHash': MANIFEST_SHA256,
            'PublicKeySha256': digest(pinned.public_key().public_bytes(
                serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo))}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--candidate', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--sign', action='store_true')
    parser.add_argument('--key-file', type=Path)
    args = parser.parse_args()
    key_data = None
    password = None
    if args.sign:
        if args.key_file:
            key_data = args.key_file.read_bytes()
        else:
            key_data = os.environ.get('AVATA_UPDATE_SIGNING_KEY', '').encode('utf-8')
        require(bool(key_data.strip()), 'SIGNING_KEY_MISSING')
        secret_password = os.environ.get('AVATA_UPDATE_SIGNING_PASSWORD', '')
        password = secret_password.encode('utf-8') if secret_password else None
    else:
        require(args.key_file is None, 'SIGNING_MODE_REQUIRED')
    print(json.dumps(build(args.candidate, args.output, key_data, password)))


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        # Never expose exception details from key parsers or filesystem paths.
        code = str(exc) if isinstance(exc, ValueError) and re.fullmatch('[A-Z0-9_]+', str(exc)) else 'RELEASE_PREPARATION_FAILED'
        print(code, file=sys.stderr)
        sys.exit(1)
