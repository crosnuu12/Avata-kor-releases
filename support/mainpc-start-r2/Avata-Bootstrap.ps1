param([string]$HostRoot='',[switch]$Inspect)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$startup=$null;$held=$false
function Avata-MutexExists([string]$name){
 $m=$null;try{$m=[Threading.Mutex]::OpenExisting($name);return $true}catch [Threading.WaitHandleCannotBeOpenedException]{return $false}catch [UnauthorizedAccessException]{return $true}finally{if($m){$m.Dispose()}}
}
function Avata-Result([string]$code){
 [ordered]@{Schema='AVATA-LAUNCH-1';Code=$code;HostRoot=$HostRoot;ManagementRoot=$config.ManagementRoot;InstalledVersion=$active.Version;OfferedVersion=$(if($offer){$offer.Version}else{''});TargetVersion=$target.Version;TargetId=$target.Id;HostRunning=$running;OnlineUpdates=[bool](Ops-Get $config 'FeedUrl' '');WarningCode=$warning;Utc=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json -Compress
}
try{
 if([string]::IsNullOrWhiteSpace($HostRoot)){
  $normalHost=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'esbada_AT_host'
  $profileHost=Join-Path ([Environment]::GetFolderPath('UserProfile')) 'AppData\Local\esbada_AT_host'
  # Packaged Windows apps can redirect LocalApplicationData; the existing desktop
  # installation still belongs to this same user profile. Never search other users.
  $HostRoot=if([IO.File]::Exists((Join-Path $normalHost 'settings.json'))){$normalHost}elseif([IO.File]::Exists((Join-Path $profileHost 'settings.json'))){$profileHost}else{$normalHost}
 }
 $HostRoot=[IO.Path]::GetFullPath($HostRoot).TrimEnd('\')
 foreach($name in @('At58.Host.ps1','At58.Ops.ps1','At58.Update.ps1','settings.json','active.json')){
  if(![IO.File]::Exists((Join-Path $HostRoot $name))){throw 'AVATA_INSTALLATION_MISSING'}
 }
 . (Join-Path $HostRoot 'At58.Ops.ps1')
 . (Join-Path $HostRoot 'At58.Update.ps1')
 $config=Ops-ReadJson (Join-Path $HostRoot 'settings.json')
 if(!$config -or $config.Schema -cne 'AT58-HOST-1' -or (Ops-Get $config 'HostProtocol' 1) -ne 2){throw 'AVATA_SETTINGS_INVALID'}
 foreach($key in @('DataRoot','ManagementRoot','ChannelRoot')){
  $p=[string](Ops-Get $config $key '')
  if([string]::IsNullOrWhiteSpace($p) -or ![IO.Path]::IsPathRooted($p)){throw 'AVATA_SETTINGS_PATH'}
  $config.$key=[IO.Path]::GetFullPath($p)
 }
 $active=Ops-ReadJson (Join-Path $HostRoot 'active.json')
 if(!$active -or $active.Id -cnotmatch '^bundle-[a-f0-9]{24}$'){throw 'AVATA_ACTIVE_INVALID'}
 $manifest=Up-Validate (Ops-Inside $HostRoot (Join-Path $HostRoot ('bundles\'+$active.Id))) $active.ManifestHash
 if($manifest.Id -cne $active.Id -or $manifest.Version -cne $active.Version -or $manifest.HostProtocol -ne 2){throw 'AVATA_ACTIVE_MISMATCH'}
 $offer=$null;$warning='';$target=$active
 if($config.Enabled){
  try{$offer=Up-Offer $config.ChannelRoot;if(!$offer){$warning='CHANNEL_UNAVAILABLE'}}catch{$warning='CHANNEL_UNAVAILABLE'}
 }else{$warning='AUTO_UPDATE_DISABLED'}
 $state=Ops-ReadJson (Join-Path $HostRoot 'state.json')
 if($offer -and (Up-Version $offer.Version) -gt (Up-Version $active.Version)){
  if($state -and $offer.Id -cin @($state.Rejected)){$warning='UPDATE_REJECTED'}else{$target=$offer}
 }
 $hostMutex='Local\esbada-AT-host-'+(Ops-Key $HostRoot.ToLowerInvariant()).Substring(0,24)
 $running=Avata-MutexExists $hostMutex
 if($Inspect){Avata-Result 'INSPECTED';exit 0}
 if($running){Avata-Result 'ALREADY_RUNNING';exit 0}
 $startup=[Threading.Mutex]::new($false,('Local\Avata-kor-start-'+(Ops-Key $HostRoot.ToLowerInvariant()).Substring(0,24)))
 try{$held=$startup.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
 if(!$held){Avata-Result 'START_IN_PROGRESS';exit 0}
 $running=Avata-MutexExists $hostMutex
 if($running){Avata-Result 'ALREADY_RUNNING';exit 0}
 # An orphaned manager must not be replaced or stopped by the launcher.
 $managerMutex='Local\esbada-AT-manager-'+(Ops-Key $config.ManagementRoot.ToLowerInvariant()).Substring(0,24)
 if(Avata-MutexExists $managerMutex){throw 'AVATA_EXISTING_MANAGER'}
 $appMutex='Local\esbada-AT-direct-'+(Ops-Key $config.DataRoot.ToLowerInvariant()).Substring(0,24)
 if(Avata-MutexExists $appMutex){throw 'AVATA_EXISTING_READER'}
 # AutoStart in this program starts account queries only. A fresh live session is DISARMED.
 # Query startup lets the existing updater perform reconciliation before switching versions.
 $settingsPath=Join-Path $HostRoot 'settings.json';$sessionPath=Join-Path $HostRoot 'session.json'
 $settingsBefore=[IO.File]::ReadAllText($settingsPath)
 $sessionBefore=if([IO.File]::Exists($sessionPath)){[IO.File]::ReadAllText($sessionPath)}else{$null}
 $old=if($sessionBefore){$sessionBefore|ConvertFrom-Json}else{$null}
 if($sessionBefore -and (!$old -or !$old.Session)){throw 'AVATA_SESSION_INVALID'}
 $startedProcess=$null
 try{
  $config.ResumeOnce=$true;Ops-WriteJson $settingsPath $config
  if($old){$old|Add-Member NoteProperty DesiredRunning $true -Force;Ops-WriteJson $sessionPath $old}
  $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $arguments=@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',(Join-Path $HostRoot 'At58.Host.ps1'),'-HostRoot',$HostRoot)
  $quoted=@(foreach($a in $arguments){'"'+[regex]::Replace([regex]::Replace($a,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'})
  $startedProcess=Start-Process -FilePath $ps -ArgumentList ($quoted -join ' ') -WorkingDirectory $HostRoot -WindowStyle Hidden -PassThru
 }catch{
  if(!$startedProcess){Ops-WriteJson $settingsPath ($settingsBefore|ConvertFrom-Json);if($sessionBefore){Ops-WriteJson $sessionPath ($sessionBefore|ConvertFrom-Json)}}
  throw
 }
 $until=[datetime]::UtcNow.AddSeconds(15)
 do{
  $running=Avata-MutexExists $hostMutex
  if($running){Avata-Result 'STARTED';exit 0}
  if($startedProcess.HasExited){throw 'AVATA_HOST_EXITED'}
  Start-Sleep -Milliseconds 200
 }while([datetime]::UtcNow -lt $until)
 throw 'AVATA_HOST_START_TIMEOUT'
}catch{
 $code=$_.Exception.Message;if($code -cnotmatch '^[A-Z][A-Z0-9_]{1,70}$'){$code='AVATA_START_FAILED'}
 [ordered]@{Schema='AVATA-LAUNCH-1';Code=$code;Utc=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json -Compress
 exit 1
}finally{
 if($startup){if($held){$startup.ReleaseMutex()};$startup.Dispose()}
}
