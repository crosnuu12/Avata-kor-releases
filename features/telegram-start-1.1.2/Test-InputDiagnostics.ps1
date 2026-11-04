#requires -Version 5.1
param([string]$Root=$PSScriptRoot)
$ErrorActionPreference='Stop'
. (Join-Path $Root 'bundle/At58.Ops.ps1')
. (Join-Path $Root 'bundle/At58.Sheets.ps1')
. (Join-Path $Root 'bundle/payload/At58.Core.ps1')
. (Join-Path $Root 'tests/CashFixture.ps1')
$script:passed=0
function Check($ok,[string]$name){if(!$ok){throw ('FAILED: '+$name)};$script:passed++;'PASS '+$name}
$dir=Join-Path ([IO.Path]::GetTempPath()) ('AvataInputDiagnosticTest-'+[guid]::NewGuid().ToString('N'))
$f=Cash-Fixture $dir;$o=$f.Owner;$path=Join-Path $dir 'strategy-input.dpapi';$raw=$f.Raw
function Save-Input {At58-Atomic $path (At58-Protect ($raw|ConvertTo-Json -Depth 30 -Compress) 'AT58-STRATEGY-INPUT-1')}
function Input-Failure([string]$code,[string]$reason){
 $actual='';try{$null=At58X-Input $o}catch{$actual=(At58-Error $_).Code}
 Check ($actual -ceq $code -and $o.InputDiagnostic.Reason -ceq $reason) ('distinguishes '+$reason+' without changing '+$code)
}
function Read-Events([string]$channel){
 @(Get-ChildItem -LiteralPath (Join-Path $dir 'input-diagnostics') -Filter ($channel+'-*.jsonl')|ForEach-Object{Get-Content -LiteralPath $_.FullName -Encoding UTF8|ForEach-Object{$_|ConvertFrom-Json}})
}
Input-Failure 'LIVE_INPUT_WAIT' 'FILE_MISSING'
Save-Input
$locked=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{Input-Failure 'LIVE_INPUT_WAIT' 'FILE_SHARING';Check ($o.InputDiagnostic.Error.Win32 -eq 32) 'records Windows sharing violation number'}finally{$locked.Dispose()}
At58-Atomic $path 'synthetic invalid base64 secret-not-for-logs'
Input-Failure 'LIVE_INPUT_WAIT' 'DECRYPT'
At58-Atomic $path ([Convert]::ToBase64String([byte[]]@(1,2,3,4)))
Input-Failure 'LIVE_INPUT_WAIT' 'DECRYPT'
Check ($o.InputDiagnostic.Error.ErrorType -ceq 'CryptographicException') 'separates invalid protected data from file access'
At58-Atomic $path (At58-Protect '{invalid secret-not-for-logs' 'AT58-STRATEGY-INPUT-1')
Input-Failure 'LIVE_INPUT_WAIT' 'JSON'
$raw.Utc='invalid-secret-not-for-logs';Save-Input
Input-Failure 'STRATEGY_TIME' 'TIMESTAMP'
$raw.Utc=$script:cashClock.AddSeconds(-121).ToString('o');Save-Input
Input-Failure 'LIVE_INPUT_WAIT' 'INPUT_EXPIRED'
Check ($o.InputDiagnostic.InputAgeSeconds -eq 121 -and $o.InputDiagnostic.File.Exists -and $o.InputDiagnostic.File.Bytes -gt 0) 'captures input age and encrypted file metadata'
$raw.Utc=$script:cashClock.AddSeconds(6).ToString('o');Save-Input
Input-Failure 'LIVE_INPUT_WAIT' 'INPUT_FUTURE'
$raw.Utc=$script:cashClock.ToString('o');$raw.Day='20261030';Save-Input
Input-Failure 'LIVE_INPUT_WAIT' 'INPUT_DAY'
$raw.Day='20261102';$raw.Utc=$script:cashClock.AddSeconds(-120).ToString('o');Save-Input
$result=At58X-Input $o
Check ($result.Source.Hash -ceq $f.Source.Hash -and !$o.InputDiagnostic) 'exact 120-second boundary remains accepted and clears input incident'
$events=Read-Events 'read'
Check (@($events|Where-Object Outcome -ceq 'INPUT_RECOVERED').Count -eq 1) 'records input recovery separately from account reconciliation'
$null=At58X-Input $o
Check ((Read-Events 'read').Count -eq $events.Count) 'healthy reads do not continuously append diagnostic events'
$raw.Utc=$script:cashClock.AddSeconds(5).ToString('o');Save-Input
Check ((At58X-Input $o).Source.Hash -ceq $f.Source.Hash) 'exact future-clock tolerance remains five seconds'
$o.LiveSession=@{RunId=$o.RunId;State='ARMED'}
$raw.Utc=$script:cashClock.AddSeconds(-121).ToString('o');Save-Input
$cycle=At58X-Cycle $o
Check ($cycle.Status.State -ceq 'ARMED' -and !$cycle.Status.ExecutionEnabled -and !$cycle.Status.Reconciled -and $cycle.Status.Confirmations -eq 0 -and $cycle.Status.OrdersSent -eq 0) 'failed input keeps intent but blocks orders and resets reconciliation'
$raw.Utc=$script:cashClock.ToString('o');Save-Input
$null=At58X-Input $o
Check ((At58X-Load $o).Confirmations -eq 0) 'input recovery alone does not grant account confirmations'
$all=(Read-Events 'read')|ConvertTo-Json -Depth 10 -Compress
Check ($all -notmatch 'secret-not-for-logs|synthetic-interest-key|synthetic-interest-secret|AppKey|AppSecret|Params|Ledger|Settings|C:\\') 'diagnostics omit raw input credentials exception messages and paths'

