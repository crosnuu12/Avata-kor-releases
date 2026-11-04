from pathlib import Path
import hashlib,json,zipfile
r=Path(__file__).resolve().parent
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
files=[dict(Name=p.relative_to(r/'bundle').as_posix(),Hash=sha(p),Size=p.stat().st_size) for p in sorted((r/'bundle').rglob('*.ps1'))]
assert len(files)==12
bid='bundle-'+hashlib.sha256(json.dumps(files,sort_keys=True).encode()).hexdigest()[:24]
(r/'bundle/release.json').write_text(json.dumps(dict(Schema='AT58-BUNDLE-1',HostProtocol=2,Mode='CONTROLLED_LIVE',Id=bid,Version='58.17.8',Files=files),separators=(',',':')),encoding='utf-8')
selected=[p for d in ['bundle','host','recovery','tests'] for p in (r/d).rglob('*') if p.is_file()]
selected += list(r.glob('Test-*.ps1'))+[r/'Run-Checks.ps1',r/'README.md']
out=r/'Avata_1.1.2_Telegram_Verification.zip'
with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED) as z:
 for p in sorted(selected):
  rel=p.relative_to(r).as_posix();assert p.suffix.lower() in {'.ps1','.json','.md','.txt'}
  assert not any(part.lower() in {'private-signing','credentials','logs'} for part in p.parts)
  assert not p.name.endswith('.dpapi')
  z.write(p,rel)
metadata=dict(Status='UNPUBLISHED_CANDIDATE',ProductVersion='1.1.2',InternalVersion='58.17.8',Id=bid,ManifestHash=sha(r/'bundle/release.json'),ArchiveSHA256=sha(out),ArchiveBytes=out.stat().st_size,NetworkTests='synthetic only',LiveInstalled=False)
(r/'candidate.json').write_text(json.dumps(metadata,indent=2),encoding='utf-8')
print(json.dumps(metadata))
