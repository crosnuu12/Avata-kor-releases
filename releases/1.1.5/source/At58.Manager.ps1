param([string]$DataRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'esbada_AT_direct'),[string]$ManagementRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'esbada_AT_manage'),[switch]$AutoStart,[string]$HostSession='',[string]$BundleVersion='58.17.11',[int]$HostProtocol=1)

. (Join-Path $PSScriptRoot 'At58.Ops.ps1')

. (Join-Path $PSScriptRoot 'At58.Telegram.ps1')

. (Join-Path $PSScriptRoot 'At58.Sheets.ps1')

$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$DataRoot=[IO.Path]::GetFullPath($DataRoot);$ManagementRoot=[IO.Path]::GetFullPath($ManagementRoot)

$created=$false;$mutex=[Threading.Mutex]::new($true,('Local\esbada-AT-manager-'+(Ops-Key $ManagementRoot.ToLowerInvariant()).Substring(0,24)),[ref]$created)

if(!$created){$mutex.Dispose();exit}

$child=$null;$repairJob=$null;$transaction=$null;$rollback=$false;$started=Ops-Now;$runId='';$activeIncident=$null;$restartHeld=$false

$lastRuntime=$null;$lastStatus=$null;$receiptWatch=@{};$simulationWatch=@{}

$script:runDesired=$false

$state=Ops-ReadJson (Join-Path $ManagementRoot 'state.json');if(!$state){$state=[pscustomobject]@{Repairs=@();Restarts=@();Outbox=@();TelegramNext='2000-01-01T00:00:00Z';CircuitOpen=$false}}

function Save-Manager {Ops-WriteJson (Join-Path $ManagementRoot 'state.json') $state}

function Queue-Manager([string]$code,[string]$detail=''){

 Ops-Event $ManagementRoot $code $(if($activeIncident){$activeIncident.Id}else{''}) $detail

 $text=Tg-EventText $code $detail

 $state.Outbox=@($state.Outbox)+@([pscustomobject]@{Code=$code;Text=$text;Utc=(Ops-Now).ToString('o')})

 if($state.Outbox.Count -gt 200){$state.Outbox=@($state.Outbox|Select-Object -Last 200)};Save-Manager

}

function Flush-Manager($config){

 if(Ops-PruneMarketOutbox $state (Ops-Now)){Save-Manager}

 if(!$config -or !$config.Enabled -or !$state.Outbox.Count -or (Ops-Now) -lt (Ops-Utc $state.TelegramNext)){return}

 try{Tg-Notify $config $state.Outbox[0].Text;$state.Outbox=@($state.Outbox|Select-Object -Skip 1);$state.TelegramNext=(Ops-Now).AddSeconds(2).ToString('o')}catch{$state.TelegramNext=(Ops-Now).AddSeconds([math]::Max(60,[int]$_.Exception.Data['RetryAfter'])).ToString('o')};Save-Manager

}

function Start-Managed([string]$release,[bool]$auto){

 $script:runDesired=$auto

 $path=Ops-ReleasePath $ManagementRoot $release

 $args=@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',(Join-Path $path 'esbada_Merits_AT_v58.ps1'),'-DataRoot',$DataRoot,'-RunId',$script:runId,'-OperationsRoot',$PSScriptRoot,'-ManagementRoot',$ManagementRoot,'-HostProtocol',[string]$HostProtocol)

 if($auto){$args+='-AutoStart'}

 return (Ops-StartProcess $powershell $args $path)

}

