#requires -Version 5.1
param([string]$Root=$PSScriptRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
. (Join-Path $Root 'bundle/At58.Ops.ps1')
. (Join-Path $Root 'bundle/At58.Sheets.ps1')
$script:checks=0
function Check($ok,[string]$message){if(!$ok){throw ('FAILED: '+$message)};$script:checks++;Write-Output ('PASS '+$message)}
function Throws([scriptblock]$action,[string]$code){$actual='';try{$null=& $action}catch{$actual=$_.Exception.Message};Check ($actual -ceq $code) $code}
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('AvataAuthRemote-'+[guid]::NewGuid().ToString('N'))
$data=Join-Path $tmp 'data';$manage=Join-Path $tmp 'manage';$hostRoot=Join-Path $tmp 'host'
foreach($path in @($data,$manage,$hostRoot)){[void][IO.Directory]::CreateDirectory($path)}
$now=([datetimeoffset]'2026-11-07T12:00:00Z').UtcDateTime;$runId='11111111-1111-4111-8111-111111111111';$device='22222222-2222-4222-8222-222222222222'
$secret='AUTH_REMOTE_PRIVATE_CANARY'
function Save-Lines([string]$path,$records){$lines=@($records|ForEach-Object {$_|ConvertTo-Json -Depth 12 -Compress});[IO.File]::WriteAllText($path,($lines -join "`n")+"`n",[Text.UTF8Encoding]::new($false))}
function Copy-Record($record){$r=[ordered]@{};foreach($key in $record.Keys){$r[$key]=$record[$key]};return $r}
try{
 $rejected=[ordered]@{Schema='AT-AUTH-EVENT-1';Utc=$now.ToString('o');RunId=$runId;Role='READER';Event='TOKEN_REJECTED';Code='TOKEN_EXPIRED';ApiCode='EGW00123';Stage='/accounts/v1/me/transactions';Http=500;Attempt=1;Failures=1;Issued=$true;SameRejectedToken=$true;TokenComparisonKnown=$true;TokenAgeSeconds=0;RemainingSeconds=43140;LifetimeSeconds=43200;RetrySeconds=60;RetryUtc=$now.AddSeconds(60).ToString('o');Token=$secret;AppKey=$secret;AppSecret=$secret;Scope=$secret;TokenHash=$secret;Message=$secret;Account=$secret;Error=@{Message=$secret}}
 $clean=SheetDiag-Clean $rejected
 Check ($clean.Role -ceq 'READER' -and $clean.Event -ceq 'TOKEN_REJECTED' -and $clean.Code -ceq 'TOKEN_EXPIRED' -and $clean.ApiCode -ceq 'EGW00123' -and $clean.Http -eq 500) 'auth diagnostics preserve source role issuance stage and broker rejection code'
 Check ($clean.Issued -eq $true -and $clean.SameRejectedToken -eq $true -and $clean.TokenComparisonKnown -eq $true -and $clean.TokenAgeSeconds -eq 0 -and $clean.LifetimeSeconds -eq 43200 -and $clean.RemainingSeconds -eq 43140) 'bounded auth evidence distinguishes fresh issue from cached expiry without token identifiers'
 Check ($clean.RetrySeconds -eq 60 -and $clean.RetryUtc -ceq $now.AddSeconds(60).ToString('o') -and $clean.Attempt -eq 1 -and $clean.Failures -eq 1) 'retry backoff metadata survives safe projection'
 Check (!(($clean|ConvertTo-Json -Depth 8).Contains($secret)) -and !$clean.Contains('Token') -and !$clean.Contains('Scope') -and !$clean.Contains('TokenHash')) 'credentials tokens hashes account identity and raw messages are excluded'
 $mal=Copy-Record $rejected;$mal.Role=$secret
 Check ((SheetDiag-Clean $mal).Count -eq 0) 'unknown auth role is excluded'
 $mal=Copy-Record $rejected;$mal.Event=$secret
 Check ((SheetDiag-Clean $mal).Count -eq 0) 'unknown auth event is excluded'
 $mal=Copy-Record $rejected;$mal.Schema='AT-AUTH-PRIVATE-1'
 Check ((SheetDiag-Clean $mal).Count -eq 0) 'unknown auth schema cannot fall back to generic diagnostic fields'
 $mal=Copy-Record $rejected;$mal.Code=$secret;$mal.Stage=$secret;$mal.ApiCode='secret raw message';$mal.Http=600;$mal.Attempt=3;$mal.Failures=11;$mal.RetrySeconds=301;$mal.TokenAgeSeconds=-2;$mal.RemainingSeconds='1.5';$mal.LifetimeSeconds=2147483648L;$mal.RetryUtc=$secret;$mal.Issued='true';$mal.SameRejectedToken='false';$mal.TokenComparisonKnown='false'
 $filtered=SheetDiag-Clean $mal
 Check (!(($filtered|ConvertTo-Json).Contains($secret)) -and !$filtered.Contains('Code') -and !$filtered.Contains('Stage') -and !$filtered.Contains('ApiCode')) 'auth strings use exact events and known API paths rather than arbitrary printable identifiers'
 Check (!$filtered.Contains('Http') -and !$filtered.Contains('Attempt') -and !$filtered.Contains('Failures') -and !$filtered.Contains('RetrySeconds') -and !$filtered.Contains('TokenAgeSeconds') -and !$filtered.Contains('RemainingSeconds') -and !$filtered.Contains('LifetimeSeconds')) 'out of range fractional and overflow metrics are excluded'
 Check (!$filtered.Contains('RetryUtc') -and !$filtered.Contains('Issued') -and !$filtered.Contains('SameRejectedToken') -and !$filtered.Contains('TokenComparisonKnown')) 'invalid timestamps and string booleans are excluded'
 $unknown=Copy-Record $rejected;$unknown.TokenAgeSeconds=-1;$unknown.RemainingSeconds=-1;$unknown.LifetimeSeconds=-1
 $unknown=SheetDiag-Clean $unknown
 Check ($unknown.TokenAgeSeconds -eq -1 -and $unknown.RemainingSeconds -eq -1 -and $unknown.LifetimeSeconds -eq -1) 'unknown token timing is distinct from zero seconds'
 $readerStatus=Copy-Record $rejected;$readerStatus.Schema='AT-AUTH-STATUS-1'
 Save-Lines (Join-Path $data 'auth-reader-status.json') @($readerStatus)
 $asset=Copy-Record $rejected;$asset.Role='ASSET';$asset.Utc=$now.AddSeconds(1).ToString('o');$asset.SameRejectedToken=$false
 $assetStatus=Copy-Record $asset;$assetStatus.Schema='AT-AUTH-STATUS-1'
 Save-Lines (Join-Path $data 'auth-asset-status.json') @($assetStatus)
 $issued=Copy-Record $rejected;$issued.Event='TOKEN_ISSUED';$issued.Code='OK';$issued.Stage='AUTH';$issued.Utc=$now.AddSeconds(-1).ToString('o')
 $recovered=Copy-Record $rejected;$recovered.Event='AUTH_RECOVERED';$recovered.Code='OK';$recovered.Utc=$now.AddSeconds(65).ToString('o')
 Save-Lines (Join-Path $data 'auth-reader-20261107.jsonl') @($issued,$rejected,$recovered)
 Save-Lines (Join-Path $data 'auth-asset-20261107.jsonl') @($asset)
 $previous=Copy-Record $rejected;$previous.Utc=$now.AddDays(-1).ToString('o')
 Save-Lines (Join-Path $data 'auth-reader-20261106.jsonl') @($previous)
 foreach($day in @('20261105','20261108')){Save-Lines (Join-Path $data ('auth-reader-'+$day+'.jsonl')) @($rejected)}
 $before=@(Get-ChildItem -LiteralPath $data -Recurse -File|ForEach-Object {$_.FullName+'|'+(Get-FileHash -LiteralPath $_.FullName).Hash}) -join ';'
 $snapshot=SheetDiag-Snapshot $data $manage $hostRoot $now.AddSeconds(90)
 $statuses=@($snapshot.Sources|Where-Object {$_.File -like 'auth-*-status.json'})
 Check ($statuses.Count -eq 2 -and @($statuses|Where-Object {$_.Read -ceq 'OK'}).Count -eq 2 -and @($statuses|Where-Object {$_.Data.Role -ceq 'READER'}).Count -eq 1 -and @($statuses|Where-Object {$_.Data.Role -ceq 'ASSET'}).Count -eq 1) 'reader and asset status files remain separate without overwriting each other'
 $logs=@($snapshot.ArchiveLogs|Where-Object {$_.File -like 'auth-*'})
 Check ($logs.Count -eq 5 -and @($logs|Where-Object {$_.File -ceq 'auth-reader-20261106.jsonl'}).Count -eq 1 -and @($logs|Where-Object {$_.File -ceq 'auth-asset-20261107.jsonl'}).Count -eq 1) 'only current and previous KST day role-specific auth logs are collected'
 Check (@($logs|Where-Object {$_.Data.Event -cin @('TOKEN_ISSUED','AUTH_RECOVERED') -and $_.Context}).Count -eq 2 -and @($logs|Where-Object {$_.Data.Code -ceq 'TOKEN_EXPIRED' -and !$_.Context}).Count -eq 3) 'issuance and recovery are healthy context while rejected tokens remain incidents'
 Check (!(($snapshot|ConvertTo-Json -Depth 15 -Compress).Contains($secret))) 'remote snapshot never contains raw private auth fields'
 $rows=SheetDiag-Values $snapshot $device 1
 Check (@($rows|Where-Object {$_[0] -ceq 'STATUS' -and $_[1] -ceq 'auth-reader-status.json' -and $_[11].Contains('SameRejectedToken')}).Count -eq 1) 'rolling diagnostic sheet carries bounded authentication evidence'
 $after=@(Get-ChildItem -LiteralPath $data -Recurse -File|ForEach-Object {$_.FullName+'|'+(Get-FileHash -LiteralPath $_.FullName).Hash}) -join ';'
 Check ($before -ceq $after) 'auth collection does not mutate account data tokens or recovery state'
 $normal=Join-Path $tmp 'normal';[void][IO.Directory]::CreateDirectory($normal)
 Save-Lines (Join-Path $normal 'auth-reader-20261107.jsonl') @($issued,$recovered)
 Check (@((SheetDiag-Snapshot $normal $manage $hostRoot $now.AddSeconds(90)).ArchiveLogs).Count -eq 0) 'normal token issuance alone does not flood the archive'
 $script:sent=@()
 function SheetDiag-ArchiveConfig($headers,[string]$mainBase){return 'ARCHIVE_TEST_SHEET'}
 function SheetDiag-ArchiveTarget($headers,[string]$archiveId){return [pscustomobject]@{SpreadsheetId='ARCHIVE_TEST_SHEET';SheetId=77;Rows=1000}}
 function Invoke-RestMethod {param($Method,$Uri,$Headers,$ContentType,$Body,$TimeoutSec,$MaximumRedirection)
  if($Method -ceq 'Get'){return @{range="'진단로그'!A2:A1000";majorDimension='ROWS'}}
  $text=[Text.Encoding]::UTF8.GetString($Body);$script:sent+=,$text;$parsed=$text|ConvertFrom-Json
  return @{spreadsheetId='ARCHIVE_TEST_SHEET';replies=@($parsed.requests|ForEach-Object {@{}})}
 }
 $state=SheetDiag-ArchiveRun $snapshot @{} 'https://synthetic.invalid/MAIN' $device $manage
 Check ($state.Code -ceq 'OK' -and @($state.Pending).Count -eq 0 -and $state.NextSequence -eq 5 -and $script:sent.Count -eq 1) 'auth events pass queue validation and drain through mocked archive transport'
 Check ($script:sent[0].Contains('auth-reader-20261107.jsonl') -and $script:sent[0].Contains('auth-asset-20261107.jsonl') -and $script:sent[0].Contains('SameRejectedToken') -and $script:sent[0].Contains('RetryUtc') -and !$script:sent[0].Contains($secret)) 'archival payload preserves both roles and timing evidence without secrets'
 $disk=SheetDiag-ArchiveReadState $manage
 Check ($disk.Ready -and @($disk.Pending).Count -eq 0 -and @($disk.Seen).Count -eq 5) 'archive state round-trip accepts the new role-specific source names'
 $values=SheetDiag-ArchiveRow $logs[0] $device 1 ('a'*64);$values[4]='../auth-reader-20261107.jsonl'
 Throws {SheetDiag-ArchiveValidateEvent ([pscustomobject]@{Sequence=1;Key=('a'*64);Values=$values})} 'DIAG_ARCHIVE_EVENT'
 # Exercise the real short-lived asset worker with the real auth state machine.
 # Only protected storage, presentation, time and broker transport are synthetic.
 . (Join-Path $Root 'bundle/payload/At58.Core.ps1')
 $script:assetClock=$now;$script:assetIssues=0;$script:assetGets=0;$script:assetMode='REJECT';$script:assetStore=@{};$script:assetContexts=0
 $script:makeContext=(Get-Command At58-Context).ScriptBlock
 function Ops-Now {return $script:assetClock}
 function At58-Mac {return '112233445566'}
 function At58-Context([string]$root,[string]$symbol){
  $script:assetContexts++
  $ctx=& $script:makeContext $root $symbol ([pscustomobject]@{AppKey='synthetic-asset-key';AppSecret='synthetic-asset-secret'})
  $ctx.NoWait=$true;$ctx.Mac='112233445566';$ctx.Clock={return $script:assetClock}
  $ctx.Transport={param($method,$path,$query,$body,$token)
   if($path -ceq '/oauth2/token'){$script:assetIssues++;return [pscustomobject]@{access_token=('synthetic-asset-token-'+$script:assetIssues);expires_in=43200}}
   $script:assetGets++
   if($script:assetMode -ceq 'REJECT'){return [pscustomobject]@{rsp_cd='EGW00123';data=$null}}
   return [pscustomobject]@{rsp_cd='0000';rsp_sub_msg='';tr_cont='0';data=@()}
  }
  return $ctx
 }
 function Asset-ProtectedRead([string]$path,[string]$purpose){if($script:assetStore.ContainsKey($path)){return ($script:assetStore[$path]|ConvertFrom-Json)};return $null}
 function Asset-ProtectedWrite([string]$path,[string]$purpose,$value){$script:assetStore[$path]=$value|ConvertTo-Json -Depth 20 -Compress}
 function Asset-Ledger($rows){return [pscustomobject]@{From='20261107';Rows=@()}}
 function Asset-CostReport($ledger,$rows){return [pscustomobject]@{VerifiedDays=0;EstimatedDays=0}}
 function Asset-Payload($snapshot,$ledger,$report,$history,[int]$end){return [pscustomobject]@{End=55;Unknown=0}}
 function Asset-Publish($headers,$base,$payload,$scope,$gridRows,$outputRoot){return [pscustomobject]@{LastPublishedUtc=$script:assetClock.ToString('o');Cached=$true;Requests=0;WrittenRanges=0;WrittenCells=0;SkippedRanges=0;FullRefresh=$false}}
 $assetData=Join-Path $tmp 'asset-data';$assetOutput=Join-Path $tmp 'asset-output';foreach($p in @($assetData,$assetOutput)){[void][IO.Directory]::CreateDirectory($p)}
 $assetScope=At58-Hash 'synthetic-asset-key';$assetTokenPath=Join-Path $assetOutput 'assets-token.dpapi'
 Asset-ProtectedWrite $assetTokenPath 'AT-ASSET-TOKEN-1' @{Scope=$assetScope;Token='synthetic-already-rejected';Until=$script:assetClock.AddHours(12).ToString('o')}
 $meta=[pscustomobject]@{sheets=@([pscustomobject]@{properties=[pscustomobject]@{title='자산상세내역';sheetId=1830155726;gridProperties=[pscustomobject]@{columnCount=11;rowCount=500}}})}
 $assetSnapshot=[pscustomobject]@{Scope=$assetScope;Symbol='0210A0';Day='20261107';CompletedUtc=$script:assetClock.ToString('o')}
 $journal=[pscustomobject]@{Ledger=@()}
 Asset-Pump @{} 'https://synthetic.invalid/MAIN' $meta $assetSnapshot $journal $assetData $assetOutput
 $saved=Asset-ProtectedRead $assetTokenPath 'AT-ASSET-TOKEN-1'
 Check ($saved.Token -ceq '' -and $saved.Recovery.Role -ceq 'ASSET' -and $saved.Recovery.Failures -eq 1 -and $script:assetIssues -eq 1 -and $script:assetGets -eq 2) 'asset rejection clears the old persisted token and retains bounded recovery state'
 $script:assetClock=$script:assetClock.AddSeconds(20)
 Asset-Pump @{} 'https://synthetic.invalid/MAIN' $meta $assetSnapshot $journal $assetData $assetOutput
 Check ($script:assetContexts -eq 2 -and $script:assetIssues -eq 1 -and $script:assetGets -eq 2) 'a fresh asset worker imports cooldown instead of reloading and retrying the rejected token'
 $script:assetClock=$script:assetClock.AddSeconds(20)
 Asset-Pump @{} 'https://synthetic.invalid/MAIN' $meta $assetSnapshot $journal $assetData $assetOutput
 $saved=Asset-ProtectedRead $assetTokenPath 'AT-ASSET-TOKEN-1'
 Check ($saved.Token -ceq '' -and $saved.Recovery.Failures -eq 2 -and $script:assetIssues -eq 3 -and $script:assetGets -eq 4) 'after cooldown the asset worker probes again and persists increasing failure backoff'
 $script:assetClock=$script:assetClock.AddSeconds(20)
 $historyPath=Join-Path $assetOutput 'assets-history.dpapi'
 Asset-ProtectedWrite $historyPath 'AT-ASSET-HISTORY-1' @{Schema='AT-ASSETS-1';Scope=$assetScope;From='20261107';To='20261107';Phase='COMPLETE';CostRows=@();Transactions=@();StartedUtc=$script:assetClock.ToString('o');CompletedUtc=$script:assetClock.ToString('o')}
 $recoveryBefore=$saved.Recovery|ConvertTo-Json -Compress
 Asset-Pump @{} 'https://synthetic.invalid/MAIN' $meta $assetSnapshot $journal $assetData $assetOutput
 $saved=Asset-ProtectedRead $assetTokenPath 'AT-ASSET-TOKEN-1'
 Check ($script:assetIssues -eq 3 -and $script:assetGets -eq 4 -and ($saved.Recovery|ConvertTo-Json -Compress) -ceq $recoveryBefore -and $saved.Token -ceq '') 'a complete cached asset history preserves outstanding auth recovery without claiming a successful read'
 $script:assetStore.Remove($historyPath);$script:assetClock=$script:assetClock.AddSeconds(20)
 Asset-Pump @{} 'https://synthetic.invalid/MAIN' $meta $assetSnapshot $journal $assetData $assetOutput
 Check ($script:assetIssues -eq 3 -and $script:assetGets -eq 4) 'recreated asset workers do not reset repeated-failure backoff'
 $script:assetClock=$script:assetClock.AddSeconds(20);$script:assetMode='OK'
 Asset-Pump @{} 'https://synthetic.invalid/MAIN' $meta $assetSnapshot $journal $assetData $assetOutput
 $saved=Asset-ProtectedRead $assetTokenPath 'AT-ASSET-TOKEN-1'
 Check ($saved.Token -ceq 'synthetic-asset-token-4' -and $saved.Recovery.Failures -eq 0 -and $script:assetIssues -eq 4 -and $script:assetGets -eq 6) 'authenticated asset reads recover and persist a reusable token without touching trading intent'
 $assetAuth=SheetDiag-Json (Join-Path $assetData 'auth-asset-status.json')
 Check ($assetAuth.Role -ceq 'ASSET' -and $assetAuth.Event -ceq 'AUTH_RECOVERED' -and !(Test-Path (Join-Path $assetData 'auth-reader-status.json'))) 'real asset auth flow writes only its role-specific diagnostic status'
 Write-Output ('AUTH DIAGNOSTIC REMOTE PASSED: '+$script:checks+' checks; isolated files and mocked network only')
}finally{Remove-Item -LiteralPath $tmp -Recurse -Force}
