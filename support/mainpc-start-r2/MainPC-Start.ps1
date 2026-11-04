#requires -Version 5.1
param([switch]$Inspect)
$ErrorActionPreference='Stop'

function MP-Hash([string]$text){$h=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}}
function MP-Resolve([string]$profileRoot,[string]$knownLocal){
 $profileRoot=[IO.Path]::GetFullPath($profileRoot).TrimEnd('\')
 $roots=@((Join-Path $profileRoot 'AppData\Local'),$knownLocal)|Where-Object {$_}|Select-Object -Unique
 $found=@();$observed=@()
 foreach($root in $roots){
  $root=[IO.Path]::GetFullPath($root).TrimEnd('\');$hostRoot=Join-Path $root 'esbada_AT_host'
  $missing=@(@('At58.Host.ps1','At58.Ops.ps1','At58.Update.ps1','settings.json','active.json')|Where-Object {![IO.File]::Exists((Join-Path $hostRoot $_))})
  $observed+=,[pscustomobject]@{Root=$root;Missing=$missing;LauncherExists=[IO.File]::Exists((Join-Path $root 'Avata_kor\Avata_kor.exe'))}
  if(!$missing.Count){$found+=,[pscustomobject]@{HostRoot=$hostRoot;LocalRoot=$root;ProfileRoot=$profileRoot}}
 }
 if(!$found.Count){return [pscustomobject]@{Code='AVATA_HOST_INSTALLATION_MISSING';Candidates=$observed;Installation=$null}}
 $found=@($found|Sort-Object HostRoot -Unique)
 if($found.Count -ne 1){return [pscustomobject]@{Code='AVATA_MULTIPLE_INSTALLATIONS';Candidates=$observed;Installation=$null}}
 return [pscustomobject]@{Code='OK';Candidates=$observed;Installation=$found[0]}
}
function MP-Validate($installation){
 $cfg=Get-Content -LiteralPath (Join-Path $installation.HostRoot 'settings.json') -Raw | ConvertFrom-Json
 $active=Get-Content -LiteralPath (Join-Path $installation.HostRoot 'active.json') -Raw | ConvertFrom-Json
 if($cfg.Schema -cne 'AT58-HOST-1' -or $cfg.HostProtocol -ne 2 -or !$cfg.Enabled -or $cfg.FeedUrl -cne 'https://github.com/crosnuu12/Avata-kor-releases/releases/latest/download/avata-update.json'){throw 'AVATA_UPDATE_SETTINGS_CHECK'}
 $data=[IO.Path]::GetFullPath([string]$cfg.DataRoot);$manage=[IO.Path]::GetFullPath([string]$cfg.ManagementRoot)
 foreach($path in @($installation.HostRoot,$data,$manage)){
  if(!$path.StartsWith(($installation.ProfileRoot.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -or ![IO.Directory]::Exists($path)){throw 'AVATA_INSTALLATION_PATH'}
 }
 return [pscustomobject]@{DataRoot=$data;ManagementRoot=$manage;Version=$active.Version}
}
function MP-Running([string]$name){$m=$null;try{$m=[Threading.Mutex]::OpenExisting($name);return $true}catch [Threading.WaitHandleCannotBeOpenedException]{return $false}catch [UnauthorizedAccessException]{return $true}finally{if($m){$m.Dispose()}}}
function MP-Bootstrap([string]$hostRoot,[bool]$inspectOnly){
 $bootstrap=Join-Path $PSScriptRoot 'Avata-Bootstrap.ps1'
 if(![IO.File]::Exists($bootstrap)){throw 'MAIN_PC_PACKAGE_INCOMPLETE'}
 $expected='e4d90f1d78684ac5fdfb39d582091bed39501cc5a19df0d66357649d43607a49'
 if((Get-FileHash -LiteralPath $bootstrap -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected){throw 'MAIN_PC_BOOTSTRAP_CHANGED'}
 $args=@('-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',$bootstrap,'-HostRoot',$hostRoot)
 if($inspectOnly){$args+='-Inspect'}
 $lines=& (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @args
 $exitCode=$LASTEXITCODE
 try{$result=($lines -join [Environment]::NewLine)|ConvertFrom-Json}catch{throw 'MAIN_PC_BOOTSTRAP_RESPONSE'}
 if($result.Schema -cne 'AVATA-LAUNCH-1'){throw 'MAIN_PC_BOOTSTRAP_RESPONSE'}
 if($exitCode -ne 0){$code=[string]$result.Code;if($code -cnotmatch '^[A-Z0-9_]{1,80}$'){$code='MAIN_PC_BOOTSTRAP_FAILED'};throw $code}
 return $result
}
function MP-WriteBytes([string]$path,[byte[]]$bytes){
 $tmp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 try{[IO.File]::WriteAllBytes($tmp,$bytes);if([IO.File]::Exists($path)){[IO.File]::Replace($tmp,$path,[Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($tmp,$path)}}finally{if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}}
}
function MP-Start($installation,[bool]$inspectOnly){
 $config=MP-Validate $installation
 $checks=@(@('host',$installation.HostRoot),@('manager',$config.ManagementRoot),@('direct',$config.DataRoot))
 $running=$false;foreach($entry in $checks){if(MP-Running ('Local\esbada-AT-'+$entry[0]+'-'+(MP-Hash $entry[1].ToLowerInvariant()).Substring(0,24))){$running=$true}}
 $proof=MP-Bootstrap $installation.HostRoot $true
 if($proof.Code -cne 'INSPECTED'){throw 'MAIN_PC_INSPECTION_FAILED'}
 if($inspectOnly){return [pscustomobject]@{Code='INSPECTED';InstalledVersion=$config.Version;Running=$running;HostRoot=$installation.HostRoot;WindowMode='DESKTOP'}}
 if($running){throw 'AVATA_CLOSE_FIRST'}
 $pref=Join-Path $config.DataRoot 'window-preferences.json';$before=if([IO.File]::Exists($pref)){[IO.File]::ReadAllBytes($pref)}else{$null}
 MP-WriteBytes $pref ([Text.Encoding]::UTF8.GetBytes('{"Schema":"AT-WINDOW-2","UseTray":false,"StartInTray":false}'))
 try{
  # The existing bootstrap requests account queries and starts the signed-update host.
  # It never creates live-order consent or sends an ARM/STOP/order command.
  $result=MP-Bootstrap $installation.HostRoot $false
  if($result.Code -cnotin @('STARTED','ALREADY_RUNNING','START_IN_PROGRESS')){throw 'MAIN_PC_START_UNCONFIRMED'}
 }catch{
  if($null -ne $before){MP-WriteBytes $pref $before}else{[IO.File]::Delete($pref)}
  throw
 }
 return $result
}
if($MyInvocation.InvocationName -eq '.'){return}
if(!$Inspect){Write-Output 'Avata MainPC 1.1.1 - START HELPER R2'}
$diagnostic=[ordered]@{Schema='AVATA-MAIN-START-2';Utc=[datetime]::UtcNow.ToString('o');Device=(MP-Hash ([Environment]::MachineName+'|'+[Environment]::UserName)).Substring(0,16);Code='STARTING'}
try{
 $resolved=MP-Resolve ([Environment]::GetFolderPath('UserProfile')) ([Environment]::GetFolderPath('LocalApplicationData'))
 $diagnostic.Candidates=$resolved.Candidates
 if($resolved.Code -cne 'OK'){throw $resolved.Code}
 $result=MP-Start $resolved.Installation ([bool]$Inspect)
 $diagnostic.Code=$result.Code;$diagnostic.InstalledVersion=$result.InstalledVersion
 if($Inspect){$result|ConvertTo-Json -Compress;exit 0}
 $diagnostic|ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'MainPC-start-result.json') -Encoding UTF8
 Write-Output 'Avata host started. Wait for the account window and the signed update check.'
 Write-Output 'STARTED means startup was requested; confirm 1.1.1 and READ_OK in Avata.'
}catch{
 $code=[string]$_.Exception.Message;if($code -cnotmatch '^[A-Z0-9_]{1,80}$'){$code='MAIN_PC_START_FAILED'}
 $diagnostic.Code=$code
 try{$diagnostic|ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'MainPC-start-result.json') -Encoding UTF8}catch{}
 Write-Output ('Could not complete: '+$code)
 Write-Output 'Diagnostic details: MainPC-start-result.json (no keys or account data).'
 exit 1
}
