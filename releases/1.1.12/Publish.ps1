#requires -Version 5.1
param([string]$Assets,[string]$Kit,[string]$PublicKey)
$ErrorActionPreference='Stop'
. (Join-Path $Kit 'host/At58.Ops.ps1')
. (Join-Path $Kit 'host/At58.Update.ps1')
$script:ReleasePublicKey=[IO.File]::ReadAllText($PublicKey)
function Up-PublicKey {return $script:ReleasePublicKey}
$signed=Up-Envelope (Join-Path $Assets 'avata-update.json')
function Verify-Remote([string]$feed,[string]$baseId,[string]$baseVersion,[string]$baseHash){
 $check=Join-Path $env:RUNNER_TEMP ('avata-public-'+[guid]::NewGuid().ToString('N'))
 try{
  Ops-WriteJson (Join-Path $check 'settings.json') @{Enabled=$true;FeedUrl=$feed}
  Ops-WriteJson (Join-Path $check 'active.json') @{Schema='AT58-OFFER-1';Id=$baseId;Version=$baseVersion;ManifestHash=$baseHash}
  $r=Up-RemoteRefresh $check
  if($r.State -cne 'CHECKED' -or $r.Version -cne '58.17.18'){throw 'PUBLIC_UPDATE_FAILED'}
  $o=Up-Offer (Join-Path $check 'remote-channel');if($o.Id -cne $signed.Id -or $o.ManifestHash -cne $signed.ManifestHash){throw 'PUBLIC_IDENTITY_FAILED'}
 }finally{if(Test-Path $check){Remove-Item -LiteralPath $check -Recurse -Force}}
}
foreach($tag in @('v58.17.18','v1.1.12')){
 $preference=$ErrorActionPreference
 try{$ErrorActionPreference='Continue';$lookup=gh release view $tag --json isDraft 2>$null;$lookupExit=$LASTEXITCODE}finally{$ErrorActionPreference=$preference}
 $upload=$true
 if($lookupExit -eq 0){
  $existing=$lookup|ConvertFrom-Json
  if(!$existing.isDraft){$upload=$false;Write-Output "Existing published release retained: $tag"}
 }else{
  gh release create $tag --draft --target $env:GITHUB_SHA --title 'Avata 1.1.12 - Diagnostic path validation and worker error evidence' --notes-file releases/1.1.12/RELEASE_NOTES.md
  if($LASTEXITCODE -ne 0){throw 'CREATE_RELEASE_FAILED'}
 }
 if($upload){
  gh release upload $tag (Join-Path $Assets 'Avata_kor-58.17.18.zip') (Join-Path $Assets 'Avata_58.17.18_Verification.zip') (Join-Path $Assets 'avata-update.json') (Join-Path $Assets 'SHA256SUMS.txt') --clobber
  if($LASTEXITCODE -ne 0){throw 'UPLOAD_FAILED'}
 }
}
gh release edit v58.17.18 --draft=false --latest=false
if($LASTEXITCODE -ne 0){throw 'VERSION_PUBLICATION_FAILED'}
Verify-Remote 'https://github.com/crosnuu12/Avata-kor-releases/releases/download/v58.17.18/avata-update.json' 'bundle-11fc76ec177e6d55f3a300e6' '58.17.12' '16351c5443f98c741ea43304812c4e65b3d8443ca5a8e6282e2a990c0c46527e'
Verify-Remote 'https://github.com/crosnuu12/Avata-kor-releases/releases/download/v58.17.18/avata-update.json' 'bundle-3f617914608248bbb8f82310' '58.17.13' 'b20270433d38d4ba830a565d976e5ff07abf63a351f6dba3f79e1691212879a4'
Verify-Remote 'https://github.com/crosnuu12/Avata-kor-releases/releases/download/v58.17.18/avata-update.json' 'bundle-a9df92f616e201f74d83b9c0' '58.17.14' 'fe55e2d8a6031f18ffadc22d8d783a06b22757d4f55da9bd4a73fd7560b53f0e'
Verify-Remote 'https://github.com/crosnuu12/Avata-kor-releases/releases/download/v58.17.18/avata-update.json' 'bundle-5650b4ff96c851b288fe7e63' '58.17.15' '5b6f106a470e818f5502f3505d7ddadd84beba4b569d9105ae9545b73a74398e'
Verify-Remote 'https://github.com/crosnuu12/Avata-kor-releases/releases/download/v58.17.18/avata-update.json' 'bundle-38927a8011dc4625bf62c704' '58.17.16' 'fbf324e12a0238d670fe2da2d54be64f018b376e161c99229a7411f043aefb9f'
gh release edit v1.1.12 --draft=false --latest
if($LASTEXITCODE -ne 0){throw 'LATEST_PROMOTION_FAILED'}
Verify-Remote 'https://github.com/crosnuu12/Avata-kor-releases/releases/latest/download/avata-update.json' 'bundle-3f617914608248bbb8f82310' '58.17.13' 'b20270433d38d4ba830a565d976e5ff07abf63a351f6dba3f79e1691212879a4'
Verify-Remote 'https://github.com/crosnuu12/Avata-kor-releases/releases/latest/download/avata-update.json' 'bundle-a9df92f616e201f74d83b9c0' '58.17.14' 'fe55e2d8a6031f18ffadc22d8d783a06b22757d4f55da9bd4a73fd7560b53f0e'
Verify-Remote 'https://github.com/crosnuu12/Avata-kor-releases/releases/latest/download/avata-update.json' 'bundle-5650b4ff96c851b288fe7e63' '58.17.15' '5b6f106a470e818f5502f3505d7ddadd84beba4b569d9105ae9545b73a74398e'
Verify-Remote 'https://github.com/crosnuu12/Avata-kor-releases/releases/latest/download/avata-update.json' 'bundle-38927a8011dc4625bf62c704' '58.17.16' 'fbf324e12a0238d670fe2da2d54be64f018b376e161c99229a7411f043aefb9f'
Verify-Remote 'https://github.com/crosnuu12/Avata-kor-releases/releases/latest/download/avata-update.json' 'bundle-b2f445057bc7139ccabd9238' '58.17.17' '7b0f5fc64eb08d64e30c532fb70bfa8438871424da08462769aba1eb6c5fab46'
Write-Output 'PUBLISHED AND VERIFIED: 1.1.12 / 58.17.18. Public auto-update signature and downloaded package passed. No real account or broker order used.'
