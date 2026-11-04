"""Bind public pre-signed assets to the already-validated application bytes."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import zipfile

root = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('base', root.parent / '1.1.2/package_release.py')
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
candidate = Path(sys.argv[1])
assets = Path(sys.argv[2])
kit, content, old_public = base.verified_candidate(candidate)
with zipfile.ZipFile(assets / base.PACKAGE) as z:
    assert set(z.namelist()) == set(content) and len(z.namelist()) == len(content)
    assert all(z.read(name) == raw for name, raw in content.items())
with zipfile.ZipFile(assets / 'Avata_Update_Key_Recovery_1.1.2.zip') as z:
    names = z.namelist()
    assert len(names) == len(set(names))
    assert set(names) == {'Apply_New_Update_Key.cmd', 'Recover-Update-Key.ps1', 'README_KO.txt',
                          'recovery.json', 'public-key.xml', 'old-public-key.xml',
                          'verifier/At58.Ops.ps1', 'verifier/At58.Update.ps1',
                          'avata-update.json', base.PACKAGE}
    assert z.read('public-key.xml') == (root / 'public-key.xml').read_bytes()
    assert z.read('avata-update.json') == (assets / 'avata-update.json').read_bytes()
    assert z.read(base.PACKAGE) == (assets / base.PACKAGE).read_bytes()
    manifest_raw = z.read('recovery.json')
    manifest = json.loads(manifest_raw)
    assert manifest['PublicKeySha256'] == '70c8289ed2e4727725e36c9016e201f287e8f9665fa8ea520f2df4e149a334ac'
    template = (root / 'Recover-Update-Key.template.ps1').read_text(encoding='utf-8')
    script = template.replace('__MANIFEST_HASH__', base.digest(manifest_raw))
    assert z.read('Recover-Update-Key.ps1') == script.replace('\r\n', '\n').replace('\n', '\r\n').encode('utf-8-sig')
    for f in manifest['Files']:
        assert base.digest(z.read(f['Name'])) == f['Sha256']
    with zipfile.ZipFile(candidate) as old:
        for variant in manifest['Updaters']:
            raw = old.read(variant['Source'])
            assert base.digest(raw) == variant['Before']
            assert raw.count(z.read('old-public-key.xml')) == 1
            patched = raw.replace(z.read('old-public-key.xml'), z.read('public-key.xml'))
            assert base.digest(patched) == variant['After']
            if variant['Source'] == 'host/At58.Update.ps1':
                assert patched == z.read('verifier/At58.Update.ps1')
        assert old.read('host/At58.Ops.ps1') == z.read('verifier/At58.Ops.ps1')
    for name in names:
        assert not any(marker in z.read(name) for marker in (b'BEGIN PRIVATE KEY', b'BEGIN RSA PRIVATE KEY', b'<D>', b'<P>'))
for line in (assets / 'SHA256SUMS.txt').read_text().splitlines():
    digest, name = line.split('  ', 1)
    assert name in {base.PACKAGE, base.VERIFY_KIT, 'avata-update.json', 'Avata_Update_Key_Recovery_1.1.2.zip'}
    assert base.digest((assets / name).read_bytes()) == digest
print('PUBLIC ASSETS MATCH VERIFIED SOURCE; RECOVERY CHANGES ONLY PUBLIC TRUST KEY; NO PRIVATE KEY INCLUDED')
