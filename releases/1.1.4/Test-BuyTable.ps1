param([string]$Root=$PSScriptRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
. (Join-Path $Root 'bundle/At58.Ops.ps1')
. (Join-Path $Root 'bundle/At58.Sheets.ps1')
. (Join-Path $Root 'bundle/payload/At58.Core.ps1')
$script:checks=0;$script:network=0
function Check($ok,[string]$name){if(!$ok){throw ('FAILED: '+$name)};$script:checks++;'PASS '+$name}
function Invoke-RestMethod {$script:network++;throw 'NETWORK_FORBIDDEN'}
function At58T-Wire {$script:network++;throw 'ORDER_FORBIDDEN'}
# Synthetic prices, balances, identities and fill events; no installed state is read.
function Fixture {
 $p=[pscustomobject]@{Principal=10000000D;Reinvest=$false;Tick=5D;BuyGap=.03D;SellGap=.01D;Splits=30;BuyDistance=.1D;BuyWeightMax=2D;BelowSellRatio=.1D;SellRatio=.1D;SellDistance=.1D;SellRatioMax=.8D;BuyFee=.001D;SellFee=.001D;MaxBuys=3;ReserveRatio=.1D;LossStop=.5D;MaxInvest=.9D;NextEntry=10000D;Regimes=[pscustomobject]@{};Neutral=[pscustomobject]@{ReserveRatio=.3D;MaxBuys=2;MinEdge=.01D};Controls=[pscustomobject]@{BuyLossStop=.2D;DownReserve=.3D;DownMaxBuys=1;CrashReserve=.5D}}
 foreach($m in @('상승','하락','급락','보합')){$p.Regimes|Add-Member $m ([pscustomobject]@{Budget=1D;BuyGap=$(if($m -ceq '상승'){.5D}else{1D});SellGap=1D;SellWeight=1D;BuyEnabled=$true})}
 $rows=@(1..10|ForEach-Object {[pscustomobject]@{Day='20260105';Stage=$_;Side='매수';Price=10000D;Qty=10D;Amount=100000D}})
 $src=[pscustomobject]@{Symbol='000000';Scope=('a'*64);Hash=('b'*64);Day='20260106';Policy=$p;Cycle=[pscustomobject]@{Id=1;Basis=10000D;Phase='운영중'};Ledger=[pscustomobject]@{Qty=100D;Average=10000D;Cash=9000000D;Realized=0D;Held=@(1..10);Rows=$rows}}
 $book=[pscustomobject]@{Mode='LIVE';Scope=$src.Scope;Symbol=$src.Symbol;Account=('c'*64);Revision=0;Orders=@();Fills=@();GoalCaps=@()}
 $s=[pscustomobject]@{Day=$src.Day;CompletedUtc='2026-01-06T01:00:00Z';Quote=[pscustomobject]@{Price=6800D;BasisDay=$src.Day};Cash=[pscustomobject]@{Orderable=9000000D}}
 return @{Source=$src;Book=$book;Snapshot=$s}
}
function Portfolio($f){$p=At58X-Replay $f.Source $f.Book $f.Snapshot.Day;$p|Add-Member DailyStages (At58D-Usage $f.Book $f.Snapshot.Day $f.Source @($p.Held));$p.BuyCount=$p.DailyStages.FilledCount;return $p}
function Plan($f,[string]$market='하락'){At58L-Candidate $f.Source (Portfolio $f) $f.Snapshot $market $f.Book}
function Node($f,$intent){$key=At58-Hash ('synthetic-node-'+$f.Book.Orders.Count);$o=[pscustomobject]@{Key=$key;RootKey=$key;BrokerId=([string](100+$f.Book.Orders.Count));Day=$f.Snapshot.Day;Action='NEW';State='OPEN';Intent=(At58S-Clone $intent);Remaining=$intent.Qty};$f.Book.Orders+=,$o;return $o}
function Fill($f,$o,[decimal]$qty,[decimal]$price){$f.Book.Fills+=,[pscustomobject]@{Key=(At58-Hash ('synthetic-fill-'+$f.Book.Fills.Count));OrderKey=$o.Key;Account=$f.Book.Account;Day=$f.Snapshot.Day;Time=('1000'+$f.Book.Fills.Count.ToString('00')+'000');Qty=$qty;Price=$price;Amount=($qty*$price);Evidence='BROKER_NOTIFICATION_RECONCILED'};$o.Remaining-=$qty;$o.State=if($o.Remaining -eq 0){'FILLED'}else{'PARTIAL'}}
$f=Fixture;$original=Plan $f;$table=@($original.Rows|ForEach-Object {$_.BuyPrice})
Check ($original.Intent.Stage -eq 11 -and $original.Intent.Price -eq $table[10] -and $original.Intent.Price -gt $f.Snapshot.Quote.Price) 'gap-down buy uses the selected table price instead of the last trade'
$packet=At58O-Request $original.Intent
Check ($packet.Body.oder_cls_code -ceq '01' -and $packet.Body.oder_unpr -eq $table[10] -and $packet.Body.odqt -eq $original.Intent.Qty) 'broker packet remains a limit order with table price and calculated quantity'
$rising=Plan $f '상승'
Check ($rising.Intent.Price -eq $rising.Rows[10].BuyPrice -and $rising.Intent.Price -ne $original.Intent.Price) 'selected market regime determines the table and exact limit price'
$above=Fixture;$above.Snapshot.Quote.Price=$table[10]+5
Check ($null -eq (Plan $above).Intent) 'no buy is triggered above the next stage table price'
$equal=Fixture;$equal.Snapshot.Quote.Price=$table[10]
Check ((Plan $equal).Intent.Price -eq $table[10]) 'price at the threshold still triggers a table-priced order'
Check ($null -eq (Plan $f '급락').Intent) 'crash risk pause still blocks buys'
$cash=Fixture;$cash.Snapshot.Cash.Orderable=0
Check ($null -eq (Plan $cash).Intent) 'insufficient available cash still blocks buys'
$spent=0D
foreach($stage in @(11,12,13)){
 $plan=Plan $f;$i=$plan.Intent
 Check ($i.Stage -eq $stage -and $i.Price -eq $table[$stage-1] -and $i.Target -eq $i.Price) ('stage '+$stage+' advances at an unchanged last trade and retains its table price')
 $o=Node $f $i
 Check ($null -eq (Plan $f).Intent) ('stage '+$stage+' open order blocks duplicate or next-stage submission')
 Fill $f $o $i.Qty 6800;$spent+=$i.Qty*6800
 $p=Portfolio $f
 Check ($p.Anchors.([string]$stage).Entry -eq 6800 -and $p.Cash -eq $f.Source.Ledger.Cash-$spent) ('stage '+$stage+' holdings and cash use actual fill amount')
 $next=Plan $f
 Check ($next.Rows[$stage].BuyPrice -eq $table[$stage]) ('stage '+$stage+' actual fill does not lower the next stage threshold')
}
$p=Portfolio $f
Check (($p.DailyStages.FilledStages -join ',') -ceq '11,12,13' -and $p.DailyStages.NewStageSlots -eq 0) 'three distinct filled stages consume the daily allowance'
$f.Snapshot.Quote.Price=6400
Check ($null -eq (Plan $f).Intent) 'fourth new stage remains blocked even after another price drop'
$state=[pscustomobject]@{TestOnly=$false;Scope=$f.Source.Scope;Symbol=$f.Source.Symbol;SourceHash=''}
$catalog=Sheet-JournalCatalog $state $f.Book
Check ($catalog.Orders.Count -eq 3 -and @($catalog.Orders|Where-Object {$_.Values[3] -ne 6800}).Count -eq 0) 'three stage journal rows show actual fills, not their distinct order limits'
Check (($catalog.Orders|ForEach-Object {$_.Values[5]}|Measure-Object -Sum).Sum -eq $spent) 'journal total exactly matches the sum of actual broker fill amounts'
# Partial fills, cancellations and retries keep one goal and the original quantity.
$partial=Fixture;$first=(Plan $partial).Intent;$o=Node $partial $first
Fill $partial $o 3 6785
Check ($null -eq (Plan $partial).Intent -and (Portfolio $partial).DailyStages.FilledCount -eq 1) 'partial fill blocks the next stage and counts its stage once'
$o.State='CANCELLED';$remaining=$o.Remaining;$retry=(Plan $partial).Intent
Check ($retry.Stage -eq 11 -and $retry.Price -eq $first.Target -and $retry.Qty -eq $remaining -and $retry.GoalQty -eq $first.GoalQty -and $retry.GoalId -ceq $first.GoalId) 'cancelled partial buy resumes only its remainder at the original table price'
$partial.Snapshot.Cash.Orderable=$remaining*6800
Check ($null -eq (Plan $partial).Intent) 'retry requires cash for its actual limit rather than a cheaper last trade'
$partial.Snapshot.Cash.Orderable=9000000D;$last=Node $partial $retry;Fill $partial $last $remaining 6800
$p=Portfolio $partial;$expected=3*6785+$remaining*6800
Check ($p.DailyStages.FilledCount -eq 1 -and $p.Qty -eq 100+$first.GoalQty -and $p.Cash -eq 9000000-$expected) 'retry cannot double the goal quantity or count a second daily stage'
Check ((Plan $partial).Intent.Stage -eq 12) 'next stage becomes eligible only after the complete goal fills'
# Split executions of one broker order still produce one weighted-average row.
$split=Fixture;$i=(Plan $split).Intent;$o=Node $split $i;Fill $split $o 3 6785;Fill $split $o ($i.Qty-3) 6800
$cat=Sheet-JournalCatalog $state $split.Book;$amount=3*6785+($i.Qty-3)*6800
Check ($cat.Orders.Count -eq 1 -and $cat.Orders[0].Values[4] -eq $i.Qty -and $cat.Orders[0].Values[5] -eq $amount -and $cat.Orders[0].Values[3] -eq $amount/$i.Qty) 'split fills retain one order row with exact total and weighted actual fill price'
# The existing next-cycle breakout entry is a separate upward trigger.
$entry=Fixture;$entry.Source.Cycle.Phase='다음 사이클 대기';$entry.Source.Ledger.Qty=0D;$entry.Source.Ledger.Average=0D;$entry.Source.Ledger.Held=@();$entry.Source.Ledger.Rows=@();$entry.Snapshot.Quote.Price=10050D
$start=(Plan $entry).Intent
Check ($start.Entry -and $start.EntryMode -ceq 'BREAKOUT' -and $start.Price -eq 10050 -and $start.Target -eq 10000) 'existing upward next-cycle breakout behavior is preserved'
$neutral=Fixture;$neutral.Snapshot|Add-Member MarketContext ([pscustomobject]@{Schema='AT-NEUTRAL-RANGE-1';SnapshotUtc=$neutral.Snapshot.CompletedUtc;BasisDay=$neutral.Snapshot.Day;Name='보합';Usable=$true;Inside=$true;Lower=6500D;Upper=8000D;BuyCeiling=7000D;SellFloor=7800D})
$range=Plan $neutral '보합'
Check ($range.Intent.Price -eq $range.Rows[10].BuyPrice -and $range.Intent.Price -gt 6800) 'eligible range-regime stage uses its selected table limit too'
# Public broker daily limits constrain the packet, never the strategy table.
function Reject($body,[string]$code,[string]$name){$found='';try{& $body|Out-Null}catch{$found=(At58-Error $_).Code};Check ($found -ceq $code) ($name+' ['+$found+']')}
$capped=Fixture;$capped.Snapshot.Quote|Add-Member UpperLimit 7100;$capped.Snapshot.Quote|Add-Member LowerLimit 6000
$capPlan=Plan $capped
Check ($capPlan.Intent.Price -eq 7100 -and $capPlan.Intent.Target -eq $table[10] -and $capPlan.Rows[10].BuyPrice -eq $table[10]) 'daily upper limit caps only the order price and leaves the table target intact'
Check ((At58O-Request $capPlan.Intent).Body.oder_unpr -eq 7100 -and $capPlan.Intent.Qty -eq $original.Intent.Qty) 'capping a limit does not inflate the table-calculated quantity'
At58O-CheckPrice $capPlan.Intent $capped.Snapshot.Quote
Check ((At58O-BuyLimit 7000 $capped.Snapshot.Quote) -eq 7000 -and (At58O-BuyLimit 7100 $capped.Snapshot.Quote) -eq 7100) 'table prices below or exactly at the daily ceiling are unchanged'
$bad=At58S-Clone $capPlan.Intent;$bad.Price=7105
Reject {At58O-CheckPrice $bad $capped.Snapshot.Quote} 'TRADE_PRICE_LIMIT' 'one tick above the actual daily maximum is blocked before sending'
$bad.Price=5995
Reject {At58O-CheckPrice $bad $capped.Snapshot.Quote} 'TRADE_PRICE_LIMIT' 'one tick below the actual daily minimum is blocked before sending'
Reject {At58O-CheckPrice $capPlan.Intent (Fixture).Snapshot.Quote} 'TRADE_PRICE_LIMITS' 'live price validation rejects missing daily limits'
$invalid=At58S-Clone $capped.Snapshot.Quote;$invalid.UpperLimit=0
Reject {At58O-PriceBounds $invalid} 'TRADE_PRICE_LIMITS' 'zero or inverted daily limits cannot authorize an order'
$invalid.UpperLimit=7103
Reject {At58O-PriceBounds $invalid} 'TRADE_PRICE_LIMITS' 'invalid tick in daily limits is rejected'
$invalid.UpperLimit=7100;$invalid.Price=7105
Reject {At58O-PriceBounds $invalid} 'TRADE_PRICE_LIMITS' 'a quote inconsistent with its daily limits cannot authorize an order'
Check ((At58O-BuyLimit 5995 $capped.Snapshot.Quote) -eq 0) 'a target below the daily floor is never raised above the strategy target'
$o=Node $capped $capPlan.Intent;Fill $capped $o 3 6800;$o.State='CANCELLED'
Check ((Plan $capped).Intent.Price -eq 7100 -and (Plan $capped).Intent.Target -eq $table[10]) 'partial buy resumption applies the actual daily upper limit as well'
$ack=[pscustomobject]@{State='SUBMITTING';LastResponse='';BrokerId=''}
foreach($warning in @('1','2','a','h','z')){
 $result=At58O-Ack $ack @{rsp_cd='0001';data=@{warn_cls_code=$warning;oder_no='123'}}
 Check ($result.State -cne 'ACKNOWLEDGED' -and !$result.BrokerId) ('warning '+$warning+' is never mistaken for an accepted order')
}
Check ($packet.Body.warn_cnfr_yn -ceq 'N') 'orders do not bypass broker warnings by confirming them automatically'
Check ($script:network -eq 0) 'all regression scenarios made zero network or broker order calls'
Write-Output ('BUY TABLE TESTS COMPLETE: '+$script:checks+' passed; synthetic local state only.')