# Real Sheets input function with synthetic transport only. No installed paths or live API.
$script:testRaw=$f.Raw;$script:testMode='OK';$script:requests=0
function Invoke-RestMethod {
 param($Method,$Uri,$Headers,$TimeoutSec,$MaximumRedirection,$ErrorAction)
 $script:requests++
 if($Method -cne 'Get' -or !$Uri.StartsWith('https://synthetic.invalid/')){throw 'TEST_NETWORK_FORBIDDEN'}
 if(($script:testMode -ceq 'ROWS_TIMEOUT' -and $Uri.Contains('batchGet')) -or ($script:testMode -ceq 'SETTINGS_TIMEOUT' -and !$Uri.Contains('batchGet'))){throw [Net.WebException]::new('secret-not-for-logs',[Net.WebExceptionStatus]::Timeout)}
 if($Uri.Contains('batchGet')){return @{valueRanges=@(@{values=$script:testRaw.Params},@{values=$script:testRaw.Cycles},@{values=$script:testRaw.Ledger})}}
 return @{values=@()}
}
function Sheet-ImportSettings($rows){return ,$script:testRaw.Settings}
$meta=@{sheets=@()}
foreach($v in @(@('매매기준',2026102807),@('사이클관리',2026102806),@('매매일지',1136811970),@('운영설정',2026110202))){$meta.sheets+=@{properties=@{title=$v[0];sheetId=$v[1];gridProperties=@{rowCount=1000;columnCount=7}}}}
$ctx=At58ID-StartRefresh $dir
Sheet-StrategyInput @{} 'https://synthetic.invalid/sheet' $meta $f.Snapshot $dir $null $ctx
$ok=At58ID-ReadState $dir 'input-refresh-success.json'
Check ($ctx.InputSaved -and $ok.AttemptId -ceq $ctx.Id -and $ok.Stage -ceq 'INPUT_DONE' -and $script:requests -eq 2) 'successful refresh records a correlated attempt after atomic input save'
Check ($ok.ElapsedMs -ge 0 -and $ok.StartedUtc -and $ok.StageUtc) 'refresh records start completion and elapsed duration'
$savedInput=[IO.File]::ReadAllText($path)
foreach($v in @(@('ROWS_TIMEOUT','FETCH_ROWS'),@('SETTINGS_TIMEOUT','FETCH_SETTINGS'))){
 $script:testMode=$v[0];$ctx=At58ID-StartRefresh $dir
 try{Sheet-StrategyInput @{} 'https://synthetic.invalid/sheet' $meta $f.Snapshot $dir $null $ctx;throw 'TEST_EXPECTED_FAILURE'}catch{Check ($_.Exception.Message -cne 'TEST_EXPECTED_FAILURE') ('propagates '+$v[0])}
 $state=At58ID-ReadState $dir 'input-refresh-status.json';$log=(Read-Events 'refresh')|Where-Object {$_.AttemptId -ceq $ctx.Id -and $_.Outcome -ceq 'FAILED'}|Select-Object -Last 1
 Check ($state.Outcome -ceq 'FAILED' -and $state.Stage -ceq $v[1] -and $log.Error.Network -ceq 'Timeout') ('identifies '+$v[1]+' timeout without a response body')
 Check ([IO.File]::ReadAllText($path) -ceq $savedInput -and (At58ID-ReadState $dir 'input-refresh-success.json').AttemptId -ceq $ok.AttemptId) 'failed fetch preserves old input and last successful refresh evidence'
}
$script:testMode='OK';$ctx=At58ID-StartRefresh $dir
$locked=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{
 try{Sheet-StrategyInput @{} 'https://synthetic.invalid/sheet' $meta $f.Snapshot $dir $null $ctx;throw 'TEST_EXPECTED_FAILURE'}catch{Check ($_.Exception.Message -cne 'TEST_EXPECTED_FAILURE') 'input save still rejects exclusive file lock'}
 $state=At58ID-ReadState $dir 'input-refresh-status.json'
 Check ($state.Stage -ceq 'WRITE_INPUT' -and $state.Outcome -ceq 'FAILED' -and !$state.InputSaved) 'distinguishes local input write failure from remote fetch failure'
}finally{$locked.Dispose()}
$raw.Utc=$script:cashClock.AddSeconds(-121).ToString('o');Save-Input
Input-Failure 'LIVE_INPUT_WAIT' 'INPUT_EXPIRED'
Check ($o.InputDiagnostic.Refresh.AttemptId -ceq $ctx.Id -and $o.InputDiagnostic.Refresh.Stage -ceq 'WRITE_INPUT' -and $o.InputDiagnostic.LastSuccessfulRefresh.AttemptId -ceq $ok.AttemptId) 'read incident preserves active refresh stage and previous successful refresh'
$ctx=At58ID-StartRefresh $dir
At58ID-Refresh $ctx 'AUTH'
try{throw [Net.WebException]::new('https://secret-not-for-logs',[Net.WebExceptionStatus]::NameResolutionFailure)}catch{At58ID-Refresh $ctx 'FAILED' $_}
$state=At58ID-ReadState $dir 'input-refresh-status.json'
Check ($state.Stage -ceq 'AUTH' -and $state.Outcome -ceq 'FAILED') 'records failures before the strategy fetch begins'
At58ID-Refresh $ctx 'DONE'
Check ((At58ID-ReadState $dir 'input-refresh-status.json').Outcome -ceq 'FAILED') 'later display work cannot overwrite a failed input refresh'
$all=(Read-Events 'refresh')|ConvertTo-Json -Depth 10 -Compress
Check ($all -notmatch 'secret-not-for-logs|synthetic.invalid|Authorization|AppKey|client_email|private_key') 'refresh history contains no request URLs tokens or exception messages'

