import base64,hashlib,json,sys,zipfile
from pathlib import Path
from cryptography.hazmat.primitives import hashes,serialization
from cryptography.hazmat.primitives.asymmetric import padding
root=Path(sys.argv[1]);assets=root/'assets';key=serialization.load_pem_public_key((root.parent/'key-20261104/public-key.pem').read_bytes())
sha=lambda b:hashlib.sha256(b).hexdigest()
assert sha(key.public_bytes(serialization.Encoding.DER,serialization.PublicFormat.SubjectPublicKeyInfo))=='70c8289ed2e4727725e36c9016e201f287e8f9665fa8ea520f2df4e149a334ac'
e=json.loads((assets/'avata-update.json').read_bytes());assert e['Schema']=='AVATA-UPDATE-SIGNED-1'
p=base64.b64decode(e['Payload'],validate=True);sig=base64.b64decode(e['Signature'],validate=True);key.verify(sig,p,padding.PKCS1v15(),hashes.SHA256());d=json.loads(p)
assert d['Version']=='58.17.15' and d['PackageUrl']=='https://github.com/crosnuu12/Avata-kor-releases/releases/download/v58.17.15/Avata_kor-58.17.15.zip'
package=assets/'Avata_kor-58.17.15.zip';assert sha(package.read_bytes())==d['PackageSha256'] and package.stat().st_size==d['PackageBytes']
with zipfile.ZipFile(package) as z,zipfile.ZipFile(assets/'Avata_58.17.15_Verification.zip') as kit:
    mraw=z.read('release.json');m=json.loads(mraw);assert sha(mraw)==d['ManifestHash'] and m['Id']==d['Id'] and m['Version']==d['Version']
    assert len(z.namelist())==13 and set(z.namelist())=={'release.json'}|{f['Name'] for f in m['Files']}
    for f in m['Files']:
        b=z.read(f['Name']);assert sha(b)==f['Hash'] and len(b)==f['Size'] and b==kit.read('bundle/'+f['Name'])
    for test in ['Test-PresentationWrites.ps1','Test-AssetOptimization.ps1','Test-DiagnosticArchive.ps1','Test-RejectResume.ps1']:
        assert test in kit.namelist() and len(kit.read(test))>0
    for n in z.namelist():
        b=z.read(n)
        assert b'PRIVATE KEY-----\nMII' not in b and b'private_key":' not in b and b'credentials.dpapi' not in n.encode()
for line in (assets/'SHA256SUMS.txt').read_text().splitlines():
    h,n=line.split('  ',1);assert sha((assets/n).read_bytes())==h
print('PUBLIC ASSETS: signature, package bytes, manifest, verification source and checksums verified')
