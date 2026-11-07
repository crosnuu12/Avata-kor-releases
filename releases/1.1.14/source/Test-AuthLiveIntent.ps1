#requires -Version 5.1
param([string]$Root=$PSScriptRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
. (Join-Path $Root 'bundle/At58.Ops.ps1')
. (Join-Path $Root 'bundle/At58.Sheets.ps1')
. (Join-Path $Root 'bundle/payload/At58.Core.ps1')
. (Join-Path $Root 'tests/CashFixture.ps1')
$script:checks=0;$script:wire=0;$script:issues=0;$script:orderCalls=0;$script:rejectAuth=$false;$script:duplicate=''
function Check($ok,[string]$name){if(!$ok){throw ('FAILED: '+$name)};$script:checks++;Write-Output ('PASS '+$name)}
$portable=($env:OS -cne 'Windows_NT')
if($portable){
 function At58-Protect([string]$plain,[string]$purpose=''){return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($purpose+"`n"+$plain))}
 function At58-Unprotect([string]$cipher,[string]$purpose=''){$plain=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($cipher));$prefix=$purpose+"`n";if(!$plain.StartsWith($prefix)){throw 'TEST_PURPOSE'};return $plain.Substring($prefix.Length)}
}
function At58-Mac {return '001122334455'}
# This boundary is synthetic. The actual auth adapter and live cycle remain in use.
function Invoke-RestMethod {
 param($Method,$Uri,$Headers,$Body,$ContentType,$TimeoutSec,$MaximumRedirection,$ErrorAction)
 $script:wire++
 if($Method -ceq 'POST' -and $Uri -ceq 'https://openapi.imeritz.com:9443/oauth2/token'){
  $script:issues++;return @{access_token=('synthetic-access-'+$script:issues);expires_in=3600}
 }
 if($Method -ceq 'GET' -and $Uri -ceq 'https://openapi.imeritz.com:9443/accounts/v1/me/deposit'){
  if($script:rejectAuth){return @{rsp_cd='EGW00123';rsp_sub_msg='';data=@{}}}
  return @{rsp_cd='0000';rsp_sub_msg='';data=@{proof='synthetic'}}
 }
 throw 'UNEXPECTED_SYNTHETIC_ROUTE'
}
function At58T-Wire {$script:orderCalls++;throw 'REAL_ORDER_FORBIDDEN'}
function At58X-Dispatch {$script:orderCalls++;throw 'ANY_ORDER_FORBIDDEN'}
function At58I-Read($owner,$from,$to){return [pscustomobject]@{Schema='AT-CASH-INTEREST-1';Scope=$owner.Scope;From=$from;To=$to;Utc=$script:cashClock.ToString('o');Rows=@()}}
function At58X-Costs {return @()}
function At58-List {return @()}
function At58E-Run {return [pscustomobject]@{Code='LISTENING';Connected=$true;ReceiptAck=$true;FillAck=$true;ReceiptProofComplete=$true;Pending=0;Gaps=0}}
function At58S-Market {return [pscustomobject]@{Name='하락'}}
function At58-ReadSnapshot($owner){
 $null=At58-Get $owner '/accounts/v1/me/deposit' @{}
 $s=At58S-Clone $script:fixture.Snapshot
 $s.CompletedUtc=if($script:duplicate){$script:duplicate}else{$script:cashClock.ToString('o')}
 $s.Quote.ReceivedUtc=$s.CompletedUtc;$s.PSObject.Properties.Remove('Execution');$s|Add-Member ExecutionEnabled $false -Force
 return $s
}
function Poll($f,[int]$advance=5){
 $script:fixture=$f;$script:cashClock=$script:cashClock.AddSeconds($advance);$f.Raw.Utc=$script:cashClock.ToString('o')
 At58-Atomic (Join-Path $f.Owner.Root 'strategy-input.dpapi') (At58-Protect ($f.Raw|ConvertTo-Json -Depth 30 -Compress) 'AT58-STRATEGY-INPUT-1')
 $f.Box.UiUtc=$script:cashClock.ToString('o');$result=At58X-ManagedCycle $f.Owner $f.Box;$f.Last=$result;return $result
}
function New-Fixture([string]$name,[bool]$armed=$true){
 $f=Cash-Fixture (Join-Path $work $name);$f.Owner.Transport=$null;$f.Owner.NoWait=$true;$f.Owner.Mac='001122334455'
 $f.Box=At58X-Mailbox $f.Owner.RunId;$f.Box.Mode='LIVE';$f.Last=$null
 if($armed){$session=At58X-NewSession $f.Owner $f.Source.Hash (At58D-Limits);At58X-Authorize $f.Owner $session $f.Source.Hash}
 $null=Poll $f;$null=Poll $f;return $f
}
$work=Join-Path ([IO.Path]::GetTempPath()) ('AvataAuthIntent-'+[guid]::NewGuid().ToString('N'))
try{
 $f=New-Fixture 'armed';$run=$f.Owner.RunId
 Check ($f.Last.Ok -and $f.Last.Status.Live.State -ceq 'ARMED' -and $f.Last.Status.Live.Confirmations -eq 2 -and $f.Last.Status.Live.Reconciled) 'synthetic operator authorization starts with two valid account proofs'
 $script:rejectAuth=$true;$failed=Poll $f
 Check (!$failed.Ok -and $failed.Status.Code -ceq 'TOKEN_EXPIRED' -and $failed.Status.ApiCode -ceq 'EGW00123') 'actual GET auth adapter reports rejected renewed token through the live cycle'
 Check ($failed.Status.Live.State -ceq 'ARMED' -and !$failed.Status.ExecutionEnabled -and !$failed.Status.Live.Reconciled -and $failed.Status.Live.Confirmations -eq 0) 'auth rejection preserves existing operator intent while execution and reconciliation remain blocked'
 $saved=At58X-Load $f.Owner
 Check ($saved.Confirmations -eq 0 -and $saved.Proof -ceq '') 'auth rejection also clears the persisted account quorum'
 $calls=$script:wire;$issues=$script:issues;$held=Poll $f
 Check (!$held.Ok -and $held.Status.Code -ceq 'TOKEN_EXPIRED' -and $script:wire -eq $calls -and $script:issues -eq $issues) 'the next live cycle respects auth cooldown without another token or account request'
 Check ($held.Status.Live.State -ceq 'ARMED' -and !$held.Status.ExecutionEnabled -and $script:orderCalls -eq 0) 'waiting for authentication never disarms existing intent or sends an order'
 $script:rejectAuth=$false;$first=Poll $f 301
 Check ($first.Ok -and $first.Status.Live.State -ceq 'ARMED' -and $first.Status.Live.Confirmations -eq 1 -and !$first.Status.Live.Reconciled) 'first successful read after auth recovery rebuilds only one account proof'
 Check ($first.Status.Live.Code -ceq 'LIVE_MARKET_WAIT' -and !$first.Status.ExecutionEnabled -and $f.Owner.RunId -ceq $run) 'same approved process returns to off-hours wait without reauthorizing or submitting'
 $script:duplicate=$first.Snapshot.CompletedUtc;$duplicateResult=Poll $f;$script:duplicate=''
 Check ($duplicateResult.Status.Live.Code -ceq 'LIVE_DUPLICATE_SNAPSHOT' -and $duplicateResult.Status.Live.Confirmations -eq 1 -and !$duplicateResult.Status.Live.Reconciled) 'reusing one recovered snapshot cannot satisfy the second account proof'
 $second=Poll $f
 Check ($second.Ok -and $second.Status.Live.Reconciled -and $second.Status.Live.Confirmations -eq 2 -and $second.Status.Live.Code -ceq 'LIVE_MARKET_WAIT') 'second fresh successful account read restores verified market wait'

 $d=New-Fixture 'disarmed' $false;$script:rejectAuth=$true;$null=Poll $d;$script:rejectAuth=$false
 $null=Poll $d 301;$disarmed=Poll $d
 Check ($disarmed.Ok -and $disarmed.Status.Live.State -ceq 'DISARMED' -and !$disarmed.Status.ExecutionEnabled -and !(At58-Value $d.Owner 'LiveSession')) 'authentication recovery cannot create a session or arm a previously disarmed reader'

 $s=New-Fixture 'stop';$script:rejectAuth=$true;$null=Poll $s;$calls=$script:wire
 At58X-Queue $s.Box 'STOP' '' $null $script:cashClock
 $stopping=Poll $s
 Check (!$stopping.Ok -and $s.Box.StopRequested -and $s.Owner.MaintenanceStop -and !$s.Owner.MaintenanceStop.Complete -and $s.Owner.MaintenanceStop.Confirmations -eq 0) 'STOP received during auth cooldown stays pending with no fabricated account proof'
 Check ($script:wire -eq $calls -and $stopping.Status.Live.State -ceq 'STOPPING' -and !$stopping.Status.ExecutionEnabled -and $script:orderCalls -eq 0) 'STOP uses the same cooldown and cannot issue an order from failed account reads'
 $script:rejectAuth=$false;$one=Poll $s 301
 Check ($one.Ok -and $one.Status.Live.Confirmations -eq 1 -and $s.Box.StopRequested) 'first recovered stop read cannot clear the pending STOP'
 $two=Poll $s
 Check ($two.Ok -and $two.Status.Live.State -ceq 'DISARMED' -and $two.Status.Live.Reconciled -and $two.Status.Live.Confirmations -eq 2 -and !$s.Box.StopRequested -and $s.Owner.MaintenanceStop.Complete) 'two recovered stop proofs finish shutdown without restoring previous ARMED intent'
 foreach($fixture in @($f,$d,$s)){Check ((At58T-Load (At58X-Context $fixture.Owner)).Orders.Count -eq 0) 'authentication scenarios leave the synthetic order journal empty'}
 Check ($script:orderCalls -eq 0) 'no real or simulated order transport was invoked in any auth recovery scenario'
 Write-Output ('AUTH LIVE INTENT TESTS COMPLETE: '+$script:checks+' passed; PortableProtection='+$portable+'; synthetic HTTP only; no real network or orders.')
}finally{
 $safe=[IO.Path]::GetFullPath($work);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
 if([IO.Path]::GetDirectoryName($safe) -cne $parent -or [IO.Path]::GetFileName($safe) -cnotmatch '^AvataAuthIntent-[a-f0-9]{32}$'){throw 'TEST_CLEANUP_PATH'}
 if([IO.Directory]::Exists($safe)){Remove-Item -LiteralPath $safe -Recurse -Force}
}
