#requires -Version 5.1
param([string]$Root=$PSScriptRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
. (Join-Path $Root 'bundle/At58.Ops.ps1')
. (Join-Path $Root 'bundle/At58.Sheets.ps1')
$script:checks=0
function Check($ok,[string]$message){if(!$ok){throw ('FAILED: '+$message)};$script:checks++;Write-Output ('PASS '+$message)}
function Throws([scriptblock]$action,[string]$code){$actual='';try{& $action}catch{$actual=$_.Exception.Message};Check ($actual -ceq $code) $code}
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('avata-diag-test-'+[guid]::NewGuid().ToString('N'))
$data=Join-Path $tmp 'data';$manage=Join-Path $tmp 'manage';$hostRoot=Join-Path $tmp 'host'
foreach($p in @($data,$manage,$hostRoot)){[void][IO.Directory]::CreateDirectory($p)}
$now=[datetime]::Parse('2026-11-05T01:00:00Z').ToUniversalTime();$stamp=$now.ToString('o');$device='11111111-1111-4111-8111-111111111111'
try{
 $secret='DO_NOT_TRANSMIT_SECRET';$bad=@{Utc=$stamp;Code='LIVE_DISARMED';State='READ_OK';OrdersSent=0;ExecutionEnabled=$false;ApiKey=$secret;Token=$secret;Account=$secret;Balance=123;Orders=@($secret);Message=$secret;Path=$secret;CodeExtra=$secret}
 $clean=SheetDiag-Clean $bad;$json=$clean|ConvertTo-Json -Compress
 Check (!$json.Contains($secret) -and !$clean.Contains('Account') -and !$clean.Contains('Balance')) 'private fields and raw messages are excluded'
 Check ($clean.Code -ceq 'LIVE_DISARMED' -and !$clean.ExecutionEnabled -and $clean.OrdersSent -eq 0) 'diagnostic status remains useful'
 $mal=SheetDiag-Clean @{Code='=IMPORTXML("https://example.invalid")';ApiCode=$secret;Stage='C:\private\secret';RunId=$secret;OrdersSent=-1;ExecutionEnabled='true'}
 Check ($mal.Count -eq 0) 'malformed identifiers, formulas and untyped values rejected'
 SheetDiag-Write (Join-Path $data 'status.json') $bad
 SheetDiag-Write (Join-Path $data 'input-refresh-status.json') @{Utc=$stamp;Stage='VALIDATE';Outcome='FAILED';Error=@{ErrorType='FormatException';Http=0;Win32=5;Message=$secret}}
 SheetDiag-Write (Join-Path $manage 'runtime.json') @{Utc=$stamp;LiveState='DISARMED';CommandError='LIVE_SOURCE_CHANGED';AutoStartCode='COMMAND_REVIEW';AutoStartEnabled=$true;AutoStartAttempted=$true;Token=$secret}
 [IO.File]::WriteAllText((Join-Path $data 'credentials.dpapi'),$secret)
 [IO.File]::WriteAllText((Join-Path $data 'snapshot.dpapi'),$secret)
 $log=Join-Path $data 'read-20261105.jsonl'
 [IO.File]::WriteAllText($log,((@{Utc=$stamp;Code='LIVE_INPUT_WAIT';Stage='LIVE_CONTROL';Token=$secret}|ConvertTo-Json -Compress)+"`n"+'{partial'),[Text.UTF8Encoding]::new($false))
 $snapshot=SheetDiag-Snapshot $data $manage $hostRoot $now
 Check ($snapshot.Logs.Count -eq 1) 'partial final log line ignored'
 Check (!(($snapshot|ConvertTo-Json -Depth 10 -Compress).Contains($secret))) 'status and log snapshot exclude canary secrets'
 Check (@($snapshot.Sources|Where-Object File -ceq 'snapshot.dpapi').Count -eq 0) 'account snapshots and credentials never collected'
 $input=@($snapshot.Sources|Where-Object File -ceq 'input-refresh-status.json')[0]
 Check ($input.Data.ErrorType -ceq 'FormatException' -and $input.Data.Win32 -eq 5) 'bounded input failure details retained'
 $runtime=@($snapshot.Sources|Where-Object File -ceq 'runtime.json')[0]
 Check ($runtime.Data.CommandError -ceq 'LIVE_SOURCE_CHANGED' -and $runtime.Data.AutoStartAttempted) 'automatic start failure context retained'
 $rows=SheetDiag-Values $snapshot $device 9
 Check ($rows.Count -eq 400 -and @($rows|Where-Object {$_.Count -ne 13}).Count -eq 0) 'fixed bounded 400 by 13 payload'
 Check ($rows[0][3] -ceq 'MAINPC' -and $rows[1][9] -ceq 'APP_FRESH') 'main PC identity and fresh original timestamp'
 $stale=SheetDiag-Snapshot $data $manage $hostRoot $now.AddMinutes(5)
 $rows=SheetDiag-Values $stale $device 10
 Check ($rows[1][9] -ceq 'APP_STALE' -and $rows[1][7] -ceq 'RUNNING') 'fresh collector does not hide stale app status'
 $reverse=SheetDiag-Snapshot $data $manage $hostRoot $now.AddMinutes(-2)
 Check ((SheetDiag-Values $reverse $device 11)[1][9] -ceq 'APP_STALE') 'future original clock flagged'
 [IO.File]::WriteAllText((Join-Path $data 'status.json'),'{invalid')
 $missing=SheetDiag-Snapshot $data $manage $hostRoot $now
 Check (@($missing.Sources|Where-Object {$_.File -ceq 'status.json' -and $_.Read -ceq 'READ_ERROR'}).Count -eq 1) 'broken app status does not stop collection'
 Check ((SheetDiag-Values $missing $device 12)[1][9] -ceq 'APP_STALE') 'invalid original file flagged'
 [IO.File]::WriteAllText((Join-Path $data 'status.json'),('x'*2097153))
 Check ((SheetDiag-ReadStatus $data 'status.json' $now).Read -ceq 'READ_ERROR') 'oversized JSON rejected'
 [IO.File]::WriteAllText($log,('x'*300000)+"`n"+(@{Utc=$stamp;Code='OK'}|ConvertTo-Json -Compress)+"`n")
 $tail=@(SheetDiag-Tail $log 1000)
 Check ($tail.Count -eq 1 -and $tail[0].Contains('OK')) 'tail reads at most 256 KiB and drops truncated first record'
 $first=SheetDiag-Identity $manage;$second=SheetDiag-Identity $manage
 Check ($first -ceq $second -and $first.Length -eq 36) 'device identity persists across restart'
 for($i=0;$i -lt 20;$i++){SheetDiag-Write (Join-Path $manage 'atomic.json') @{Sequence=$i}}
 Check ((SheetDiag-Json (Join-Path $manage 'atomic.json')).Sequence -eq 19) 'Windows atomic replacement supports repeated saves'

 $script:apiCalls=@();$script:owner=$device;$script:tabMode='OWNED';$script:failSend=$false
 function Invoke-RestMethod {
  param($Method,$Uri,$Headers,$ContentType,$Body,$TimeoutSec,$MaximumRedirection)
  $script:apiCalls+=,@{Method=$Method;Uri=$Uri;Body=$Body}
  if($Uri -like '*?fields=*'){
   if($script:tabMode -ceq 'ABSENT'){return @{sheets=@()}}
   $title=if($script:tabMode -ceq 'COLLISION'){'existing user tab'}else{'메인PC_진단'}
   return @{sheets=@(@{properties=@{sheetId=2026110590;title=$title;gridProperties=@{rowCount=400;columnCount=13}}})}
  }
  if($Uri.EndsWith(':batchUpdate')){$parsed=[Text.Encoding]::UTF8.GetString($Body)|ConvertFrom-Json;$script:owner=$parsed.requests[1].updateCells.rows[0].values[1].userEnteredValue.stringValue;$script:tabMode='OWNED';return @{spreadsheetId='SYNTHETIC_SHEET';replies=@(@{},@{})}}
  if($Method -ceq 'Get'){return @{values=@(,@('AVATA_MAINPC_LOG_1',$script:owner,'1.1.3','MAINPC'))}}
  if($script:failSend){throw 'HTTP body containing private diagnostic secret'}
  return @{spreadsheetId='SYNTHETIC_SHEET';updatedRows=400;updatedColumns=13}
 }
 $base='https://sheets.googleapis.com/v4/spreadsheets/SYNTHETIC_SHEET'
 SheetDiag-Send $snapshot @{} $base $device 20
 Check (@($script:apiCalls|Where-Object Method -ceq 'Put').Count -eq 1) 'authorized tab receives one write'
 $write=@($script:apiCalls|Where-Object Method -ceq 'Put')[0]
 Check ($write.Uri -like '*valueInputOption=RAW' -and [uri]::UnescapeDataString($write.Uri).Contains("'메인PC_진단'!A1:M400")) 'write is restricted to diagnostic tab with raw values'
 Check (![Text.Encoding]::UTF8.GetString($write.Body).Contains($secret)) 'outgoing HTTP body contains no canary secret'
 $script:owner='22222222-2222-4222-8222-222222222222';$script:apiCalls=@()
 Throws {SheetDiag-Send $snapshot @{} $base $device 21} 'DIAG_DEVICE_MISMATCH'
 Check (@($script:apiCalls|Where-Object Method -ceq 'Put').Count -eq 0) 'another PC cannot overwrite owner diagnostics'
 $script:tabMode='COLLISION';$script:apiCalls=@()
 Throws {SheetDiag-Send $snapshot @{} $base $device 22} 'DIAG_TAB_MISMATCH'
 Check (@($script:apiCalls|Where-Object {$_.Method -cne 'Get'}).Count -eq 0) 'existing unrelated tab remains untouched'
 $script:tabMode='ABSENT';$script:apiCalls=@()
 SheetDiag-Send $snapshot @{} $base $device 23
 Check ($script:owner -ceq $device -and @($script:apiCalls|Where-Object Method -ceq 'Post').Count -eq 1) 'new tab and ownership created atomically'
 $script:failSend=$true
 function Sheet-Config($root){return @{Enabled=$true;SheetId=('s'*30);KeyPath='NO_REAL_KEY'}}
 function Sheet-Id($value){return 'SYNTHETIC_SHEET'}
 function SheetDiag-Auth($cfg,$root){return 'SYNTHETIC_TOKEN'}
 $script:owner=$first
 $beforeFiles=@(Get-ChildItem $data|ForEach-Object {$_.Name+'|'+(Get-FileHash $_.FullName).Hash}) -join ';'
 Check ((SheetDiag-Run $data $manage) -eq 1) 'transport failure returns independent failure status'
 $result=SheetDiag-Json (Join-Path $manage 'diagnostics-status.json')
 Check ($result.Code -ceq 'DIAG_TRANSPORT_OR_STORAGE' -and !(($result|ConvertTo-Json).Contains('private'))) 'raw network errors are never persisted or transmitted'
 $script:failSend=$false
 Check ((SheetDiag-Run $data $manage) -eq 0) 'collection succeeds without snapshot decryption or ledger validation'
 $afterFiles=@(Get-ChildItem $data|ForEach-Object {$_.Name+'|'+(Get-FileHash $_.FullName).Hash}) -join ';'
 Check ($beforeFiles -ceq $afterFiles) 'diagnostic worker never changes application data or trading controls'
 $worker=[IO.File]::ReadAllText((Join-Path $Root 'bundle/At58.SheetWorker.ps1'))
 Check ($worker.IndexOf('if($Diagnostics)') -lt $worker.IndexOf('At58ID-StartRefresh') -and $worker.IndexOf('if($Diagnostics)') -lt $worker.IndexOf('payload/At58.Core.ps1')) 'diagnostic branch runs before strategy input and trading core'
 $manager=[IO.File]::ReadAllText((Join-Path $Root 'bundle/At58.Manager.ps1'))
 Check ($manager.IndexOf('SheetDiag-Pump') -lt $manager.IndexOf('$exited=$child.Process.HasExited') -and $manager.Contains('SheetDiag-StopPump')) 'diagnostics have independent manager lifecycle'
 Write-Output ('MAIN PC DIAGNOSTICS PASSED: '+$script:checks+' checks; synthetic files and mocked network only')
}finally{Remove-Item -LiteralPath $tmp -Recurse -Force}
