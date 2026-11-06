#requires -Version 5.1
param([string]$Root=$PSScriptRoot,[switch]$ExpectBug)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
. (Join-Path $Root 'bundle/At58.Ops.ps1')
. (Join-Path $Root 'bundle/At58.Sheets.ps1')
. (Join-Path $Root 'bundle/payload/At58.Core.ps1')
. (Join-Path $Root 'tests/CashFixture.ps1')
$script:checks=0;$script:network=0;$script:posts=0;$script:cancels=0;$script:lastCancel=$null;$script:fixtures=@{}
function Check($ok,[string]$name){if(!$ok){throw ('FAILED: '+$name)};$script:checks++;Write-Output ('PASS '+$name)}
function Reject($body,[string]$code,[string]$name){$found='';try{& $body|Out-Null}catch{$found=(At58-Error $_).Code};Check ($found -ceq $code) ($name+' ['+$found+']')}
function Invoke-RestMethod {$script:network++;throw 'NETWORK_FORBIDDEN'}
function At58T-Wire {$script:network++;throw 'ORDER_FORBIDDEN'}
# Linux validation substitutes only protection of synthetic test files. Windows
# executes the same fixture with real CurrentUser DPAPI. No installed data is read.
$portable=($env:OS -cne 'Windows_NT')
if($portable){
 function At58-Protect([string]$plain,[string]$purpose=''){return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($purpose+"`n"+$plain))}
 function At58-Unprotect([string]$cipher,[string]$purpose=''){$plain=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($cipher));$prefix=$purpose+"`n";if(!$plain.StartsWith($prefix)){throw 'TEST_PURPOSE'};return $plain.Substring($prefix.Length)}
}
$script:baseContext=${function:At58-Context}
function At58-Context([string]$root,[string]$symbol='0210A0',$credential=$null){$ctx=& $script:baseContext $root $symbol $credential;$ctx.LiveTestMode=$true;return $ctx}
$work=Join-Path ([IO.Path]::GetTempPath()) ('AvataRejectTest-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
function Save-Input($f){$f.Raw.Day=$f.Snapshot.Day;$f.Raw.Utc=$script:cashClock.ToString('o');At58-Atomic (Join-Path $f.Owner.Root 'strategy-input.dpapi') (At58-Protect ($f.Raw|ConvertTo-Json -Depth 30 -Compress) 'AT58-STRATEGY-INPUT-1')}
function Test-History($node){return [pscustomobject]@{Id=$node.BrokerId;Day=$node.Day;Symbol=$node.Intent.Symbol;Side=$(if($node.Intent.Side -ceq '매수'){'2'}else{'1'});Qty=$node.Intent.Qty;Price=$node.Intent.Price;Filled=$node.Filled;Remaining=$node.Remaining;Kind=$(if($node.Action -ceq 'CANCEL'){'3'}else{'1'});Original=$node.ParentId;Status=$(if($node.State -ceq 'REJECTED'){'3'}else{'2'});Reject=$(if($node.State -ceq 'REJECTED'){'1234'}else{'0'})}}
function Add-Node($f,$intent,[string]$state='REJECTED'){
 $ctx=At58X-Context $f.Owner;$book=At58T-Load $ctx;$key=At58-Hash ('synthetic-'+$f.Owner.Root+'|'+$book.Orders.Count)
 $node=[pscustomobject]@{Key=$key;RootKey=$key;ParentKey='';ParentId='';Day=$f.Snapshot.Day;Action='NEW';Intent=(At58S-Clone $intent);BrokerId=([string](1000+$book.Orders.Count));State=$state;CreatedUtc=$script:cashClock.ToString('o');HistoryUtc='';Filled=0D;Amount=0D;Remaining=$(if($state -ceq 'REJECTED'){0D}else{[decimal]$intent.Qty});Response='0001';Issue='';FeeStatus='UNCONFIRMED'}
 $book.Orders+=,$node;$book.Revision++;At58T-Save $ctx $book;$f.Rows+=,(Test-History $node);return $node
}
function New-Fixture([string]$name){
 $f=Cash-Fixture (Join-Path $work $name);$f.Rows=@();$f.Last=$null
 $script:cashClock=([datetimeoffset]'2026-11-06T14:00:00Z').UtcDateTime
 $f.Snapshot.Day='20261106';$f.Snapshot.Quote.BasisDay='20261106';$f.Snapshot.Quote.Price=3000D;$f.Snapshot.Session.Close=[datetime]'2026-11-06T15:30:00'
 $f.Snapshot|Add-Member HistoryDays @('20261106') -Force
 $view=At58S-Clone $f.Book;$view.Mode='LIVE_TEST';$p=At58X-Replay $f.Source $view $f.Snapshot.Day
 $intent=(At58L-Candidate $f.Source $p $f.Snapshot '하락' $f.Book).Intent
 if(!$intent){throw 'TEST_NO_INTENT'}
 $f.Rejected=Add-Node $f $intent;$script:fixtures[$f.Owner.Root]=$f
 Save-Input $f;return $f
}
function Poll($f,[int]$advance=2){
 $script:cashClock=$script:cashClock.AddSeconds($advance);$s=$f.Snapshot;$s.CompletedUtc=$script:cashClock.ToString('o');$s.Quote.ReceivedUtc=$s.CompletedUtc
 $s.OrdersToday=@($f.Rows|Where-Object Day -ceq $s.Day);$s.PriorOrders=@($f.Rows|Where-Object Day -cne $s.Day)
 $s.HistoryDays=@($s.Day)+@($f.Rows|Select-Object -ExpandProperty Day -Unique)
 if(At58-Value $f.Owner 'LiveMailbox'){$f.Owner.LiveMailbox.UiUtc=$s.CompletedUtc}
 $f.Last=At58X-Step $f.Owner $f.Source $s @() $null '하락' '허용';return $f.Last
}
function Start-Manual($f,[string]$action='ARM'){
 Save-Input $f;$box=At58X-Mailbox $f.Owner.RunId;$box.Mode='LIVE';$box.SourceHash=$f.Source.Hash;$box.Last=$f.Last;$box.UiUtc=$script:cashClock.ToString('o')
 At58X-Queue $box $action $f.Source.Hash (At58D-Limits) $script:cashClock
 At58X-Commands $f.Owner $box;$f.Box=$box;return $box
}
# The state machine chooses whether to dispatch. The test boundary records that
# choice as an acknowledged synthetic order; no broker or financial action exists.
function At58X-Dispatch($owner,$state,$snapshot,$intent,[string]$action,[string]$decision,[string]$parent=''){
 At58X-ManagedGate $owner $action
 $f=$script:fixtures[$owner.Root]
 if($action -ceq 'NEW'){$script:posts++;return (Add-Node $f $intent 'ACKNOWLEDGED')}
 if($action -cne 'CANCEL'){throw 'UNEXPECTED_TEST_ACTION'}
 $ctx=At58X-Context $owner;$book=At58T-Load $ctx;$parents=@($book.Orders|Where-Object Key -ceq $parent)
 if($parents.Count -ne 1 -or $parents[0].State -cne 'OPEN' -or $intent.Qty -ne $parents[0].Remaining){throw 'TEST_CANCEL_PARENT'}
 $original=$parents[0];$key=At58-Hash ('synthetic-cancel-'+$owner.Root+'|'+$book.Orders.Count)
 $node=[pscustomobject]@{Key=$key;RootKey=$original.RootKey;ParentKey=$original.Key;ParentId=$original.BrokerId;Day=$snapshot.Day;Action='CANCEL';Intent=(At58S-Clone $intent);BrokerId=([string](1000+$book.Orders.Count));State='ACKNOWLEDGED';CreatedUtc=$script:cashClock.ToString('o');HistoryUtc='';Filled=0D;Amount=0D;Remaining=0D;Response='0001';Issue='';FeeStatus='UNCONFIRMED'}
 $book.Orders+=,$node;$book.Revision++;At58T-Save $ctx $book
 # The subsequent real reconciliation must verify BOTH parent and cancellation
 # rows before clearing STOPPING. This boundary supplies only synthetic evidence.
 foreach($row in $f.Rows){if($row.Day -ceq $original.Day -and $row.Id -ceq $original.BrokerId){$row.Remaining=0D}}
 $f.Rows+=,(Test-History $node);$script:cancels++;$script:lastCancel=$node;return $node
}
try{
 $f=New-Fixture 'manual';$null=Poll $f;$before=Poll $f
 Check ($before.Reconciled -and $before.Code -ceq 'LIVE_ORDER_REJECTED' -and $before.State -ceq 'DISARMED') 'confirmed rejection is visible before any new operator start'
 $ctx=At58X-Context $f.Owner;$beforeOrders=(At58T-Load $ctx).Orders|ConvertTo-Json -Depth 20 -Compress
 $box=Start-Manual $f
 Check (!$box.CommandError -and $f.Owner.LiveSession.State -ceq 'ARMED') 'actual manual ARM command initially grants the same-process session'
 $first=Poll $f
 if($ExpectBug){
  Check ($first.State -ceq 'DISARMED' -and $first.Code -ceq 'LIVE_ORDER_REJECTED' -and !$first.Plan.Intent) 'baseline reproduces immediate rejection latch after explicit restart'
  Check ($script:posts -eq 0 -and $script:network -eq 0) 'baseline reproduction issued no network or orders'
  Write-Output ('BASELINE BUG REPRODUCED: '+$script:checks+' checks.');return
 }
 Check ($first.State -ceq 'ARMED' -and $first.Code -ceq 'LIVE_MARKET_WAIT' -and $first.Confirmations -eq 1 -and !$first.Reconciled -and $script:posts -eq 0) 'manual restart waits off-hours and requires first fresh account proof'
 $second=Poll $f
 Check ($second.State -ceq 'ARMED' -and $second.Code -ceq 'LIVE_MARKET_WAIT' -and $second.Reconciled -and $second.Plan.Intent -and $script:posts -eq 0) 'second fresh off-hours read keeps approval and restores candidate calculation without sending'
 Check ((@($f.Owner.LiveSession.AcknowledgedRejections).Count -eq 1) -and ((At58T-Load $ctx).Orders|ConvertTo-Json -Depth 20 -Compress) -ceq $beforeOrders) 'acknowledgment is run-local and leaves rejected order history intact'
 $script:cashClock=([datetimeoffset]'2026-11-08T14:59:50Z').UtcDateTime;$f.Snapshot.Day='20261108';$f.Snapshot.PriorDay='20261106';$f.Snapshot.Session.Close=[datetime]'2026-11-08T15:30:00'
 $sunday=Poll $f
 Check ($sunday.State -ceq 'ARMED' -and $sunday.Code -ceq 'LIVE_MARKET_WAIT' -and $sunday.Confirmations -eq 1 -and $script:posts -eq 0) 'Sunday date rollover preserves approval but rebuilds account evidence'
 $script:cashClock=([datetimeoffset]'2026-11-09T00:00:00Z').UtcDateTime;$f.Snapshot.Day='20261109';$f.Snapshot.Session.Live=$true;$f.Snapshot.Session.Close=[datetime]'2026-11-09T15:30:00';$f.Snapshot.Quote.Mode='LIVE_REST'
 $monday1=Poll $f
 Check ($monday1.State -ceq 'ARMED' -and $monday1.Confirmations -eq 1 -and $script:posts -eq 0) 'Monday opening cannot submit on the first new-day account proof'
 $monday2=Poll $f
 Check ($monday2.Code -ceq 'LIVE_ORDER_SENT' -and $script:posts -eq 1 -and $monday2.Orders.Count -eq 2) 'Monday second fresh proof permits one new synthetic intent'
 Check ($monday2.Orders[1].Key -cne $f.Rejected.Key -and $monday2.Orders[1].Intent.GoalId -cne $f.Rejected.Intent.GoalId) 'new decision retains the old rejected record and uses distinct order and goal identities'
 $after=Poll $f
 Check ($script:posts -eq 1 -and $after.Orders.Count -eq 2 -and $after.State -ceq 'ARMED') 'acknowledged order blocks duplicate submission on the next poll'
 Check ($after.Orders[1].State -ceq 'OPEN') 'the accepted new order is independently reconciled as open'
 At58X-Queue $f.Box 'STOP' '' $null $script:cashClock;At58X-Commands $f.Owner $f.Box;$cancel=Poll $f
 Check ($cancel.State -ceq 'STOPPING' -and $cancel.Code -ceq 'LIVE_CANCEL_SENT' -and $script:cancels -eq 1 -and $script:posts -eq 1 -and $script:lastCancel.ParentKey -ceq $after.Orders[1].Key -and $script:lastCancel.Intent.Qty -eq $after.Orders[1].Remaining) 'STOP dispatches one cancellation for the open order despite acknowledged historical rejection'
 $cancelled=Poll $f
 Check ($cancelled.State -ceq 'DISARMED' -and $cancelled.Code -ceq 'LIVE_STOPPED' -and $cancelled.Orders[1].State -ceq 'CANCELLED' -and $cancelled.Orders[2].State -ceq 'CANCELLED') 'fresh parent and child history confirms cancellation before stop completes'
 $idle=Poll $f
 Check ($idle.State -ceq 'DISARMED' -and $script:cancels -eq 1 -and $script:posts -eq 1) 'completed stop cannot repeat cancellation or submit another new order'

 $g=New-Fixture 'new-rejection';$null=Poll $g;$null=Poll $g;$null=Start-Manual $g;$null=Poll $g;$ready=Poll $g
 $new=Add-Node $g $ready.Plan.Intent;$blocked=Poll $g
 Check ($blocked.State -ceq 'DISARMED' -and $blocked.Code -ceq 'LIVE_ORDER_REJECTED' -and !$blocked.Plan.Intent -and $script:posts -eq 1) 'new rejection is not covered by an earlier acknowledgment and stops execution'
 $still=Poll $g
 Check ($still.State -ceq 'DISARMED' -and $script:posts -eq 1) 'new rejection does not silently reauthorize or repeatedly retry'

 $h=New-Fixture 'stop';$null=Poll $h;$null=Poll $h;$null=Start-Manual $h;$null=Poll $h;$null=Poll $h
 At58X-Queue $h.Box 'STOP' '' $null $script:cashClock;At58X-Commands $h.Owner $h.Box;$stopped=Poll $h
 Check ($stopped.State -ceq 'DISARMED' -and $stopped.Code -ceq 'LIVE_STOPPED' -and $script:posts -eq 1) 'operator STOP still clears a resumed waiting session'

 foreach($action in @('ARM_AUTO','ARM_TELEGRAM')){
  $a=New-Fixture $action;$null=Poll $a;$null=Poll $a
  # Origin routing is tested after a successful consent guard. Guards themselves
  # have independent existing test suites; no external Telegram call is made.
  function At58AS-Guard {}
  function At58TG-Guard {}
  $b=Start-Manual $a $action;$r=Poll $a
  Check ($r.State -ceq 'DISARMED' -and $r.Code -ceq 'LIVE_ORDER_REJECTED' -and @($a.Owner.LiveSession.AcknowledgedRejections).Count -eq 0) ($action+' cannot acknowledge rejected history through manual-only consent')
 }
 foreach($badState in @('UNKNOWN','SUBMITTING','WARNING_REVIEW','REVIEW')){
  $u=New-Fixture ('unsafe-'+$badState);$book=At58T-Load (At58X-Context $u.Owner);$book.Orders[0].State=$badState;At58T-Save (At58X-Context $u.Owner) $book
  $session=At58X-NewSession $u.Owner $u.Source.Hash (At58D-Limits)
  Reject {At58X-Authorize $u.Owner $session $u.Source.Hash $true} 'LIVE_ORDER_REVIEW' ($badState+' remains blocked by the actual authorization gate')
 }
 $p=New-Fixture 'proof';$null=Poll $p;$null=Poll $p;$null=Start-Manual $p
 $book=At58T-Load (At58X-Context $p.Owner);$view=At58S-Clone $book;$view.Mode='LIVE_TEST';$portfolio=At58X-Replay $p.Source $view $p.Snapshot.Day
 foreach($case in @('partial','missing-id','remaining','issue','changed-intent','review')){
  $v=At58S-Clone $portfolio;$session=At58S-Clone $p.Owner.LiveSession
  switch($case){
   'partial'{$v.Goals[0].Filled=1D;$v.Goals[0].Amount=6000D}
   'missing-id'{$v.Goals[0].Nodes[0].BrokerId=''}
   'remaining'{$v.Goals[0].Nodes[0].Remaining=1D}
   'issue'{$v.Goals[0].Nodes[0].Issue='TRADE_REJECT_WITH_FILL'}
   'changed-intent'{$v.Goals[0].Nodes[0].Intent.Price+=5D}
   'review'{$session.State='REVIEW'}
  }
  $terminal=At58X-HandleTerminalReject $v $session
  Check ($terminal -and $v.Code -ceq 'SIM_ORDER_REJECTED' -and $session.State -ceq $(if($case -ceq 'review'){'REVIEW'}else{'DISARMED'})) ($case+' cannot reuse a prior rejection acknowledgment')
 }
 Check ($script:network -eq 0 -and $script:posts -eq 1 -and $script:cancels -eq 1) 'all scenarios used synthetic temporary state, one fake new order and one fake cancellation; zero network calls'
 Write-Output ('REJECT RESUME TESTS COMPLETE: '+$script:checks+' passed; Engine='+$PSVersionTable.PSVersion+'; PortableProtection='+$portable+'.')
}finally{
 $safe=[IO.Path]::GetFullPath($work);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
 if(!$safe.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($safe) -cnotmatch '^AvataRejectTest-[a-f0-9]{32}$'){throw 'TEST_CLEANUP_PATH'}
 if([IO.Directory]::Exists($safe)){Remove-Item -LiteralPath $safe -Recurse -Force}
}
