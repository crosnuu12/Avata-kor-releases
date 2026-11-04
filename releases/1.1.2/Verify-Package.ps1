param([Parameter(Mandatory=$true)][string]$Kit,[Parameter(Mandatory=$true)][string]$Assets,[switch]$RequireSignature)
$ErrorActionPreference='Stop'
$expectedId='bundle-5d6e0eb02f86ac466df09cea'
$expectedManifest='062c855b611296d1a5d5998a836422c8bdf6f824ccf6cbfb3abc4c040693ca8e'
foreach($line in Get-Content -LiteralPath (Join-Path $Assets 'SHA256SUMS.txt')){
 if($line -cnotmatch '^([a-f0-9]{64})  ([A-Za-z0-9_.-]+)$'){throw 'HASH_FORMAT'}
 if((Get-FileHash -LiteralPath (Join-Path $Assets $Matches[2]) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Matches[1]){throw 'HASH_MISMATCH'}
}
foreach($hostKind in @('tests/original','host')){
 . (Join-Path $Kit ($hostKind+'/At58.Ops.ps1'))
 . (Join-Path $Kit ($hostKind+'/At58.Update.ps1'))
 if($RequireSignature){$offer=Up-Envelope (Join-Path $Assets 'avata-update.json')}
 else{
  if(Test-Path -LiteralPath (Join-Path $Assets 'avata-update.json')){throw 'UNEXPECTED_SIGNED_FEED'}
  $offer=Get-Content -LiteralPath (Join-Path $Assets 'UNSIGNED-update-payload.json') -Raw|ConvertFrom-Json
 }
 if($offer.Version -cne '58.17.8' -or $offer.Id -cne $expectedId -or $offer.ManifestHash -cne $expectedManifest){throw 'RELEASE_IDENTITY'}
 $temporary=Join-Path ([IO.Path]::GetTempPath()) ('AvataReleaseCheck-'+[guid]::NewGuid().ToString('N'))
 try{Up-Extract (Join-Path $Assets 'Avata_kor-58.17.8.zip') $temporary $offer}
 finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Recurse -Force}}
 Write-Output ('PACKAGE VERIFIED WITH '+$hostKind+' UPDATER; signature checked: '+[bool]$RequireSignature)
}
