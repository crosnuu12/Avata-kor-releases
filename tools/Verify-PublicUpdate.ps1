#requires -Version 5.1
param([string]$AssetRoot, [string]$WorkRoot)
$ErrorActionPreference = 'Stop'
if (!$AssetRoot -or !$WorkRoot) { throw 'VERIFY_ARGUMENTS_REQUIRED' }
if ([IO.Directory]::Exists($WorkRoot)) { throw 'VERIFY_ROOT_EXISTS' }
[void][IO.Directory]::CreateDirectory($WorkRoot)
$kitZip = Join-Path $AssetRoot 'Avata_58.17.2_Update_Kit.zip'
if ((Get-FileHash $kitZip -Algorithm SHA256).Hash.ToLowerInvariant() -cne '4a4bb2a129fe844e89fe406d590eb94248ff8602de82aee2191541f3a67db94e') { throw 'VALIDATED_KIT_HASH' }
$kit = Join-Path $WorkRoot 'kit'
Expand-Archive $kitZip $kit
. (Join-Path $kit 'tests/original/At58.Ops.ps1')
. (Join-Path $kit 'tests/original/At58.Update.ps1')
$hostRoot = Join-Path $WorkRoot 'synthetic-host'
$feed = 'https://github.com/crosnuu12/Avata-kor-releases/releases/latest/download/avata-update.json'
$old = Ops-ReadJson (Join-Path $kit 'tests/original/channel/ready.json')
$expected = Ops-ReadJson (Join-Path $kit 'offer.json')
Ops-WriteJson (Join-Path $hostRoot 'settings.json') @{Enabled=$true; FeedUrl=$feed}
Ops-WriteJson (Join-Path $hostRoot 'active.json') $old
$remote = Up-RemoteRefresh $hostRoot
if ($remote.State -cne 'CHECKED' -or $remote.Version -cne $expected.Version) { throw ('PUBLIC_FEED_FAILED_' + $remote.Code) }
$offer = Up-Offer (Join-Path $hostRoot 'remote-channel')
if (!$offer -or $offer.Id -cne $expected.Id -or $offer.ManifestHash -cne $expected.ManifestHash) { throw 'PUBLIC_BUNDLE_IDENTITY' }
$available = Up-AvailableState $true $offer $false $false $feed $remote $old ''
if ($available -cne 'AVAILABLE') { throw 'OLD_VERSION_DETECTION' }
Ops-WriteJson (Join-Path $hostRoot 'active.json') $expected
$remote = Up-RemoteRefresh $hostRoot
if ($remote.State -cne 'CHECKED') { throw ('SAME_VERSION_FAILED_' + $remote.Code) }
$current = Up-AvailableState $true $null $false $false $feed $remote $expected ''
if ($current -cne 'CURRENT') { throw 'SAME_VERSION_NOT_CURRENT' }
$downloadedKit = Join-Path $WorkRoot 'public-kit.zip'
Up-Download 'https://github.com/crosnuu12/Avata-kor-releases/releases/download/v58.17.2/Avata_58.17.2_Update_Kit.zip' $downloadedKit 25000000
if ((Ops-Hash $downloadedKit) -cne (Ops-Hash $kitZip)) { throw 'PUBLIC_KIT_HASH' }
Write-Output 'PASS old 58.17.0 updater downloaded and verified public signed 58.17.2'
Write-Output 'PASS old installed version shows AVAILABLE'
Write-Output 'PASS matching installed 58.17.2 shows CURRENT without version reuse error'
Write-Output 'PASS public update kit matches validated package hash'
Write-Output 'PUBLIC FEED CHECKS PASSED; isolated synthetic host; no broker access or orders.'
