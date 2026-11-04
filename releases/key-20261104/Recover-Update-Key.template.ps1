#requires -Version 5.1
param([string]$LocalBase=([Environment]::GetFolderPath('LocalApplicationData')))
$ErrorActionPreference='Stop'
function RK-Hash([string]$p){return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
function RK-Load([string]$package){
 $manifest=Join-Path $package 'recovery.json'
 if((RK-Hash $manifest) -cne '__MANIFEST_HASH__'){throw 'RECOVERY_PACKAGE_CHANGED'}
 $m=[IO.File]::ReadAllText($manifest,[Text.Encoding]::UTF8)|ConvertFrom-Json
 foreach($f in $m.Files){
  if($f.Name -cnotin @('old-public-key.xml','public-key.xml','verifier/At58.Ops.ps1','verifier/At58.Update.ps1','avata-update.json','Avata_kor-58.17.8.zip')){throw 'RECOVERY_FILE_LIST'}
  $p=Join-Path $package $f.Name
  if((Get-Item -LiteralPath $p).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'RECOVERY_LINK'}
  if((RK-Hash $p) -cne $f.Sha256){throw 'RECOVERY_PACKAGE_CHANGED'}
 }
 return $m
}
function RK-Lock($paths){
 $locks=New-Object 'Collections.Generic.List[object]'
 try{
  foreach($pair in @(@('Local\esbada-AT-host-',$paths.Host),@('Local\esbada-AT-manager-',$paths.Manage),@('Local\esbada-AT-direct-',$paths.Data))){
   $created=$false;$mutex=[Threading.Mutex]::new($true,($pair[0]+(Ops-Key $pair[1].ToLowerInvariant()).Substring(0,24)),[ref]$created)
   if(!$created){$mutex.Dispose();throw 'CLOSE_AVATA_FIRST'}
   $locks.Add($mutex)
  }
  return ,$locks
 }catch{foreach($mutex in $locks){$mutex.ReleaseMutex();$mutex.Dispose()};throw}
}
function RK-Checkpoint([string]$stage){}
function RK-Apply([string]$base,[string]$package){
 $m=RK-Load $package
 . (Join-Path $package 'verifier/At58.Ops.ps1')
 . (Join-Path $package 'verifier/At58.Update.ps1')
 if(![IO.Path]::IsPathRooted($base)){throw 'STANDARD_INSTALLATION_REQUIRED'}
 $base=[IO.Path]::GetFullPath($base).TrimEnd('\')
 $paths=@{Host=(Join-Path $base 'esbada_AT_host');Manage=(Join-Path $base 'esbada_AT_manage');Data=(Join-Path $base 'esbada_AT_direct')}
 foreach($path in $paths.Values){$null=Ops-Inside $base $path}
 if(![IO.Directory]::Exists($paths.Host)){throw 'AVATA_NOT_INSTALLED'}
 $locks=RK-Lock $paths
 $scratch='';$temp='';$backup='';$changed=$false
 try{
  $cfg=Ops-ReadJson (Ops-Inside $paths.Host (Join-Path $paths.Host 'settings.json'))
  if(!$cfg -or $cfg.Schema -cne 'AT58-HOST-1' -or $cfg.HostProtocol -ne 2 -or !$cfg.Enabled){throw 'STANDARD_INSTALLATION_REQUIRED'}
  if([IO.Path]::GetFullPath($cfg.DataRoot) -ine $paths.Data -or [IO.Path]::GetFullPath($cfg.ManagementRoot) -ine $paths.Manage -or [IO.Path]::GetFullPath($cfg.ChannelRoot) -ine (Join-Path $paths.Host 'remote-channel') -or $cfg.FeedUrl -cne 'https://github.com/crosnuu12/Avata-kor-releases/releases/latest/download/avata-update.json'){throw 'STANDARD_INSTALLATION_REQUIRED'}
  $trial=Ops-ReadJson (Ops-Inside $paths.Host (Join-Path $paths.Host 'trial.json'))
  if($trial -and $trial.Phase -cin @('PENDING','ROLLING_BACK')){throw 'UPDATE_RECOVERY_PENDING'}
  $target=Ops-Inside $paths.Host (Join-Path $paths.Host 'At58.Update.ps1')
  $hash=RK-Hash $target
  $before=@($m.Updaters|Where-Object {$_.Before -ceq $hash})
  $after=@($m.Updaters|Where-Object {$_.After -ceq $hash})
  if($before.Count -ne 1 -and $after.Count -ne 1){throw 'UNRECOGNIZED_UPDATER'}
  $active=Ops-ReadJson (Ops-Inside $paths.Host (Join-Path $paths.Host 'active.json'))
  if(!$active -or $active.Id -cnotmatch '^bundle-[a-f0-9]{24}$'){throw 'INSTALLATION_IDENTITY'}
  $installed=Up-Validate (Ops-Inside $paths.Host (Join-Path $paths.Host ('bundles\'+$active.Id))) $active.ManifestHash
  if($installed.Id -cne $active.Id -or $installed.Version -cne $active.Version -or $installed.HostProtocol -ne 2){throw 'INSTALLATION_IDENTITY'}
  $signed=Up-Envelope (Join-Path $package 'avata-update.json')
  if($signed.Id -cne 'bundle-5d6e0eb02f86ac466df09cea' -or $signed.Version -cne '58.17.8' -or $signed.ManifestHash -cne '062c855b611296d1a5d5998a836422c8bdf6f824ccf6cbfb3abc4c040693ca8e'){throw 'RELEASE_IDENTITY'}
  $scratch=Join-Path ([IO.Path]::GetTempPath()) ('avata-trust-check-'+[guid]::NewGuid().ToString('N'))
  Up-Extract (Join-Path $package 'Avata_kor-58.17.8.zip') $scratch $signed
  if($after.Count -eq 1){return 'ALREADY_APPLIED'}
  $old=[IO.File]::ReadAllText((Join-Path $package 'old-public-key.xml'),[Text.Encoding]::ASCII)
  $new=[IO.File]::ReadAllText((Join-Path $package 'public-key.xml'),[Text.Encoding]::ASCII)
  $raw=[IO.File]::ReadAllBytes($target)
  # A one-to-one byte encoding preserves BOM, line endings and every other byte.
  $encoding=[Text.Encoding]::GetEncoding(28591);$text=$encoding.GetString($raw)
  if([regex]::Matches($text,[regex]::Escape($old)).Count -ne 1){throw 'TRUST_ANCHOR_COUNT'}
  $patched=$encoding.GetBytes($text.Replace($old,$new))
  $temp=Ops-Inside $paths.Host ($target+'.'+[guid]::NewGuid().ToString('N')+'.tmp')
  [IO.File]::WriteAllBytes($temp,$patched)
  if((RK-Hash $temp) -cne $before[0].After){throw 'PATCH_IDENTITY'}
  $backupDir=Ops-Inside $paths.Host (Join-Path $paths.Host ('trust-key-backups\20261104-'+[guid]::NewGuid().ToString('N')))
  [void][IO.Directory]::CreateDirectory($backupDir)
  $backup=Join-Path $backupDir 'At58.Update.ps1'
  RK-Checkpoint 'BEFORE_REPLACE'
  if((RK-Hash $target) -cne $hash){throw 'UPDATER_CHANGED_DURING_RECOVERY'}
  [IO.File]::Replace($temp,$target,$backup);$changed=$true
  RK-Checkpoint 'AFTER_REPLACE'
  if((RK-Hash $target) -cne $before[0].After -or (RK-Hash $backup) -cne $hash){throw 'RECOVERY_READBACK_FAILED'}
  return 'NEW_UPDATE_KEY_APPLIED'
 }catch{
  $failure=$_
  if($changed){
   try{
    if((RK-Hash $backup) -cne $hash -or (RK-Hash $target) -cne $before[0].After){throw 'CHANGED_DURING_ROLLBACK'}
    Ops-WriteBytes $target ([IO.File]::ReadAllBytes($backup))
    if((RK-Hash $target) -cne $hash){throw 'ROLLBACK_READBACK'}
   }catch{throw 'TRUST_RECOVERY_REVIEW_REQUIRED'}
  }
  throw $failure
 }finally{
  if($temp -and [IO.File]::Exists($temp)){[IO.File]::Delete($temp)}
  if($scratch -and [IO.Directory]::Exists($scratch)){Remove-Item -LiteralPath $scratch -Recurse -Force}
  foreach($mutex in $locks){$mutex.ReleaseMutex();$mutex.Dispose()}
 }
}
if($MyInvocation.InvocationName -eq '.'){return}
try{
 if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){throw 'WINDOWS_POWERSHELL_51_REQUIRED'}
 Write-Host 'Avata 업데이트 키 복구' -ForegroundColor Cyan
 Write-Host '아바타에서 실주문을 정지하고 프로그램을 완전히 종료한 상태에서 실행하세요.'
 $result=RK-Apply $LocalBase $PSScriptRoot
 Write-Host '새 업데이트 키 적용 완료. 기존 Avata_kor를 다시 실행하고 1.1.2 업데이트를 확인하세요.' -ForegroundColor Green
 Write-Host '계좌 설정과 매매 원장은 변경하지 않았습니다. 이 도구는 아바타나 실주문을 시작하지 않습니다.'
 exit 0
}catch{
 $code=[string]$_.Exception.Message;if($code -cnotmatch '^[A-Z][A-Z0-9_]{1,70}$'){$code='TRUST_RECOVERY_FAILED'}
 Write-Host ('적용하지 못했습니다. 진단 코드: '+$code) -ForegroundColor Red
 if($code -ceq 'CLOSE_AVATA_FIRST'){Write-Host '아바타를 완전히 종료한 뒤 다시 실행하세요.'}
 Write-Host '이 화면의 진단 코드를 알려주세요. 설치 파일을 재설치하거나 계좌 정보를 지울 필요는 없습니다.'
 exit 1
}
