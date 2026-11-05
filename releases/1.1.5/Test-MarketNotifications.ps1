#requires -Version 5.1
param([string]$Root=$PSScriptRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
. (Join-Path $Root 'bundle/At58.Ops.ps1')
. (Join-Path $Root 'bundle/At58.Telegram.ps1')
. (Join-Path $Root 'bundle/payload/At58.Core.ps1')
$script:checks=0;$script:network=0
function Check($ok,[string]$name){if(!$ok){throw ('FAILED: '+$name)};$script:checks++;Write-Output ('PASS '+$name)}
function Invoke-RestMethod {$script:network++;throw 'NETWORK_FORBIDDEN'}
function At58T-Wire {$script:network++;throw 'ORDER_FORBIDDEN'}
$run='synthetic-run';$script:clock=([datetimeoffset]'2026-11-05T00:00:10Z').UtcDateTime
function Ops-Now {return $script:clock}
function Status {
 $stamp=$script:clock.ToString('o')
 return [pscustomobject]@{RunId=$run;Utc=$stamp;Code='OK';Live=[pscustomobject]@{RunId=$run;Utc=$stamp;Mode='LIVE_CONTROL';State='ARMED';Code='LIVE_WAIT';TestOnly=$false;Reconciled=$true;ExecutionEnabled=$true;OrdersSent=0;OpenOrders=0;UncertainOrders=0;MarketSession=[pscustomobject]@{Day='20261105';OpenUtc='2026-11-05T00:00:00Z';CloseUtc='2026-11-05T06:30:00Z';SnapshotUtc=$stamp}}}
}
function State {return [pscustomobject]@{Outbox=@();TelegramNext='2000-01-01T00:00:00Z'}}
function Reports {
 $stamp=$script:clock.ToString('o')
 return @([pscustomobject]@{Code='OK';Day='20261105';Utc=$stamp;SnapshotUtc=$stamp;JournalReady=$true},[pscustomobject]@{Code='OK';Day='20261105';Utc=$stamp;SnapshotUtc=$stamp;Phase='COMPLETE';HistoryStartedUtc='2026-11-05T06:30:05Z';HistoryCompletedUtc=$stamp})
}
$state=State;$s=Status;$n=Ops-MarketNotice $state $s $run $script:clock
Check ($n.Event -ceq 'MARKET_OPEN') 'confirmed live activation during broker session creates attendance'
$text=Tg-EventText $n.Event
Check ($text -ceq ('본장에 출근했습니다. 실주문 시작합니다'+[Environment]::NewLine+'메인PC / 2026-11-05 09:00:10 (KST)')) 'opening text has exact requested wording, main PC and Korean time'
Check (Ops-QueueMarketNotice $state $n $text $script:clock) 'first notice is enqueued'
Check (!(Ops-QueueMarketNotice $state $n $text $script:clock) -and $state.Outbox.Count -eq 1) 'same-day queue is idempotent'
Check (!(Ops-MarketNotice $state $s $run $script:clock)) 'repeated read does not create attendance'
# Persist marker and message together using the actual manager state writer.
$dir=Join-Path ([IO.Path]::GetTempPath()) ('AvataMarket-'+[guid]::NewGuid().ToString('N'))
try{
 $path=Join-Path $dir 'state.json';Ops-WriteJson $path $state;$restored=Ops-ReadJson $path
 Check ($restored.Outbox.Count -eq 1 -and !(Ops-MarketNotice $restored $s $run $script:clock)) 'manager restart keeps pending message and daily deduplication'
}finally{if(Test-Path $dir){Remove-Item $dir -Recurse -Force}}
foreach($case in @('DISARMED','STOPPING','PAPER','TEST','UNRECONCILED','DISABLED','UNKNOWN','OLD_RUN','OLD_LIVE_RUN','STALE_STATUS','STALE_LIVE','STALE_SNAPSHOT','FUTURE','READ_FAILURE','HOLIDAY','NO_SESSION','BAD_TIME','PREOPEN')){
 $s=Status;$st=State
 switch($case){
 'DISARMED' {$s.Live.State='DISARMED'}
 'STOPPING' {$s.Live.State='STOPPING'}
 'PAPER' {$s.Live.Mode='PAPER'}
 'TEST' {$s.Live.TestOnly=$true}
 'UNRECONCILED' {$s.Live.Reconciled=$false}
 'DISABLED' {$s.Live.ExecutionEnabled=$false}
 'UNKNOWN' {$s.Live.UncertainOrders=1}
 'OLD_RUN' {$s.RunId='old'}
 'OLD_LIVE_RUN' {$s.Live.RunId='old'}
 'STALE_STATUS' {$s.Utc=$script:clock.AddMinutes(-2).ToString('o')}
 'STALE_LIVE' {$s.Live.Utc=$script:clock.AddMinutes(-2).ToString('o')}
 'STALE_SNAPSHOT' {$s.Live.MarketSession.SnapshotUtc=$script:clock.AddMinutes(-2).ToString('o')}
 'FUTURE' {$s.Live.Utc=$script:clock.AddMinutes(1).ToString('o')}
 'READ_FAILURE' {$s.Code='READ_ERROR'}
 'HOLIDAY' {$s.Live.MarketSession.Day='20261104'}
 'NO_SESSION' {$s.Live.MarketSession=$null}
 'BAD_TIME' {$s.Live.MarketSession.CloseUtc='broken'}
 'PREOPEN' {$s.Live.MarketSession.OpenUtc='2026-11-05T01:00:00Z'}
 }
 Check (!(Ops-MarketNotice $st $s $run $script:clock)) ('no false opening: '+$case)
}
# Shifted exchange hours are authoritative, including days with delayed opens.
$script:clock=([datetimeoffset]'2026-11-05T01:00:05Z').UtcDateTime;$s=Status;$s.Live.MarketSession.OpenUtc='2026-11-05T01:00:00Z';$s.Live.MarketSession.CloseUtc='2026-11-05T07:30:00Z'
Check ((Ops-MarketNotice (State) $s $run $script:clock).Event -ceq 'MARKET_OPEN') 'delayed exchange opening works without wall-clock constants'
$snap=[pscustomobject]@{CompletedUtc=$script:clock.ToString('o');Session=[pscustomobject]@{BusinessDay='20261105';Open=[datetime]'2026-11-05T10:00:00';Close=[datetime]'2026-11-05T16:30:00'}}
$session=At58X-MarketSession $snap
Check ($session.OpenUtc -ceq '2026-11-05T01:00:00.0000000Z' -and $session.CloseUtc -ceq '2026-11-05T07:30:00.0000000Z') 'broker Korean schedule is exported as unambiguous UTC'
$snap.Session.BusinessDay='20261104';Check (!(At58X-MarketSession $snap)) 'mixed-day calendar is not exported'
$script:clock=([datetimeoffset]'2026-11-05T06:31:00Z').UtcDateTime;$s=Status;$s.Live.ExecutionEnabled=$false;$s.Live.Code='LIVE_MARKET_WAIT';$reports=Reports
Check (!(Ops-MarketNotice $state $s $run $script:clock)) 'close waits for settlement reports'
$n=Ops-MarketNotice $state $s $run $script:clock $reports[0] $reports[1]
Check ($n.Event -ceq 'MARKET_CLOSE') 'post-close reconciled account plus completed reports creates checkout'
Check ((Tg-EventText $n.Event) -ceq ('장 마감으로 일일정산 후 퇴근합니다.'+[Environment]::NewLine+'메인PC / 2026-11-05 15:31:00 (KST)')) 'closing wording and main-PC timestamp are exact'
foreach($case in @('OPEN_ORDER','UNKNOWN_ORDER','UNRECONCILED','STILL_LIVE','REVIEW','BEFORE_CLOSE_SNAPSHOT','NO_ACTIVITY','JOURNAL_PENDING','SHEET_ERROR','ASSET_ERROR','HISTORY_PARTIAL','CACHED_INTRADAY','FUTURE_HISTORY','OTHER_DAY','STALE_REPORT','OLD_ASSET_SNAPSHOT')){
 $s=Status;$s.Live.ExecutionEnabled=$false;$s.Live.Code='LIVE_MARKET_WAIT';$rs=Reports;$st=$state
 switch($case){
 'OPEN_ORDER' {$s.Live.OpenOrders=1}
 'UNKNOWN_ORDER' {$s.Live.UncertainOrders=1}
 'UNRECONCILED' {$s.Live.Reconciled=$false}
 'STILL_LIVE' {$s.Live.ExecutionEnabled=$true}
 'REVIEW' {$s.Live.State='REVIEW'}
 'BEFORE_CLOSE_SNAPSHOT' {$s.Live.MarketSession.SnapshotUtc='2026-11-05T06:29:59Z'}
 'NO_ACTIVITY' {$st=State}
 'JOURNAL_PENDING' {$rs[0].JournalReady=$false}
 'SHEET_ERROR' {$rs[0].Code='SHEET_ERROR'}
 'ASSET_ERROR' {$rs[1].Code='ASSET_REPORT_RETRY'}
 'HISTORY_PARTIAL' {$rs[1].Phase='TRANSACTIONS'}
 'CACHED_INTRADAY' {$rs[1].HistoryStartedUtc='2026-11-05T06:29:59Z'}
 'FUTURE_HISTORY' {$rs[1].HistoryCompletedUtc='2026-11-05T06:32:00Z'}
 'OTHER_DAY' {$rs[0].Day='20261104'}
 'STALE_REPORT' {$rs[1].Utc='2026-11-05T06:25:00Z'}
 'OLD_ASSET_SNAPSHOT' {$rs[1].SnapshotUtc='2026-11-05T06:29:59Z'}
 }
 Check (!(Ops-MarketNotice $st $s $run $script:clock $rs[0] $rs[1])) ('no premature checkout: '+$case)
}
$s=Status;$s.Live.ExecutionEnabled=$false;$s.Live.Code='LIVE_MARKET_WAIT';$s.Live.OrdersSent=3
Check ((Ops-MarketNotice (State) $s $run $script:clock $reports[0] $reports[1]).Event -ceq 'MARKET_CLOSE') 'upgrade after close can recognize today real order activity'
Check (Ops-QueueMarketNotice $state $n (Tg-EventText $n.Event) $script:clock) 'closing queue persists its own daily marker'
Check (!(Ops-MarketNotice $state $s $run $script:clock $reports[0] $reports[1])) 'repeated post-close reports do not repeat checkout'
Check ((Ops-PruneMarketOutbox $state $script:clock) -and $state.Outbox.Count -eq 1 -and $state.Outbox[0].Code -ceq 'MARKET_CLOSE') 'undelivered attendance expires at close'
$state.Outbox+=@([pscustomobject]@{Code='FAULT';Text='synthetic';Utc=$script:clock.ToString('o')})
$script:clock=([datetimeoffset]'2026-11-05T15:00:00Z').UtcDateTime
Check ((Ops-PruneMarketOutbox $state $script:clock) -and $state.Outbox.Count -eq 1 -and $state.Outbox[0].Code -ceq 'FAULT') 'next-day pruning discards checkout without dropping fault notices'
$script:clock=([datetimeoffset]'2026-11-06T00:00:10Z').UtcDateTime;$s=Status;$s.Live.MarketSession.Day='20261106';$s.Live.MarketSession.OpenUtc='2026-11-06T00:00:00Z';$s.Live.MarketSession.CloseUtc='2026-11-06T06:30:00Z'
Check ((Ops-MarketNotice $state $s $run $script:clock).Event -ceq 'MARKET_OPEN') 'next business day gets its own attendance'
Check ($script:network -eq 0) 'all lifecycle tests send no Telegram messages or broker orders'
Write-Output ('ALL '+$script:checks+' MARKET NOTIFICATION CHECKS PASSED')
