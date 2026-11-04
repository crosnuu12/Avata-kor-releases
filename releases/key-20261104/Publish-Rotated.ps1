#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$Assets,[Parameter(Mandatory=$true)][string]$Recovery)
$ErrorActionPreference='Stop'
. (Join-Path $Recovery 'verifier/At58.Ops.ps1')
. (Join-Path $Recovery 'verifier/At58.Update.ps1')
$signed=Up-Envelope (Join-Path $Assets 'avata-update.json')
function Verify-PublicFeed([string]$feed){
 $checkRoot=Join-Path $env:RUNNER_TEMP ('avata-public-'+[guid]::NewGuid().ToString('N'))
 try{
  Ops-WriteJson (Join-Path $checkRoot 'settings.json') @{Enabled=$true;FeedUrl=$feed}
  Ops-WriteJson (Join-Path $checkRoot 'active.json') @{Schema='AT58-OFFER-1';Id='bundle-c698595148d2fe89ffabb7c3';Version='58.17.7';ManifestHash='13f7a85352608b05a7b700e708959af597f38b4919b029b4a0e8a1e04f09fab2'}
  $remote=Up-RemoteRefresh $checkRoot
  if($remote.State -cne 'CHECKED' -or $remote.Version -cne '58.17.8'){throw 'PUBLIC_UPDATE_VERIFICATION_FAILED'}
  $offer=Up-Offer (Join-Path $checkRoot 'remote-channel')
  if($offer.Id -cne $signed.Id -or $offer.ManifestHash -cne $signed.ManifestHash){throw 'PUBLIC_UPDATE_IDENTITY'}
 }finally{if([IO.Directory]::Exists($checkRoot)){Remove-Item -LiteralPath $checkRoot -Recurse -Force}}
}
foreach($releaseTag in @('v58.17.8','v1.1.2')){
 $savedPreference=$ErrorActionPreference
 try{$ErrorActionPreference='Continue';$lookup=gh release view $releaseTag --json isDraft 2>$null;$lookupExit=$LASTEXITCODE}
 finally{$ErrorActionPreference=$savedPreference}
 if($lookupExit -eq 0){
  if(!(($lookup|ConvertFrom-Json).isDraft)){throw 'PUBLISHED_RELEASE_IS_IMMUTABLE'}
 }else{
  gh release create $releaseTag --draft --target $env:GITHUB_SHA --title 'Avata 1.1.2 (build 58.17.8) - new update key' --notes-file releases/key-20261104/RELEASE_NOTES.md
  if($LASTEXITCODE -ne 0){throw 'DRAFT_RELEASE_FAILED'}
 }
 gh release upload $releaseTag (Join-Path $Assets 'Avata_kor-58.17.8.zip') (Join-Path $Assets 'Avata_58.17.8_Verification.zip') (Join-Path $Assets 'Avata_Update_Key_Recovery_1.1.2.zip') (Join-Path $Assets 'avata-update.json') (Join-Path $Assets 'SHA256SUMS.txt') --clobber
 if($LASTEXITCODE -ne 0){throw 'RELEASE_UPLOAD_FAILED'}
}
gh release edit v58.17.8 --draft=false --latest=false
if($LASTEXITCODE -ne 0){throw 'VERSIONED_PUBLICATION_FAILED'}
Verify-PublicFeed 'https://github.com/crosnuu12/Avata-kor-releases/releases/download/v58.17.8/avata-update.json'
gh release edit v1.1.2 --draft=false --latest
if($LASTEXITCODE -ne 0){throw 'CHANNEL_PROMOTION_FAILED'}
Verify-PublicFeed 'https://github.com/crosnuu12/Avata-kor-releases/releases/latest/download/avata-update.json'
Write-Output 'PUBLISHED AND DOWNLOADED WITH SIGNATURE/HASH CHECKS: 1.1.2 / 58.17.8. Existing PCs require one-time public-key recovery. No real account or live order accessed.'