# Rotation, retention and diagnostic I/O must be independent of trading input.
$day=(At58-Kst $script:cashClock).ToString('yyyyMMdd');$diagDir=Join-Path $dir 'input-diagnostics';$logPath=Join-Path $diagDir ('read-'+$day+'.jsonl')
[IO.File]::WriteAllText($logPath,('x'*2097150))
At58ID-Write $dir 'read' @{Outcome='TEST'} $script:cashClock
Check ([IO.File]::Exists($logPath+'.1') -and ([IO.FileInfo]::new($logPath)).Length -lt 100) 'rotates before exceeding the two-MiB per-file bound'
$old=Join-Path $diagDir ('read-'+(At58-Kst $script:cashClock).AddDays(-7).ToString('yyyyMMdd')+'.jsonl')
$keep=Join-Path $diagDir ('read-'+(At58-Kst $script:cashClock).AddDays(-6).ToString('yyyyMMdd')+'.jsonl')
$unrelated=Join-Path $diagDir 'unrelated.txt'
[IO.File]::WriteAllText($old,'old');[IO.File]::WriteAllText($keep,'keep');[IO.File]::WriteAllText($unrelated,'keep')
At58ID-Write $dir 'read' @{Outcome='TEST'} $script:cashClock
Check (![IO.File]::Exists($old) -and [IO.File]::Exists($keep) -and [IO.File]::Exists($unrelated)) 'retains seven dates and removes only exact diagnostic log names'
$size=([IO.FileInfo]::new($logPath)).Length
At58ID-Write $dir 'read' @{Oversized=('x'*17000)} $script:cashClock
Check (([IO.FileInfo]::new($logPath)).Length -eq $size) 'oversized diagnostics are dropped rather than growing without bound'
$raw.Utc=$script:cashClock.ToString('o');Save-Input
$locked=[IO.File]::Open($logPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{
 Check ((At58X-Input $o).Source.Hash -ceq $f.Source.Hash) 'diagnostic write failure cannot block valid input recovery'
 $raw.Utc=$script:cashClock.AddSeconds(-121).ToString('o');Save-Input
 Input-Failure 'LIVE_INPUT_WAIT' 'INPUT_EXPIRED'
}finally{$locked.Dispose()}
Check ($o.LiveSession.State -ceq 'ARMED' -and (At58T-Load (At58X-Context $o)).Orders.Count -eq 0) 'diagnostic tests never change operator intent or submit an order'
'INPUT DIAGNOSTIC TESTS COMPLETE: '+$script:passed+' passed; isolated files and synthetic transport only.'
