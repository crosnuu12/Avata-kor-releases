"""Build a deterministic public package and sign using an explicitly supplied local key."""
import argparse, base64, hashlib, json, shutil, zipfile, datetime
from pathlib import Path
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

def digest(b): return hashlib.sha256(b).hexdigest()
def js(o): return json.dumps(o,ensure_ascii=False,separators=(',',':')).encode()

def main():
    p=argparse.ArgumentParser();p.add_argument('--candidate',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--key-file',type=Path,required=True);a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(a.candidate) as z:
        manifest=z.read('bundle/release.json');m=json.loads(manifest)
        assert m['Version']=='58.17.13' and len(m['Files'])==12
        package=a.output/'Avata_kor-58.17.13.zip'
        with zipfile.ZipFile(package,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as out:
            for name in sorted(['release.json']+[f['Name'] for f in m['Files']]):
                raw=z.read('bundle/'+name)
                if name!='release.json':
                    f=next(f for f in m['Files'] if f['Name']==name)
                    assert len(raw)==f['Size'] and digest(raw)==f['Hash']
                info=zipfile.ZipInfo(name,(2026,11,5,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED;info.external_attr=0o100644<<16
                out.writestr(info,raw,compresslevel=9)
    key=serialization.load_pem_private_key(a.key_file.read_bytes(),password=None)
    public=key.public_key();assert digest(public.public_bytes(serialization.Encoding.DER,serialization.PublicFormat.SubjectPublicKeyInfo))=='70c8289ed2e4727725e36c9016e201f287e8f9665fa8ea520f2df4e149a334ac'
    raw=package.read_bytes()
    payload=js(dict(Schema='AVATA-UPDATE-1',App='Avata_kor',Version='58.17.13',Id=m['Id'],ManifestHash=digest(manifest),PackageUrl='https://github.com/crosnuu12/Avata-kor-releases/releases/download/v58.17.13/Avata_kor-58.17.13.zip',PackageBytes=len(raw),PackageSha256=digest(raw),PublishedUtc=datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00','Z')))
    sig=key.sign(payload,padding.PKCS1v15(),hashes.SHA256());public.verify(sig,payload,padding.PKCS1v15(),hashes.SHA256())
    (a.output/'avata-update.json').write_bytes(js(dict(Schema='AVATA-UPDATE-SIGNED-1',Payload=base64.b64encode(payload).decode(),Signature=base64.b64encode(sig).decode())))
    shutil.copyfile(a.candidate,a.output/'Avata_58.17.13_Verification.zip')
    (a.output/'SHA256SUMS.txt').write_text(''.join(f'{digest(f.read_bytes())}  {f.name}\n' for f in sorted(a.output.iterdir()) if f.is_file() and f.name!='SHA256SUMS.txt'))
    print(json.dumps(dict(Version='58.17.13',Id=m['Id'],PackageSha256=digest(raw),PackageBytes=len(raw),ManifestHash=digest(manifest))))
if __name__=='__main__':main()
