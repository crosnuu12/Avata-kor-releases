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
  Ops-WriteJson (Join-Path $check 'active.json') @{Schema='AT58-OFFER-1';Id='bundle-5d6e0eb02f86ac466df09cea';Version='58.17.8';ManifestHash='062c855b611296d1a5d5998a836422c8bdf6f824ccf6cbfb3abc4c040693ca8e'}
  $r=Up-RemoteRefresh $check
  if($r.State -cne 'CHECKED' -or $r.Version -cne '58.17.9'){throw 'PUBLIC_UPDATE_FAILED'}
  $o=Up-Offer (Join-Path $check 'remote-channel');if($o.Id -cne $signed.Id -or $o.ManifestHash -cne $signed.ManifestHash){throw 'PUBLIC_IDENTITY_FAILED'}
 }finally{if(Test-Path $check){Remove-Item -LiteralPath $check -Recurse -Force}}
}
foreach($tag in @('v58.17.9','v1.1.3')){
 $preference=$ErrorActionPreference
 try{$ErrorActionPreference='Continue';$lookup=gh release view $tag --json isDraft 2>$null;$lookupExit=$LASTEXITCODE}finally{$ErrorActionPreference=$preference}
 if($lookupExit -eq 0){if(!(($lookup|ConvertFrom-Json).isDraft)){throw 'PUBLISHED_RELEASE_IS_IMMUTABLE'}}else{
  gh release create $tag --draft --target $env:GITHUB_SHA --title 'Avata 1.1.3 - Main PC live diagnostics' --notes-file releases/1.1.3/RELEASE_NOTES.md
  if($LASTEXITCODE -ne 0){throw 'CREATE_RELEASE_FAILED'}
 }
 gh release upload $tag (Join-Path $Assets 'Avata_kor-58.17.9.zip') (Join-Path $Assets 'Avata_58.17.9_Verification.zip') (Join-Path $Assets 'avata-update.json') (Join-Path $Assets 'SHA256SUMS.txt') --clobber
 if($LASTEXITCODE -ne 0){throw 'UPLOAD_FAILED'}
}
gh release edit v58.17.9 --draft=false --latest=false
if($LASTEXITCODE -ne 0){throw 'VERSION_PUBLICATION_FAILED'}
Verify-Remote 'https://github.com/crosnuu12/Avata-kor-releases/releases/download/v58.17.9/avata-update.json'
gh release edit v1.1.3 --draft=false --latest
if($LASTEXITCODE -ne 0){throw 'LATEST_PROMOTION_FAILED'}
Verify-Remote 'https://github.com/crosnuu12/Avata-kor-releases/releases/latest/download/avata-update.json'
Write-Output 'PUBLISHED AND VERIFIED: 1.1.3 / 58.17.9. Public auto-update signature and downloaded package passed. No real account or broker order used.'
