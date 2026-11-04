#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$Recovery,[Parameter(Mandatory=$true)][string]$Candidate)
$ErrorActionPreference='Stop'
$Recovery=[IO.Path]::GetFullPath($Recovery);$Candidate=[IO.Path]::GetFullPath($Candidate)
. (Join-Path $Recovery 'Recover-Update-Key.ps1')
. (Join-Path $Recovery 'verifier/At58.Ops.ps1')
. (Join-Path $Recovery 'verifier/At58.Update.ps1')
$script:passed=0
function Check($ok,[string]$name){if(!$ok){throw ('FAILED: '+$name)};$script:passed++;Write-Output ('PASS '+$name)}
function Reject([scriptblock]$action,[string]$code){$actual='';try{$null=& $action}catch{$actual=$_.Exception.Message};Check ($actual -ceq $code) ('reject '+$code)}
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('avata-rotation-tests-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
function Fixture([string]$updater='tests/original/At58.Update.ps1'){
 $base=Join-Path $scratch ([guid]::NewGuid().ToString('N'));$root=Join-Path $base 'esbada_AT_host'
 foreach($d in @($root,(Join-Path $base 'esbada_AT_manage'),(Join-Path $base 'esbada_AT_direct'),(Join-Path $root 'bundles'))){[void][IO.Directory]::CreateDirectory($d)}
 Copy-Item -LiteralPath (Join-Path $Candidate 'bundle') -Destination (Join-Path $root 'bundles/bundle-5d6e0eb02f86ac466df09cea') -Recurse
 Copy-Item -LiteralPath (Join-Path $Candidate $updater) -Destination (Join-Path $root 'At58.Update.ps1')
 Ops-WriteJson (Join-Path $root 'settings.json') @{Schema='AT58-HOST-1';HostProtocol=2;Enabled=$true;DataRoot=(Join-Path $base 'esbada_AT_direct');ManagementRoot=(Join-Path $base 'esbada_AT_manage');ChannelRoot=(Join-Path $root 'remote-channel');FeedUrl='https://github.com/crosnuu12/Avata-kor-releases/releases/latest/download/avata-update.json';ManualWhenRunning=$true;ResumeOnce=$false}
 Ops-WriteJson (Join-Path $root 'active.json') @{Version='58.17.8';Id='bundle-5d6e0eb02f86ac466df09cea';ManifestHash='062c855b611296d1a5d5998a836422c8bdf6f824ccf6cbfb3abc4c040693ca8e'}
 [IO.File]::WriteAllText((Join-Path $base 'esbada_AT_direct/synthetic-ledger.txt'),'synthetic fills remain unchanged')
 [IO.File]::WriteAllText((Join-Path $base 'esbada_AT_manage/synthetic-settings.txt'),'synthetic settings remain unchanged')
 return $base
}
try{
 $manifest=RK-Load $Recovery
 Check ($manifest.Updaters.Count -eq 2) 'both verified updater variants are allowlisted'
 $signed=Up-Envelope (Join-Path $Recovery 'avata-update.json')
 Check ($signed.Version -ceq '58.17.8') 'new public key verifies actual release signature'
 & {
  . (Join-Path $Candidate 'tests/original/At58.Ops.ps1')
  . (Join-Path $Candidate 'tests/original/At58.Update.ps1')
  Reject {Up-Envelope (Join-Path $Recovery 'avata-update.json')} 'UPDATE_SIGNATURE'
 }
 $badFeed=Join-Path $scratch 'tampered-feed.json';$envelope=Ops-ReadJson (Join-Path $Recovery 'avata-update.json')
 $bytes=[Convert]::FromBase64String($envelope.Signature);$bytes[0]=$bytes[0] -bxor 1;$envelope.Signature=[Convert]::ToBase64String($bytes);Ops-WriteJson $badFeed $envelope
 Reject {Up-Envelope $badFeed} 'UPDATE_SIGNATURE'
 foreach($variant in $manifest.Updaters){
  $base=Fixture $variant.Source;$root=Join-Path $base 'esbada_AT_host';$target=Join-Path $root 'At58.Update.ps1'
  $preserved=@{};foreach($p in Get-ChildItem -LiteralPath $base -Recurse -File){if($p.FullName -ine $target){$preserved[$p.FullName]=RK-Hash $p.FullName}}
  Check ((RK-Apply $base $Recovery) -ceq 'NEW_UPDATE_KEY_APPLIED') ($variant.Source+' rotates successfully')
  Check ((RK-Hash $target) -ceq $variant.After) 'only authorized key substitution is installed'
  $backups=@(Get-ChildItem -LiteralPath (Join-Path $root 'trust-key-backups') -Recurse -File)
  Check ($backups.Count -eq 1 -and (RK-Hash $backups[0].FullName) -ceq $variant.Before) 'atomic replacement preserves exact old updater backup'
  $unchanged=$true;foreach($p in $preserved.Keys){if((RK-Hash $p) -cne $preserved[$p]){$unchanged=$false}}
  Check $unchanged 'all bundle, account, settings and pointer fixture bytes remain unchanged'
  Check ((RK-Apply $base $Recovery) -ceq 'ALREADY_APPLIED') 'second run is idempotent'
  Check (@(Get-ChildItem -LiteralPath (Join-Path $root 'trust-key-backups') -Recurse -File).Count -eq 1) 'second run creates no extra backup'
  & {. $target;Check ((Up-Envelope (Join-Path $Recovery 'avata-update.json')).Version -ceq '58.17.8') 'installed patched updater accepts signed feed'}
 }
 $base=Fixture;$root=Join-Path $base 'esbada_AT_host';$target=Join-Path $root 'At58.Update.ps1';$before=RK-Hash $target
 $created=$false;$mutex=[Threading.Mutex]::new($true,('Local\esbada-AT-host-'+(Ops-Key $root.ToLowerInvariant()).Substring(0,24)),[ref]$created)
 try{Reject {RK-Apply $base $Recovery} 'CLOSE_AVATA_FIRST'}finally{$mutex.ReleaseMutex();$mutex.Dispose()}
 Check ((RK-Hash $target) -ceq $before) 'running app rejection leaves updater unchanged'
 foreach($stage in @('BEFORE_REPLACE','AFTER_REPLACE')){
  $script:faultStage=$stage
  function RK-Checkpoint([string]$stage){if($stage -ceq $script:faultStage){throw 'INJECTED_WRITE_FAILURE'}}
  Reject {RK-Apply $base $Recovery} 'INJECTED_WRITE_FAILURE'
  Check ((RK-Hash $target) -ceq $before) ($stage+' failure restores original updater')
  Check (@(Get-ChildItem -LiteralPath $root -Filter '*.tmp').Count -eq 0) 'failed apply removes temporary files'
 }
 function RK-Checkpoint([string]$stage){}
 $hold=[IO.File]::Open($target,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 $failed=$false;try{try{$null=RK-Apply $base $Recovery}catch{$failed=$true}}finally{$hold.Dispose()}
 Check ($failed -and (RK-Hash $target) -ceq $before) 'real Windows file lock preserves old updater'
 [IO.File]::AppendAllText($target,'# unauthorized modification')
 Reject {RK-Apply $base $Recovery} 'UNRECOGNIZED_UPDATER'
 $base=Fixture;$root=Join-Path $base 'esbada_AT_host'
 Ops-WriteJson (Join-Path $root 'trial.json') @{Phase='PENDING'}
 Reject {RK-Apply $base $Recovery} 'UPDATE_RECOVERY_PENDING'
 $base=Fixture;$root=Join-Path $base 'esbada_AT_host';$cfg=Ops-ReadJson (Join-Path $root 'settings.json');$cfg.DataRoot=Join-Path $scratch 'unrelated';Ops-WriteJson (Join-Path $root 'settings.json') $cfg
 Reject {RK-Apply $base $Recovery} 'STANDARD_INSTALLATION_REQUIRED'
 $base=Fixture;$root=Join-Path $base 'esbada_AT_host'
 [IO.File]::AppendAllText((Join-Path $root 'bundles/bundle-5d6e0eb02f86ac466df09cea/At58.Sheets.ps1'),'# modified')
 Reject {RK-Apply $base $Recovery} 'BUNDLE_FILE_HASH'
 $badPackage=Join-Path $scratch 'tampered-package';Copy-Item -LiteralPath $Recovery -Destination $badPackage -Recurse
 [IO.File]::AppendAllText((Join-Path $badPackage 'public-key.xml'),'x')
 Reject {RK-Apply (Fixture) $badPackage} 'RECOVERY_PACKAGE_CHANGED'
 $base=Fixture;$root=Join-Path $base 'esbada_AT_host';$active=Join-Path $root 'active.json';$activeHash=RK-Hash $active
 $null=RK-Apply $base $Recovery
 Check ((RK-Hash $active) -ceq $activeHash -and !(Test-Path (Join-Path $root 'session.json'))) 'recovery neither switches bundles nor starts app or trading'
 Write-Output ('TRUST RECOVERY TESTS COMPLETE: '+$script:passed+' passed; synthetic installation only.')
}finally{if([IO.Directory]::Exists($scratch)){Remove-Item -LiteralPath $scratch -Recurse -Force}}
