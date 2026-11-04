param([string]$Root=$PSScriptRoot)
$ErrorActionPreference='Stop'
. (Join-Path $Root 'bundle/At58.Ops.ps1')
$work=Join-Path ([IO.Path]::GetTempPath()) ('AvataTGWorker-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
[IO.File]::WriteAllText((Join-Path $work 'telegram.dpapi'),'synthetic-config-only')
$pipe=[hashtable]::Synchronized(@{Stop=$false;Paused=$false;Decision=$null;NetworkWait=$false;View=[pscustomobject]@{Utc=[datetime]::UtcNow.ToString('o');RunId=[guid]::NewGuid().ToString();Scope=('a'*64);SourceHash=('b'*64);Ready=$true;Active=$false;AutoEnabled=$false;Blocked=$false;ArmState='DISARMED';Symbol='0210A0';Device='MAIN'}})
$worker=[PowerShell]::Create()
try{
 $code={param($ops,$telegram,$pipe,$root)
  . $ops;. $telegram
  function Tg-Load($path){return [pscustomobject]@{Enabled=$true;Token='synthetic';ChatId='-12345';OwnerUserId='12345';MessageThreadId=9}}
  function Invoke-RestMethod {throw 'TEST_REAL_NETWORK_FORBIDDEN'}
  function Tg-Call($token,$method,$body){
   switch($method){
    'getWebhookInfo' {return [pscustomobject]@{url=''}}
    'sendMessage' {$script:callbackData=$body.reply_markup.inline_keyboard[0][0].callback_data;return [pscustomobject]@{message_id=501;chat=[pscustomobject]@{id='-12345'}}}
    'getUpdates' {$pipe.NetworkWait=$true;Start-Sleep -Seconds 2;return [pscustomobject]@{update_id=1;callback_query=[pscustomobject]@{id='synthetic';from=[pscustomobject]@{id='12345';is_bot=$false};message=[pscustomobject]@{message_id=501;chat=[pscustomobject]@{id='-12345'};message_thread_id=9};data=$script:callbackData}}}
    'editMessageText' {return $true}
    'answerCallbackQuery' {return $true}
    default {throw 'TEST_UNEXPECTED_METHOD'}
   }
  }
  TgC-Run $pipe $root
 }
 [void]$worker.AddScript($code.ToString()).AddArgument((Join-Path $Root 'bundle/At58.Ops.ps1')).AddArgument((Join-Path $Root 'bundle/At58.Telegram.ps1')).AddArgument($pipe).AddArgument($work)
 $handle=$worker.BeginInvoke();$deadline=[datetime]::UtcNow.AddSeconds(10)
 while(!$pipe.NetworkWait -and !$handle.IsCompleted -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
 if(!$pipe.NetworkWait){throw 'WORKER_DID_NOT_POLL'}
 Write-Output 'PASS actual background worker loads helpers and reaches synthetic callback polling'
 $watch=[Diagnostics.Stopwatch]::StartNew();$view=$pipe.View.PSObject.Copy();$view.Ready=$false;$view.Utc=[datetime]::UtcNow.ToString('o');$pipe.View=$view;$watch.Stop()
 if($watch.ElapsedMilliseconds -gt 100){throw 'UI_BLOCKED_BY_TELEGRAM'}
 Write-Output 'PASS UI state remains writable while Telegram request is waiting'
 $deadline=[datetime]::UtcNow.AddSeconds(6)
 do{Start-Sleep -Milliseconds 100;$record=Ops-ReadJson (Join-Path $work 'telegram-control-status.json')}while(!$record -and !$handle.IsCompleted -and [datetime]::UtcNow -lt $deadline)
 if(!$record -or $pipe.Decision){throw 'STALE_CALLBACK_ACCEPTED_OR_WORKER_FAILED'}
 Write-Output 'PASS real worker rejects approval when readiness changes during network wait'
 $pipe.Stop=$true;$stop=$worker.BeginStop($null,$null)
 if(!$stop.AsyncWaitHandle.WaitOne(5000)){throw 'TELEGRAM_WORKER_CLOSE_TIMEOUT'}
 try{$worker.EndInvoke($handle)}catch [Management.Automation.PipelineStoppedException]{}
 Write-Output 'PASS background worker stops without delaying application shutdown'
 Write-Output 'TELEGRAM WORKER TESTS COMPLETE: 4 passed; synthetic transport only.'
}finally{
 $pipe.Stop=$true;try{$worker.Dispose()}catch{}
 $resolved=[IO.Path]::GetFullPath($work);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf).StartsWith('AvataTGWorker-')){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
