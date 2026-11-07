"""Apply a pinned source-only candidate; never touches installed app state."""
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
core = root / 'bundle' / 'payload' / 'At58.Core.ps1'
spec = json.loads(Path(__file__).with_name('edits.json').read_text(encoding='utf-8'))
before = core.read_bytes()
if hashlib.sha256(before).hexdigest() != spec['BaseSHA256']:
    raise SystemExit('BASE_CORE_MISMATCH')
text = before.decode('utf-8-sig').replace('\r\n', '\n')
for edit in spec['Edits']:
    if text.count(edit['Before']) != 1:
        raise SystemExit('EDIT_CONTEXT_MISMATCH')
    text = text.replace(edit['Before'], edit['After'], 1)
after = b'\xef\xbb\xbf' + text.replace('\n', '\r\n').encode('utf-8')
if hashlib.sha256(after).hexdigest() != spec['CandidateSHA256']:
    raise SystemExit('CANDIDATE_CORE_MISMATCH')
core.write_bytes(after)
print('SOURCE_CANDIDATE_APPLIED; installed app and signed release unchanged')