try{

 [void][IO.Directory]::CreateDirectory($ManagementRoot)

 # Do not adopt or stop an unrelated AT process already using the account state.

 $appLock=$null

 try{$appLock=[Threading.Mutex]::OpenExisting('Local\esbada-AT-direct-'+(Ops-Key $DataRoot.ToLowerInvariant()).Substring(0,24))}catch{}

 if($appLock){$appLock.Dispose();Add-Type -AssemblyName System.Windows.Forms;[void][Windows.Forms.MessageBox]::Show('기존 AT58을 먼저 닫은 뒤 Start_AT58.cmd를 실행하세요. 기존 조회는 그대로 유지했습니다.','AT58 자동 관리');exit}

 $pointerPath=Join-Path $ManagementRoot 'active.json';$txPath=Join-Path $ManagementRoot 'transaction.json'

 $pointer=Ops-ReadJson $pointerPath;$savedTx=Ops-ReadJson $txPath

 if($savedTx -and $savedTx.Phase -ceq 'PENDING' -and $pointer){$pointer.Active=Ops-RecoveryRelease $pointer $savedTx;Ops-WriteJson $pointerPath $pointer;$savedTx.Phase='ROLLED_BACK';Ops-WriteJson $txPath $savedTx;Queue-Manager 'ROLLBACK'}

 $baseline=Ops-Key ((@('At58.Core.ps1','At58.Log.ps1','esbada_Merits_AT_v58.ps1')|ForEach-Object {Ops-Hash (Join-Path $PSScriptRoot ('payload\'+$_))}) -join '|')

 if(!$pointer -or $pointer.Baseline -cne $baseline){

  $id='base-'+$baseline.Substring(0,20);$destination=Ops-ReleasePath $ManagementRoot $id;[void][IO.Directory]::CreateDirectory($destination)

  foreach($name in @('At58.Core.ps1','At58.Log.ps1','esbada_Merits_AT_v58.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('payload\'+$name)) -Destination (Join-Path $destination $name) -Force}

  $pointer=[pscustomobject]@{Active=$id;Baseline=$baseline};Ops-WriteJson $pointerPath $pointer

 }

 $script:runId=[guid]::NewGuid().ToString();$child=Start-Managed $pointer.Active ([bool]$AutoStart);$started=Ops-Now

 Queue-Manager 'MANAGER_STARTED'

 while($true){

  $now=Ops-Now;$config=Tg-Load $ManagementRoot

  try{SheetDiag-Pump $PSScriptRoot $DataRoot $ManagementRoot}catch{}

  $runtime=Ops-ReadJson (Join-Path $ManagementRoot 'runtime.json');$status=Ops-ReadJson (Join-Path $DataRoot 'status.json')

  $exited=$child.Process.HasExited

  if($exited){$runtime=Ops-ReadJson (Join-Path $ManagementRoot 'runtime.json')}

  if($runtime -and (Ops-Get $runtime 'RunId') -ceq $script:runId){$lastRuntime=$runtime}elseif(!$runtime -and $lastRuntime -and (Ops-Get $lastRuntime 'RunId') -ceq $script:runId){$runtime=$lastRuntime}

  if($status -and (Ops-Get $status 'RunId') -ceq $script:runId){$lastStatus=$status}elseif(!$status -and $lastStatus -and (Ops-Get $lastStatus 'RunId') -ceq $script:runId){$status=$lastStatus}

  $desired=$script:runDesired

  if($runtime -and (Ops-Get $runtime 'RunId') -ceq $script:runId){

   $desired=[bool](Ops-Get $runtime 'DesiredRunning' $false)

   # Begin first-result grace at resume, before classification; paused time is not a timeout.

   if($desired -and !$script:runDesired){$started=$now}

   $script:runDesired=$desired

  }

  # A result left from before the pause is not the first result of the resumed query.

  if($status -and (Ops-Get $status 'RunId') -ceq $script:runId){try{if((Ops-Utc (Ops-Get $status 'Utc')) -lt $started){$status=$null}}catch{}}

  $receiptNotice=Ops-ReceiptAlert $receiptWatch (Ops-ReadJson (Join-Path $DataRoot 'execution-status.json')) $script:runId $desired $now

  if($receiptNotice){Queue-Manager $receiptNotice.Event $receiptNotice.Code}

  $simulationNotice=Ops-SimulationAlert $simulationWatch (Ops-ReadJson (Join-Path $DataRoot 'simulation-status.json')) $script:runId $desired $now $runtime

  if($simulationNotice){Queue-Manager $simulationNotice.Event $simulationNotice.Code}

  $maintenance=Ops-LiveMaintenance $runtime $status $script:runId $now

  $liveNotice=Ops-LiveAlert $state $status $script:runId $now
  if($liveNotice){Queue-Manager $liveNotice.Event $liveNotice.Code}

  if(!$exited -and $desired -and $config -and $config.Enabled){
   $marketNotice=Ops-MarketNotice $state $status $script:runId $now (Ops-ReadJson (Join-Path $ManagementRoot 'sheets-status.json')) (Ops-ReadJson (Join-Path $ManagementRoot 'assets-status.json'))
   if($marketNotice -and (Ops-QueueMarketNotice $state $marketNotice (Tg-EventText $marketNotice.Event) $now)){Save-Manager;Ops-Event $ManagementRoot $marketNotice.Event '' ''}
  }

  $kind=Ops-Classify $runtime $status $script:runId $started $exited $now

  Ops-WriteJson (Join-Path $ManagementRoot 'manager-status.json') @{Utc=$now.ToString('o');State=$kind;RunId=$script:runId;Release=$pointer.Active;HostSession=$HostSession;BundleVersion=$BundleVersion;RepairTransaction=($null -ne $transaction);RepairRunning=($null -ne $repairJob);HostProtocol=$HostProtocol;LiveMaintenance=$maintenance;TelegramReady=($config -and $config.Enabled);AutoRepair=($config -and $config.Enabled -and $config.AutoRepair);CircuitOpen=$state.CircuitOpen}

  if($HostSession){

   $bundleControl=Ops-ReadJson (Join-Path $ManagementRoot 'bundle-control.json')

   if($bundleControl -and $bundleControl.Session -ceq $HostSession -and $bundleControl.Action -ceq 'STOP' -and ($maintenance -cin @('LEGACY','QUIESCENT') -or $exited)){

    Ops-StopOwned $child $ManagementRoot $script:runId

    Ops-WriteJson (Join-Path $ManagementRoot 'bundle-exit.json') @{Session=$HostSession;Reason='UPDATE';RunId=$script:runId}

    break

   }

   $bundleEvent=Ops-ReadJson (Join-Path $ManagementRoot 'bundle-event.json')

   if($bundleEvent -and $bundleEvent.Id -cne (Ops-Get $state 'BundleEventId' '') -and $bundleEvent.Code -cin @('BUNDLE_UPDATING','BUNDLE_UPDATED','BUNDLE_ROLLBACK','BUNDLE_RECOVERED','BUNDLE_FAILED') -and $bundleEvent.Version -cmatch '^58\.[0-9]{1,4}\.[0-9]{1,4}$'){

    $state|Add-Member NoteProperty BundleEventId $bundleEvent.Id -Force

    Queue-Manager $bundleEvent.Code $bundleEvent.Version

   }

  }

  if($kind -ceq 'USER_CLOSE'){if($HostSession){Ops-WriteJson (Join-Path $ManagementRoot 'bundle-exit.json') @{Session=$HostSession;Reason='USER_CLOSE';RunId=$script:runId}};Queue-Manager 'MANAGER_STOPPED';Flush-Manager $config;break}

  if($kind -ceq 'READONLY_GUARD' -and $maintenance -ceq 'LEGACY'){Queue-Manager 'READONLY_GUARD';Ops-StopOwned $child $ManagementRoot $script:runId;Flush-Manager $config;break}

  if($transaction -and $maintenance -cnotin @('LEGACY','QUIESCENT') -and !$exited){$started=$now}

  elseif($transaction -and $kind -ceq 'PAUSED'){$started=$now}

  elseif($transaction){

   if($kind -ceq 'HEALTHY' -and !$exited -and (Ops-Ready $status $script:runId $started)){

    $transaction.Phase=if($rollback){'ROLLED_BACK'}else{'COMMITTED'};Ops-WriteJson $txPath $transaction

    Queue-Manager $(if($rollback){'ROLLBACK_RECOVERED'}else{'UPDATED'});$transaction=$null;$activeIncident=$null

   }elseif(($now-$started).TotalSeconds -gt 180 -or $child.Process.HasExited){

    if(!$rollback){Ops-StopOwned $child $ManagementRoot $script:runId;$pointer.Active=$transaction.Previous;Ops-WriteJson $pointerPath $pointer;$script:runId=[guid]::NewGuid().ToString();$child=Start-Managed $pointer.Active $desired;$started=Ops-Now;$rollback=$true;Queue-Manager 'ROLLBACK'}

    else{$transaction.Phase='ROLLBACK_UNCONFIRMED';Ops-WriteJson $txPath $transaction;$transaction=$null;$state.CircuitOpen=$true;Queue-Manager 'ROLLBACK_FAILED'}

   }

  }else{

   if($kind -ceq 'HEALTHY' -and $activeIncident){Queue-Manager 'RECOVERED';$activeIncident=$null;$restartHeld=$false}

   if($kind -cin @('PROCESS_EXIT','NO_HEARTBEAT','NO_RESULT','APP_FAULT','PERSISTENT_ERROR','RESULT_STALE','STATUS_INVALID')){

    if(!$activeIncident){$activeIncident=Ops-SafeIncident $runtime $status $kind;Queue-Manager 'FAULT' ($kind+' '+$activeIncident.Code)}

    if($kind -cin @('PROCESS_EXIT','NO_HEARTBEAT','NO_RESULT','APP_FAULT','RESULT_STALE','STATUS_INVALID') -and !$state.CircuitOpen -and ($maintenance -cin @('LEGACY','QUIESCENT') -or $exited)){

     if(Ops-CanRestart $state.Restarts $now){

      $state.Restarts=@($state.Restarts|Where-Object {($now-(Ops-Utc $_)).TotalHours -lt 24})+@($now.ToString('o'));Save-Manager

      Ops-StopOwned $child $ManagementRoot $script:runId;$script:runId=[guid]::NewGuid().ToString();$child=Start-Managed $pointer.Active $desired;$started=Ops-Now;Queue-Manager 'RESTART'

     }elseif(!$restartHeld){$restartHeld=$true;Queue-Manager 'RESTART_LIMIT'}

    }

    $repairable=$activeIncident.Code -match '^(DATA_INVALID|OBJECT_SCHEMA|SESSION_INVALID|SESSION_STALE|HOLDING_IDENTITY|HOLDING_DUPLICATE|ORDER_IDENTITY|ORDER_DATE|ORDER_QUANTITY|ORDER_CHANGED_DURING_READ|DATE_INVALID)$'

    if($maintenance -cin @('LEGACY','QUIESCENT') -and (!$HostSession -or ((Ops-ReadJson (Join-Path $ManagementRoot 'bundle-status.json')).State -cin @('CURRENT','DISABLED','REJECTED'))) -and $desired -and $repairable -and $config -and $config.Enabled -and $config.AutoRepair -and !$state.CircuitOpen -and !$repairJob -and (Ops-CanRepair $state.Repairs $now)){

     $exe=[string]$config.CodexPath

     if(![IO.File]::Exists($exe)){Queue-Manager 'CODEX_UNAVAILABLE';$state.CircuitOpen=$true;Save-Manager}

     else{

      $state.Repairs=@($state.Repairs|Where-Object {($now-(Ops-Utc $_)).TotalHours -lt 24})+@($now.ToString('o'));Save-Manager

      $jobRoot=Ops-Inside $ManagementRoot (Join-Path $ManagementRoot ('jobs\'+[guid]::NewGuid().ToString()));[void][IO.Directory]::CreateDirectory($jobRoot);Ops-WriteJson (Join-Path $jobRoot 'incident.json') $activeIncident

      $repairJob=Ops-StartProcess $powershell @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'At58.Repair.ps1'),'-BundleRoot',$PSScriptRoot,'-ActivePath',(Ops-ReleasePath $ManagementRoot $pointer.Active),'-JobRoot',$jobRoot,'-CodexPath',$exe) $PSScriptRoot

      $repairJob|Add-Member NoteProperty JobRoot $jobRoot;$repairJob|Add-Member NoteProperty BaseRelease $pointer.Active

      Queue-Manager 'REPAIR_STARTED'

     }

    }

   }

   if($repairJob -and $repairJob.Process.HasExited){

    $result=Ops-ReadJson (Join-Path $repairJob.JobRoot 'result.json')

    if($result -and $result.State -ceq 'READY' -and $maintenance -cin @('LEGACY','QUIESCENT') -and $desired -and $activeIncident -and $pointer.Active -ceq $repairJob.BaseRelease){

     try{

      $core=Join-Path $repairJob.JobRoot 'verification\At58.Core.ps1';if((Ops-Hash $core) -cne $result.CoreHash){throw 'PATCH_HASH'}

      $null=Ops-ValidateCore (Join-Path (Ops-ReleasePath $ManagementRoot $pointer.Active) 'At58.Core.ps1') $core

      $id='fix-'+[guid]::NewGuid().ToString('N');$dest=Ops-ReleasePath $ManagementRoot $id;[void][IO.Directory]::CreateDirectory($dest)

      foreach($name in @('At58.Log.ps1','esbada_Merits_AT_v58.ps1')){Copy-Item -LiteralPath (Join-Path (Ops-ReleasePath $ManagementRoot $pointer.Active) $name) -Destination (Join-Path $dest $name)}

      Copy-Item -LiteralPath $core -Destination (Join-Path $dest 'At58.Core.ps1')

      $transaction=Ops-NewTransaction $pointer.Active $id $activeIncident.Id;Ops-WriteJson $txPath $transaction

      Ops-StopOwned $child $ManagementRoot $script:runId;$pointer.Active=$id;Ops-WriteJson $pointerPath $pointer;$script:runId=[guid]::NewGuid().ToString();$child=Start-Managed $id $true;$started=Ops-Now;$rollback=$false;Queue-Manager 'UPDATE'

     }catch{

      Queue-Manager 'REPAIR_FAILED'

      if($transaction){

       try{Ops-StopOwned $child $ManagementRoot $script:runId;$pointer.Active=$transaction.Previous;Ops-WriteJson $pointerPath $pointer;$script:runId=[guid]::NewGuid().ToString();$child=Start-Managed $pointer.Active $desired;$started=Ops-Now;$rollback=$true;Queue-Manager 'ROLLBACK'}

       catch{$state.CircuitOpen=$true;Save-Manager;throw 'ROLLBACK_START_FAILED'}

      }

     }

    }elseif($result -and $result.State -ceq 'NO_CHANGE'){Queue-Manager 'NO_CHANGE'}else{Queue-Manager 'REPAIR_FAILED'}

    $repairJob.Process.Dispose();$repairJob=$null

   }

  }

  Flush-Manager $config

  try{Sheet-Pump $PSScriptRoot $DataRoot $ManagementRoot $status $script:runId}catch{try{Ops-WriteJson (Join-Path $ManagementRoot 'sheets-status.json') @{Code='SHEET_PUMP';At=(Ops-Now).ToString('o')}}catch{}}

  Start-Sleep -Seconds 5

 }

}catch{

 $failure=$_

 try{Ops-Event $ManagementRoot 'MANAGER_EXCEPTION';Ops-WriteJson (Join-Path $ManagementRoot 'manager-error.json') @{Utc=(Ops-Now).ToString('o');Type=$failure.Exception.GetType().Name;Line=$failure.InvocationInfo.ScriptLineNumber;File=[IO.Path]::GetFileName($failure.InvocationInfo.ScriptName);Code=$(if($failure.Exception.Message -cmatch '^[A-Z0-9_]{1,60}$'){$failure.Exception.Message}else{'MANAGER_EXCEPTION'})}}catch{}

 Add-Type -AssemblyName System.Windows.Forms

 [void][Windows.Forms.MessageBox]::Show('자동 관리 기능을 계속 실행하지 못했습니다. 관리 로그를 확인해야 합니다. 실행 중인 AT 조회 창은 강제로 종료하지 않았습니다.','AT58 관리 오류')

}finally{

 if($HostSession -and $child){try{$safe=Ops-LiveMaintenance (Ops-ReadJson (Join-Path $ManagementRoot 'runtime.json')) (Ops-ReadJson (Join-Path $DataRoot 'status.json')) $script:runId (Ops-Now);if($safe -cin @('LEGACY','QUIESCENT') -or $child.Process.HasExited){Ops-StopOwned $child $ManagementRoot $script:runId}}catch{}}

 SheetDiag-StopPump

 Sheet-StopPump

 if($repairJob -and !$repairJob.Process.HasExited){try{Ops-WriteJson (Join-Path $repairJob.JobRoot 'cancel.json') @{Cancel=$true};if(!$repairJob.Process.WaitForExit(15000)){$repairJob.Process.Kill()}}catch{}}

 if($child){$child.Process.Dispose()};$mutex.ReleaseMutex();$mutex.Dispose()

}

