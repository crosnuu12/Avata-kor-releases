#requires -Version 5.1
param([string]$Root=$PSScriptRoot,[string]$SheetsSource='')
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
. (Join-Path $Root 'bundle/At58.Ops.ps1')
. (Join-Path $Root 'bundle/payload/At58.Core.ps1')
if(!$SheetsSource){$SheetsSource=Join-Path $Root 'bundle/At58.Sheets.ps1'}
. $SheetsSource
$script:checks=0;$script:posts=0;$script:wire=0;$script:clock=([datetimeoffset]'2026-11-05T07:00:00Z').UtcDateTime
function Check($ok,[string]$name){if(!$ok){throw ('FAILED: '+$name)};$script:checks++;Write-Output ('PASS '+$name)}
function Ops-Now {return $script:clock}
function At58T-Wire {$script:wire++;throw 'BROKER_FORBIDDEN'}
$script:At58SheetId='synthetic-sheet';$scope='synthetic-account';$target=Ops-Key ('AT-ASSET-PRESENTATION-1|'+$script:At58SheetId+'|'+$scope)
function Snapshot {return [pscustomobject]@{Scope=$scope;Symbol='0210A0';CompletedUtc=$script:clock.ToString('o');Day='20261105';TargetQty=3;Cash=[pscustomobject]@{Withdrawable=10000;D1=10000};Valuation=[pscustomobject]@{}}}
function LedgerRows([int]$count=1){$r=New-Object 'Collections.Generic.List[object]';$r.Add([object[]]@('날짜','차수','구분','가격','수량','금액'));for($i=0;$i -lt $count;$i++){$r.Add([object[]]@(46331,1,'매수',100,3,300))};return ,$r.ToArray()}
function Payload([int]$count=1,[int]$previousEnd=55){$ledger=Asset-Ledger (LedgerRows $count);$report=Asset-CostReport $ledger @();return (Asset-Payload (Snapshot) $ledger $report $null $previousEnd)}
function IsRequest($request,[string]$kind){return $null -ne (At58-Value $request $kind)}
function Plans($p,[string]$kind){return ,@($p.Requests|Where-Object {IsRequest $_ $kind})}
function CheckLayout($plan,$payload,[int]$expectedEnd,[string]$name){
 $formats=@((Plans $plan 'repeatCell')|Where-Object {$_.repeatCell.fields -cne 'userEnteredValue'})
 $base=@($formats|Where-Object {$_.repeatCell.cell.userEnteredFormat.textFormat.bold -eq $false})
 $headers=@($formats|Where-Object {$_.repeatCell.cell.userEnteredFormat.textFormat.bold -eq $true})
 Check ($base.Count -eq 1 -and $base[0].repeatCell.range.startRowIndex -eq 54 -and $base[0].repeatCell.range.endRowIndex -eq $expectedEnd) ($name+': base format covers the current table and intended stale tail')
 $expected=@(54,($payload.TransactionHeader-1),$payload.TransactionHeader)|Sort-Object
 $actual=@($headers|ForEach-Object {$_.repeatCell.range.startRowIndex})|Sort-Object
 $wide=@($headers|Where-Object {$_.repeatCell.range.endRowIndex -ne ($_.repeatCell.range.startRowIndex+1)})
 Check ($headers.Count -eq 3 -and $wide.Count -eq 0 -and ($actual -join ',') -ceq ($expected -join ',')) ($name+': all three title formats stay on their single header rows')
}
$p=Payload;$plan=Asset-PublishPlan $p $null $target 500 $script:clock
CheckLayout $plan $p $p.End 'initial publication'
Check ($plan.Requests.Count -gt 0 -and (Plans $plan 'updateCells').Count -gt 30) 'first publication writes complete report values'
Check ((Plans $plan 'appendDimension').Count -eq 0) 'small report uses existing compact sheet capacity'
Check (@((Plans $plan 'repeatCell')|Where-Object {$_.repeatCell.fields -ceq 'userEnteredValue'}).Count -eq 0) 'normal table overwrite avoids redundant clear of all cells'
$formula=@((Plans $plan 'updateCells')|Where-Object {$_.updateCells.start.rowIndex -eq 41 -and $_.updateCells.start.columnIndex -eq 4})[0].updateCells.rows[0].values[0].userEnteredValue.formulaValue
Check ($formula.Contains('A56:A'+$p.End) -and !$formula.Contains('60054')) 'date range formula is bounded to actual generated content'
$cache=$plan.Cache|ConvertTo-Json -Depth 20 -Compress|ConvertFrom-Json
$stable=Asset-PublishPlan $p $cache $target 500 $script:clock.AddSeconds(20)
Check ($stable.Requests.Count -eq 0) 'identical report causes zero API write requests'
Check ($stable.Cache.LastWriteUtc -ceq $cache.LastWriteUtc) 'skipped write retains actual last publication time'
$asset=Snapshot;$asset.Cash.Withdrawable=9000;$ledger=Asset-Ledger (LedgerRows);$report=Asset-CostReport $ledger @();$changed=Asset-Payload $asset $ledger $report $null
$one=Asset-PublishPlan $changed $cache $target 500 $script:clock.AddSeconds(20)
Check ($one.Requests.Count -eq 1 -and $one.Requests[0].updateCells.start.rowIndex -eq 17 -and $one.Requests[0].updateCells.rows[0].values[0].userEnteredValue.numberValue -eq 9000) 'cash change writes only its actual summary cell'
Check ((Plans $one 'repeatCell').Count -eq 0 -and (Plans $one 'autoResizeDimensions').Count -eq 0) 'ordinary balance change does not reformat or resize table'
$report.Rows[0][3]=101;$changed=Asset-Payload (Snapshot) $ledger $report $null
$price=Asset-PublishPlan $changed $cache $target 500 $script:clock.AddSeconds(20)
Check (@((Plans $price 'updateCells')|Where-Object {$_.updateCells.start.rowIndex -eq 54}).Count -eq 1) 'changed actual price always rewrites detail values'
$old=Asset-PublishPlan $p $cache $target 500 $script:clock.AddSeconds(301)
Check ((Plans $old 'updateCells').Count -eq (Plans $plan 'updateCells').Count) 'periodic value refresh repairs changes outside app'
Check ((Plans $old 'repeatCell').Count -eq 0) 'periodic value refresh does not reapply unchanged formatting'
$other=Asset-PublishPlan $p $cache (Ops-Key 'different-sheet-and-account') 500 $script:clock.AddSeconds(20)
Check ((Plans $other 'updateCells').Count -eq (Plans $plan 'updateCells').Count) 'cache cannot cross spreadsheet or account scope'
$wrong=$cache|ConvertTo-Json -Depth 20|ConvertFrom-Json;$wrong.Schema='OLD'
Check ((Asset-PublishPlan $p $wrong $target 500 $script:clock).Requests.Count -gt 0) 'old cache schema is not trusted'
$big=Payload 450;$grow=Asset-PublishPlan $big $cache $target 500 $script:clock.AddSeconds(20)
CheckLayout $grow $big $big.End 'capacity growth'
Check ($grow.GridRows -eq 750 -and (Plans $grow 'appendDimension')[0].appendDimension.length -eq 250) 'capacity grows in bounded chunks only when content exceeds grid'
Check ($grow.Requests[0].ContainsKey('appendDimension') -and $grow.Requests[1].ContainsKey('copyPaste')) 'capacity and inherited styles precede data writes'
Check ((Plans $grow 'copyPaste')[0].copyPaste.pasteType -ceq 'PASTE_FORMAT') 'row growth copies formatting without copying old values'
$grownCache=$grow.Cache|ConvertTo-Json -Depth 20|ConvertFrom-Json
Check ((Plans (Asset-PublishPlan $big $grownCache $target 750 $script:clock.AddSeconds(30)) 'appendDimension').Count -eq 0) 'repeated report never grows sheet again'
$shrunk=Asset-PublishPlan $p $grownCache $target 750 $script:clock.AddSeconds(30)
CheckLayout $shrunk $p $big.End 'table shrink'
$clear=@((Plans $shrunk 'repeatCell')|Where-Object {$_.repeatCell.fields -ceq 'userEnteredValue'})
Check ($clear.Count -eq 1 -and $clear[0].repeatCell.range.startRowIndex -eq $p.End -and $clear[0].repeatCell.range.endRowIndex -eq $big.End) 'shrinking report clears only stale generated tail'
$pending=[pscustomobject]@{Schema='AT-ASSET-PENDING-1';Target=$target;End=$big.End;StartedUtc=$script:clock.ToString('o')}
$ambiguous=Asset-PublishPlan $p $cache $target 750 $script:clock.AddSeconds(30) $pending
$clear=@((Plans $ambiguous 'repeatCell')|Where-Object {$_.repeatCell.fields -ceq 'userEnteredValue'})
Check ($clear.Count -eq 1 -and $clear[0].repeatCell.range.endRowIndex -eq $big.End) 'unacknowledged prior larger report is cleared on retry'
Check ((Plans $ambiguous 'updateCells').Count -eq (Plans $plan 'updateCells').Count) 'ambiguous write forces complete value repair'
Check ($stable.WrittenCells -eq 0 -and $stable.WrittenRanges -eq 0 -and $stable.SkippedRanges -gt 30 -and !$stable.FullRefresh) 'cached report diagnostics expose zero writes and skipped ranges'
Check ($one.WrittenCells -eq 1 -and $one.WrittenRanges -eq 1) 'one-cell change metrics describe actual request size'
Check ($old.FullRefresh -and $old.WrittenCells -gt $one.WrittenCells) 'periodic refresh is explicit in bounded diagnostics'
$rules=@(
 [pscustomobject]@{ranges=@([pscustomobject]@{sheetId=1830155726;startRowIndex=55;endRowIndex=500;startColumnIndex=0;endColumnIndex=11},[pscustomobject]@{sheetId=1830155726;startRowIndex=8;endRowIndex=20;startColumnIndex=0;endColumnIndex=11});booleanRule=[pscustomobject]@{condition=[pscustomobject]@{type='CUSTOM_FORMULA';values=@([pscustomobject]@{userEnteredValue='=$C56="매수"'})};format=[pscustomobject]@{textFormat=[pscustomobject]@{foregroundColor=[pscustomobject]@{red=1;green=0;blue=0}}}}},
 [pscustomobject]@{ranges=@([pscustomobject]@{sheetId=1830155726;startRowIndex=55;endRowIndex=200;startColumnIndex=0;endColumnIndex=11});booleanRule=[pscustomobject]@{condition=[pscustomobject]@{type='NUMBER_GREATER';values=@([pscustomobject]@{userEnteredValue='0'})};format=[pscustomobject]@{textFormat=[pscustomobject]@{bold=$true}}}}
)
$withRules=Asset-PublishPlan $big $cache $target 500 $script:clock.AddSeconds(20) $null $rules
$extended=Plans $withRules 'updateConditionalFormatRule'
Check ($extended.Count -eq 1 -and $extended[0].updateConditionalFormatRule.index -eq 0 -and $extended[0].updateConditionalFormatRule.rule.ranges[0].endRowIndex -eq 750) 'capacity growth explicitly extends existing data conditional formatting'
Check ($extended[0].updateConditionalFormatRule.rule.ranges[1].endRowIndex -eq 20 -and $rules[0].ranges[0].endRowIndex -eq 500) 'conditional summary ranges and source metadata remain unchanged'
Check ($extended[0].updateConditionalFormatRule.rule.booleanRule.condition.values[0].userEnteredValue -ceq '=$C56="매수"') 'conditional-format formula and colors survive exact rule replacement'
# A structurally invalid persisted state can never authorize an unchanged no-op.
function CopyState($value){return ($value|ConvertTo-Json -Depth 30|ConvertFrom-Json)}
$invalidCache=@(
 @{Name='missing end';Change={param($x)$x.PSObject.Properties.Remove('End')}},
 @{Name='oversized end';Change={param($x)$x.End=60056}},
 @{Name='fractional end';Change={param($x)$x.End=60.5}},
 @{Name='invalid transaction header';Change={param($x)$x.TransactionHeader=$x.End}},
 @{Name='missing hashes';Change={param($x)$x.PSObject.Properties.Remove('Hashes')}},
 @{Name='wrong hash container';Change={param($x)$x.Hashes='invalid'}},
 @{Name='missing hash key';Change={param($x)$x.Hashes.PSObject.Properties.Remove('54|0')}},
 @{Name='malformed digest';Change={param($x)$x.Hashes.'54|0'='bad'}},
 @{Name='future full refresh';Change={param($x)$x.FullValuesUtc=$script:clock.AddMinutes(1).ToString('o')}},
 @{Name='future write time';Change={param($x)$x.LastWriteUtc=$script:clock.AddMinutes(1).ToString('o')}},
 @{Name='unparseable time';Change={param($x)$x.LastWriteUtc='today'}},
 @{Name='reversed time order';Change={param($x)$x.LastWriteUtc=$script:clock.AddSeconds(-1).ToString('o')}}
)
foreach($case in $invalidCache){
 $bad=CopyState $cache;& $case.Change $bad;$repair=Asset-PublishPlan $p $bad $target 500 $script:clock.AddSeconds(20)
 $tail=@((Plans $repair 'repeatCell')|Where-Object {$_.repeatCell.fields -ceq 'userEnteredValue'})
 Check ($repair.FullRefresh -and (Plans $repair 'updateCells').Count -eq (Plans $plan 'updateCells').Count -and $tail.Count -eq 1 -and $tail[0].repeatCell.range.startRowIndex -eq $p.End -and $tail[0].repeatCell.range.endRowIndex -eq 500) ('invalid cache conservatively repairs owned grid: '+$case.Name)
}
$invalidPending=@(
 @{Name='wrong schema';Change={param($x)$x.Schema='OLD'}},
 @{Name='missing target';Change={param($x)$x.PSObject.Properties.Remove('Target')}},
 @{Name='missing end';Change={param($x)$x.PSObject.Properties.Remove('End')}},
 @{Name='negative end';Change={param($x)$x.End=-1}},
 @{Name='oversized end';Change={param($x)$x.End=2147483648}},
 @{Name='future time';Change={param($x)$x.StartedUtc=$script:clock.AddMinutes(1).ToString('o')}},
 @{Name='missing time';Change={param($x)$x.PSObject.Properties.Remove('StartedUtc')}}
)
foreach($case in $invalidPending){
 $bad=CopyState $pending;& $case.Change $bad;$repair=Asset-PublishPlan $p $cache $target 500 $script:clock.AddSeconds(20) $bad
 $tail=@((Plans $repair 'repeatCell')|Where-Object {$_.repeatCell.fields -ceq 'userEnteredValue'})
 Check ($repair.FullRefresh -and $tail.Count -eq 1 -and $tail[0].repeatCell.range.startRowIndex -eq $p.End -and $tail[0].repeatCell.range.endRowIndex -eq 500) ('invalid pending conservatively repairs owned grid: '+$case.Name)
}
$foreign=CopyState $pending;$foreign.Target=Ops-Key 'another-account';$foreign.End=60055
$ignored=Asset-PublishPlan $p $cache $target 500 $script:clock.AddSeconds(20) $foreign
Check ($ignored.Requests.Count -eq 0) 'valid other-target pending does not reuse its extent or force current-target writes'
$unreadable=Asset-PublishPlan $p $cache $target 500 $script:clock.AddSeconds(20) $null @() $true
CheckLayout $unreadable $p 500 'corrupted state repair'
$tail=@((Plans $unreadable 'repeatCell')|Where-Object {$_.repeatCell.fields -ceq 'userEnteredValue'})
Check ($unreadable.FullRefresh -and $tail[0].repeatCell.range.startRowIndex -eq $p.End -and $tail[0].repeatCell.range.endRowIndex -eq 500) 'undecodable existing marker repairs tail while preserving header rows'
# Exercise actual publisher with isolated protected-state and transport adapters.
$work=Join-Path ([IO.Path]::GetTempPath()) ('AvataAssetOpt-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($work)
$script:store=@{};$script:mode='OK';$script:lastRequests=@();$script:cacheWrites=0;$script:gets=0;$script:rules=$rules;$script:remoteRows=500
function Asset-ProtectedRead([string]$path,[string]$purpose){try{if($script:store.ContainsKey($path)){return ($script:store[$path]|ConvertFrom-Json)}}catch{};return $null}
function Asset-ProtectedWrite([string]$path,[string]$purpose,$value){$script:store[$path]=$value|ConvertTo-Json -Depth 30 -Compress;[IO.File]::WriteAllText($path,'synthetic');if($purpose -ceq 'AT-ASSET-PRESENTATION-1'){$script:cacheWrites++}}
function Invoke-RestMethod {
 param($Method,$Uri,$Headers,$ContentType,$Body,$TimeoutSec,$MaximumRedirection,$ErrorAction)
 if($Method -ceq 'Get'){$script:gets++;return [pscustomobject]@{sheets=@([pscustomobject]@{properties=[pscustomobject]@{sheetId=1830155726;gridProperties=[pscustomobject]@{rowCount=$script:remoteRows}};conditionalFormats=$script:rules})}}
 $script:posts++;$script:lastRequests=([Text.Encoding]::UTF8.GetString($Body)|ConvertFrom-Json).requests
 if($script:mode -ceq 'THROW'){throw 'SIMULATED_RESPONSE_LOSS'}
 $replies=@(foreach($request in $script:lastRequests){[pscustomobject]@{}})
 if($script:mode -ceq 'SHORT'){$replies=@()}
 $id=if($script:mode -ceq 'OTHER'){'other-sheet'}else{$script:At58SheetId}
 return [pscustomobject]@{spreadsheetId=$id;replies=$replies}
}
try{
 $send=Asset-Publish @{} 'https://synthetic.invalid/spreadsheets/synthetic-sheet' $p $scope 500 $work
 Check ($script:posts -eq 1 -and $script:cacheWrites -eq 1 -and !$send.Cached) 'confirmed write commits presentation cache once'
 Check (!(Test-Path (Join-Path $work 'assets-presentation-pending.dpapi'))) 'confirmed publication clears pending marker'
 $script:store.Remove((Join-Path $work 'assets-presentation-pending.dpapi'))
 $script:clock=$script:clock.AddSeconds(20)
 $send=Asset-Publish @{} 'https://synthetic.invalid/spreadsheets/synthetic-sheet' $p $scope 500 $work
 Check ($script:posts -eq 1 -and $send.Cached -and $script:cacheWrites -eq 1) 'unchanged report skips HTTP and cache mutation'
 $cacheBefore=$script:store[(Join-Path $work 'assets-presentation.dpapi')]
 foreach($mode in @('THROW','SHORT','OTHER')){
  $script:mode=$mode;$failed=$false
  try{$null=Asset-Publish @{} 'https://synthetic.invalid/spreadsheets/synthetic-sheet' $big $scope 750 $work}catch{$failed=$true}
  Check ($failed -and $script:store[(Join-Path $work 'assets-presentation.dpapi')] -ceq $cacheBefore) ('failed or unconfirmed publication never commits success cache: '+$mode)
 }
 Check ((Test-Path (Join-Path $work 'assets-presentation-pending.dpapi')) -and ((Asset-ProtectedRead (Join-Path $work 'assets-presentation-pending.dpapi') '').End -eq $big.End)) 'response loss persists largest ambiguous end for recovery'
 $script:mode='OK';$null=Asset-Publish @{} 'https://synthetic.invalid/spreadsheets/synthetic-sheet' $p $scope 750 $work
 $clear=@($script:lastRequests|Where-Object {($_.PSObject.Properties['repeatCell']) -and $_.repeatCell.fields -ceq 'userEnteredValue'})
 Check ($clear.Count -eq 1 -and $clear[0].repeatCell.range.endRowIndex -eq $big.End) 'publisher recovers ambiguous table with actual stale-tail clear'
 Check ($script:cacheWrites -eq 2) 'only two confirmed writes committed across failures'
 $script:store.Remove((Join-Path $work 'assets-presentation-pending.dpapi'))
 $null=Asset-Publish @{} 'https://synthetic.invalid/spreadsheets/synthetic-sheet' $big $scope 500 $work
 Check ($script:gets -eq 1 -and @($script:lastRequests|Where-Object {$_.PSObject.Properties['updateConditionalFormatRule']}).Count -eq 1) 'actual growth publisher reads current rules once and writes extended coverage'
 # Existing undecodable files must be distinguished from absent state.
 $cachePath=Join-Path $work 'assets-presentation.dpapi';$pendingPath=Join-Path $work 'assets-presentation-pending.dpapi'
 $script:store[$cachePath]='{truncated';$script:store.Remove($pendingPath);$beforeGets=$script:gets
 $null=Asset-Publish @{} 'https://synthetic.invalid/spreadsheets/synthetic-sheet' $p $scope 500 $work
 $tail=@($script:lastRequests|Where-Object {($_.PSObject.Properties['repeatCell']) -and $_.repeatCell.fields -ceq 'userEnteredValue'})
 Check ($script:gets -eq $beforeGets+1 -and $tail[0].repeatCell.range.endRowIndex -eq 500) 'unreadable published file fetches current capacity and repairs the allocated tail'
 $script:store[$pendingPath]='{truncated';[IO.File]::WriteAllText($pendingPath,'synthetic');$script:remoteRows=750;$beforeGets=$script:gets
 $cacheBefore=$script:store[$cachePath];$script:mode='THROW';$failed=$false
 try{$null=Asset-Publish @{} 'https://synthetic.invalid/spreadsheets/synthetic-sheet' $p $scope 500 $work}catch{$failed=$true}
 $tail=@($script:lastRequests|Where-Object {($_.PSObject.Properties['repeatCell']) -and $_.repeatCell.fields -ceq 'userEnteredValue'})
 Check ($script:gets -eq $beforeGets+1 -and $tail[0].repeatCell.range.endRowIndex -eq 750 -and @($script:lastRequests|Where-Object {$_.PSObject.Properties['appendDimension']}).Count -eq 0) 'unreadable pending recovers remote growth even when supplied metadata is stale'
 Check ($failed -and $script:store[$cachePath] -ceq $cacheBefore -and (Asset-ProtectedRead $pendingPath '').End -eq 750) 'failed corruption repair preserves success cache and records the whole uncertain extent'
 $script:mode='OK';$send=Asset-Publish @{} 'https://synthetic.invalid/spreadsheets/synthetic-sheet' $p $scope 500 $work
 Check ($send.FullRefresh -and $send.GridRows -eq 750 -and !(Test-Path -LiteralPath $pendingPath)) 'corruption repair completes automatically and removes marker only after confirmed success'
 $script:store.Remove($pendingPath);$beforePosts=$script:posts
 $send=Asset-Publish @{} 'https://synthetic.invalid/spreadsheets/synthetic-sheet' $p $scope 750 $work
 Check ($send.Cached -and $script:posts -eq $beforePosts) 'confirmed corruption repair returns to unchanged zero-write behavior'
 $script:remoteRows=500
 # Run actual pump with synthetic history to preserve post-close provenance.
 function At58-Context {return [pscustomobject]@{Scope=$scope;Token='';TokenUntil=$script:clock;Credential=$null;Mac=''}}
 function Asset-Collect {return [pscustomobject]@{Schema='AT-ASSETS-1';Scope=$scope;From='20261105';To='20261105';Phase='COMPLETE';CostRows=@();Transactions=@();StartedUtc='2026-11-05T06:31:00Z';CompletedUtc='2026-11-05T06:32:00Z'}}
 $script:store=@{};$script:mode='OK';$script:clock=$script:clock.AddSeconds(40)
 $meta=[pscustomobject]@{sheets=@([pscustomobject]@{properties=[pscustomobject]@{title='자산상세내역';sheetId=1830155726;gridProperties=[pscustomobject]@{rowCount=500;columnCount=11}}})}
 $input=[pscustomobject]@{Ledger=(LedgerRows)}
 Asset-Pump @{} 'https://synthetic.invalid/spreadsheets/synthetic-sheet' $meta (Snapshot) $input 'synthetic-data' $work
 $statusPath=Join-Path $work 'assets-status.json';$fresh=Ops-ReadJson $statusPath
 Check ($fresh.Code -ceq 'OK' -and $fresh.Phase -ceq 'COMPLETE' -and (Ops-Utc $fresh.HistoryStartedUtc) -eq ([datetimeoffset]'2026-11-05T06:31:00Z').UtcDateTime -and (Ops-Utc $fresh.SnapshotUtc) -eq $script:clock) 'actual pump retains current snapshot and post-close history provenance'
 $script:store.Remove((Join-Path $work 'assets-presentation-pending.dpapi'));$script:clock=$script:clock.AddSeconds(30)
 Asset-Pump @{} 'https://synthetic.invalid/spreadsheets/synthetic-sheet' $meta (Snapshot) $input 'synthetic-data' $work
 $cached=Ops-ReadJson $statusPath
 Check ($cached.Cached -and $cached.WrittenCells -eq 0 -and (Ops-Utc $cached.PublishedUtc) -eq (Ops-Utc $fresh.PublishedUtc) -and (Ops-Utc $cached.SnapshotUtc) -eq $script:clock) 'unchanged verified report advances observation proof but retains actual publication time'
 $before=[IO.File]::ReadAllText($statusPath);$script:mode='THROW';$script:clock=$script:clock.AddSeconds(30);$changed=Snapshot;$changed.Cash.Withdrawable=1;$failed=$false
 try{Asset-Pump @{} 'https://synthetic.invalid/spreadsheets/synthetic-sheet' $meta $changed $input 'synthetic-data' $work}catch{$failed=$true}
 Check ($failed -and [IO.File]::ReadAllText($statusPath) -ceq $before) 'write failure never refreshes successful report or post-close proof'
 Check ($script:wire -eq 0) 'asset optimization never submits a broker order'
}finally{Remove-Item -LiteralPath $work -Recurse -Force}
Write-Output ('ASSET OPTIMIZATION CHECKS PASSED: '+$script:checks)
