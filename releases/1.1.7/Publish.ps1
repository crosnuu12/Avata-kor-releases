#requires -Version 5.1
param([string]$Assets,[string]$Kit,[string]$PublicKey)
$ErrorActionPreference='Stop'
. (Join-Path $Kit 'host/At58.Ops.ps1')
. (Join-Path $Kit 'host/At58.Update.ps1')
$script:ReleasePublicKey=[IO.File]::ReadAllText($PublicKey)
function Up-PublicKey {return $script:ReleasePublicKey}
$signed=Up-Envelope (Join-Path $Assets 'avata-update.json')
function Verify-Remote([string]$feed){
 $check=Join-Path $env:RUNNER_TEMP ('avata-public-'+[guid]::NewGuid().ToString('N'))
 try{
  Ops-WriteJson (Join-Path $check 'settings.json') @{Enabled=$true;FeedUrl=$feed}
  Ops-WriteJson (Join-Path $check 'active.json') @{Schema='AT58-OFFER-1';Id='bundle-11fc76ec177e6d55f3a300e6';Version='58.17.12';ManifestHash='16351c5443f98c741ea43304812c4e65b3d8443ca5a8e6282e2a990c0c46527e'}
  $r=Up-RemoteRefresh $check
  if($r.State -cne 'CHECKED' -or $r.Version -cne '58.17.13'){throw 'PUBLIC_UPDATE_FAILED'}
  $o=Up-Offer (Join-Path $check 'remote-channel');if($o.Id -cne $signed.Id -or $o.ManifestHash -cne $signed.ManifestHash){throw 'PUBLIC_IDENTITY_FAILED'}
 }finally{if(Test-Path $check){Remove-Item -LiteralPath $check -Recurse -Force}}
}
foreach($tag in @('v58.17.13','v1.1.7')){
 $preference=$ErrorActionPreference
 try{$ErrorActionPreference='Continue';$lookup=gh release view $tag --json isDraft 2>$null;$lookupExit=$LASTEXITCODE}finally{$ErrorActionPreference=$preference}
 if($lookupExit -eq 0){if(!(($lookup|ConvertFrom-Json).isDraft)){throw 'PUBLISHED_RELEASE_IS_IMMUTABLE'}}else{
  gh release create $tag --draft --target $env:GITHUB_SHA --title 'Avata 1.1.7 - Diagnostic archive' --notes-file releases/1.1.7/RELEASE_NOTES.md
  if($LASTEXITCODE -ne 0){throw 'CREATE_RELEASE_FAILED'}
 }
 gh release upload $tag (Join-Path $Assets 'Avata_kor-58.17.13.zip') (Join-Path $Assets 'Avata_58.17.13_Verification.zip') (Join-Path $Assets 'avata-update.json') (Join-Path $Assets 'SHA256SUMS.txt') --clobber
 if($LASTEXITCODE -ne 0){throw 'UPLOAD_FAILED'}
}
gh release edit v58.17.13 --draft=false --latest=false
if($LASTEXITCODE -ne 0){throw 'VERSION_PUBLICATION_FAILED'}
Verify-Remote 'https://github.com/crosnuu12/Avata-kor-releases/releases/download/v58.17.13/avata-update.json'
gh release edit v1.1.7 --draft=false --latest
if($LASTEXITCODE -ne 0){throw 'LATEST_PROMOTION_FAILED'}
Verify-Remote 'https://github.com/crosnuu12/Avata-kor-releases/releases/latest/download/avata-update.json'
Write-Output 'PUBLISHED AND VERIFIED: 1.1.7 / 58.17.13. Public auto-update signature and downloaded package passed. No real account or broker order used.'
