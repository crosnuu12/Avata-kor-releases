$ErrorActionPreference='Stop'

Set-StrictMode -Version 2

. (Join-Path $PSScriptRoot 'At58.Core.ps1')

$script:checks=0

function Check($ok,[string]$name){if(!$ok){throw ('TEST FAILED: '+$name)};$script:checks++;Write-Output ('PASS '+$name)}

function Reject($action,[string]$code,[string]$name){$actual='';try{& $action|Out-Null}catch{$actual=(At58-Error $_).Code};Check ($actual -ceq $code) $name}

function Envelope($data,[string]$code='5766',[string]$cont='0',[string]$key=''){return [pscustomobject]@{data=$data;rsp_cd=$code;rsp_sub_msg='';tr_cont=$cont;tr_cont_key=$key}}

function Holding([int]$qty=10){return [pscustomobject]@{iscd='A0210A0';isnm='Fixture';pros_trgt_cls_code='1';mksc_cls_name='주식일반';rmnd_qty=$qty;byng_unpr='5000.50';psnt_prc=6000;vltn_amt=60000;vltn_prls_amt=9995}}

function Order([string]$id='1',[int]$left=3){return [pscustomobject]@{oder_no=$id;iscd='A0210A0';deal_cls_code='2';odqt=5;total_cntg_qty=2;ncnt_qty=$left;oder_unpr=6000;rctf_cncl_cls_code='1';orgl_oder_no='0';oder_pros_stat_cls_code='1';oder_rfus_reas_code='0000'}}

$testRoot=Join-Path $PSScriptRoot ('test-state-'+[guid]::NewGuid().ToString('N'))

[void][IO.Directory]::CreateDirectory($testRoot)

function Fixture {

 $script:clock=[datetime]::SpecifyKind([datetime]'2026-11-01T01:00:00',[DateTimeKind]::Utc)

 $script:calls=New-Object 'Collections.Generic.List[object]';$script:behavior='normal';$script:authFailures=0

 $ctx=At58-Context $testRoot '0210A0' ([pscustomobject]@{AppKey='fixture-key';AppSecret='fixture-secret'})

 $ctx.Mac='112233445566';$ctx.NoWait=$true;$ctx.Clock={return $script:clock}

 $ctx.Transport={param($method,$path,$query,$body,$token)

  $script:calls.Add([pscustomobject]@{Method=$method;Path=$path;Query=$query;Token=$token})

  if($path -ceq '/oauth2/token'){return [pscustomobject]@{access_token=('fixture-token-'+$script:calls.Count);expires_in=3600}}

  if($script:behavior -eq 'auth-once' -and $script:authFailures -eq 0){$script:authFailures++;return (Envelope $null 'EGW00123')}

  if($script:behavior -eq 'auth-always'){return (Envelope $null 'EGW00121')}

  if($script:behavior -eq 'http-auth-once' -and $script:authFailures -eq 0){$script:authFailures++;At58-ApiFailure 'EGW00123' 500 $path}

  if($script:behavior -eq 'network' -and $path -eq '/accounts/v1/me/deposit'){At58-Fail 'NETWORK' $path}

  if($script:behavior -eq 'rate-limit'){At58-ApiFailure 'EGW00200' 500 $path}

  switch($path){

   '/reference/v1/market-days' {

    if($script:behavior -in @('live','live-cross-close')){return (Envelope ([pscustomobject]@{tday_bsdy='20261102';bef_bsdy='20261030';nx_bsdy='20261103';sta_hour='090000';fin_hour='153000'}))}

    return (Envelope ([pscustomobject]@{tday_bsdy='20261030';bef_bsdy='20261029';nx_bsdy='20261102';sta_hour='090000';fin_hour='153000'}))

   }

   '/market/v1/prices' {return (Envelope ([pscustomobject]@{kor_isnm='Fixture';stck_prpr=6100;shrn_iscd='0210A0';mxpr=7800;llam=4200}) '0000')}

   '/market/v1/candles/days' {return (Envelope @([pscustomobject]@{date='20261030';stck_clpr=6000}) '0000')}

   '/accounts/v1/me/deposit' {return (Envelope ([pscustomobject]@{tfam=100000;d2_aft_tfam=90000;oder_able_cash_amt=80000}))}

   '/accounts/v1/me/valuation' {return (Envelope ([pscustomobject]@{aset_vltn_amt=160000;mksc_vltn_amt=60000}))}

   '/accounts/v1/me/holdings' {

    if($script:behavior -eq 'empty-hold'){return (Envelope @() '5820')}

    if($script:behavior -eq 'live-cross-close'){$script:clock=$script:clock.AddSeconds(2)}

    if($script:behavior -eq 'rollover'){$script:clock=$script:clock.AddSeconds(2)}

    if($script:behavior -eq 'slow'){$script:clock=$script:clock.AddSeconds(61)}

    if($script:behavior -eq 'page-loop'){return (Envelope @((Holding)) '5762' '1' ' key with spaces ')}

    if($script:behavior -eq 'two-pages'){

     if(!$query.ContainsKey('tr_cont')){return (Envelope @((Holding)) '5762' '1' ' key with spaces ')}

     if($query.tr_cont_key -cne ' key with spaces '){throw 'continuation trimmed'}

     $h=Holding 5;$h.iscd='A005930';return (Envelope @($h))

    }

    return (Envelope @((Holding)))

   }

   '/trading/v1/orders/history' {

    if($script:behavior -eq 'empty-missing'){return (Envelope $null '5820')}

    if($query.oder_date -ceq '20261030' -and $script:behavior -eq 'prior-open'){return (Envelope @((Order)))}

    return (Envelope @() '5820')

   }

  };throw 'unexpected route'

 }

 return $ctx

}

try{

 # Route checks run before token issuance or transport invocation.

 foreach($route in @('/trading/v1/orders/buy','/trading/v1/orders/sell','/trading/v1/orders/modify','/trading/v1/orders/cancel','/oauth2/revoke','https://example.com','/accounts/v1/me/deposit/../orders')){

  Reject {At58-Route 'GET' $route @{}} 'ROUTE_BLOCKED' ('no route '+$route)

 }

 Reject {At58-Route 'POST' '/accounts/v1/me/deposit' @{}} 'ROUTE_BLOCKED' 'POST cannot read or trade'

 Reject {At58-Route 'GET' '/oauth2/token' @{}} 'ROUTE_BLOCKED' 'token route accepts only POST'

 Reject {At58-Route 'GET' '/accounts/v1/me/deposit' @{acno='fixture'}} 'QUERY_BLOCKED' 'account number cannot be sent'

 Reject {At58-Route 'GET' '/market/v1/prices' @{redirect='https://example.com'}} 'QUERY_BLOCKED' 'unapproved query cannot redirect'

 Check ((At58-Value (Envelope @()) 'data') -is [array]) 'empty list remains array rather than missing data'

 foreach($bad in @($null,'','nan','Infinity','-1','1.5')){Reject {At58-Number $bad $true} 'DATA_INVALID' ('invalid quantity '+[string]$bad)}

 Check ((At58-Number 0 $true) -eq 0) 'numeric zero accepted'

 Check ((At58-Number '-10' $false $true) -eq -10) 'negative cash preserved'

 $ctx=Fixture;$s=At58-ReadSnapshot $ctx

 Check ($s.Source -ceq 'MERITZ_DIRECT' -and !$s.ExecutionEnabled -and !$s.Quote.TradeReady) 'direct snapshot has no execution authority'

 Check ($s.Quote.Mode -ceq 'CLOSED_DAILY' -and $s.Quote.BasisDay -ceq '20261030' -and $s.Quote.Price -eq 6000) 'weekend uses confirmed business-day close'

 Check ($s.TargetQty -eq 10 -and $s.TargetAverage -eq 5000.5 -and $s.Holdings.Count -eq 1) 'holdings normalize directly from broker'

 Check ($s.Cash.Orderable -eq 80000 -and $s.Valuation.Total -eq 160000) 'cash and valuation parsed'

 Check ($s.OpenOrdersToday.Count -eq 0 -and $s.PriorUnresolved.Count -eq 0) 'empty history confirmed as zero open orders'

 Check (@($script:calls|Where-Object {$_.Method -eq 'POST'}).Count -eq 1) 'only token issuance used POST'

 Check (@($script:calls|Where-Object {$_.Path -like '*sheets*'}).Count -eq 0) 'no Sheets request needed'

 $before=$script:calls.Count;At58-Token $ctx;Check ($script:calls.Count -eq $before) 'token reused until expiration'

 $ctx.TokenUntil=$script:clock.AddSeconds(-1);At58-Token $ctx;Check ($script:calls.Count -eq $before+1) 'expired cached token refreshed'

 $ctx=Fixture;$script:behavior='live';$script:clock=[datetime]::SpecifyKind([datetime]'2026-11-02T01:00:00',[DateTimeKind]::Utc);$s=At58-ReadSnapshot $ctx

 Check ($s.Quote.Mode -ceq 'LIVE_REST' -and $s.Quote.Price -eq 6100 -and $s.Quote.UpperLimit -eq 7800 -and $s.Quote.LowerLimit -eq 4200 -and $s.Day -ceq '20261102' -and !$s.Quote.TradeReady) 'trading-session snapshot uses direct REST quote without enabling orders'

 Check (@($script:calls|Where-Object {$_.Path -eq '/market/v1/candles/days'}).Count -eq 0) 'trading session cannot substitute yesterday close'

 $ctx=Fixture;$script:behavior='live-cross-close';$script:clock=[datetime]::SpecifyKind([datetime]'2026-11-02T06:29:59',[DateTimeKind]::Utc)

 Reject {At58-ReadSnapshot $ctx} 'SESSION_CHANGE' 'read spanning market close must be repeated'

 $ctx=Fixture;$script:behavior='empty-hold';$s=At58-ReadSnapshot $ctx

 Check ($s.Holdings.Count -eq 0 -and $s.TargetQty -eq 0) 'confirmed empty holdings report zero only after full successful response'

 $ctx=Fixture;$script:behavior='auth-once';$null=At58-Get $ctx '/accounts/v1/me/deposit' @{}

 Check (@($script:calls|Where-Object {$_.Path -eq '/oauth2/token'}).Count -eq 2) 'HTTP200 token-expired body renews once'

 $ctx=Fixture;$script:behavior='http-auth-once';$null=At58-Get $ctx '/accounts/v1/me/deposit' @{}

 Check (@($script:calls|Where-Object {$_.Path -eq '/oauth2/token'}).Count -eq 2) 'HTTP500 token-expired result renews once'

 $ctx=Fixture;$script:behavior='auth-always';Reject {At58-Get $ctx '/accounts/v1/me/deposit' @{}} 'TOKEN_EXPIRED' 'persistent auth failure bounded to one retry'

 Check (@($script:calls|Where-Object {$_.Path -eq '/oauth2/token'}).Count -eq 2 -and !$ctx.Token) 'failed renewal never loops or retains invalid token'

 $ctx=Fixture;$script:behavior='rate-limit';Reject {At58-Get $ctx '/accounts/v1/me/deposit' @{}} 'RATE_LIMIT' 'rate limit classified without credential renewal'

 Check (@($script:calls|Where-Object {$_.Path -eq '/oauth2/token'}).Count -eq 1) 'rate limit does not mint extra token'

 Reject {At58-ApiFailure '' 0 '/oauth2/token' 'NameResolutionFailure'} 'DNS' 'DNS failure classified without raw host exception'

 Reject {At58-ApiFailure '' 0 '/oauth2/token' 'TrustFailure'} 'TLS' 'TLS failure classified without raw certificate error'

 Reject {At58-ApiFailure '' 0 '/oauth2/token' 'Timeout'} 'TIMEOUT' 'request timeout classified'

 $ctx=Fixture;$ctx.Token='fixture-token';$ctx.TokenUntil=$script:clock.AddHours(1);$ctx.Transport={return [pscustomobject]@{data=@()}}

 Reject {At58-Get $ctx '/accounts/v1/me/holdings' @{}} 'RESPONSE_SCHEMA' 'missing result code is not assumed successful'

 $ctx=Fixture;$script:behavior='two-pages';$s=At58-ReadSnapshot $ctx

 Check ($s.Holdings.Count -eq 2 -and $s.TargetQty -eq 10) 'all holding pages read and target isolated'

 $ctx=Fixture;$script:behavior='page-loop';Reject {At58-ReadSnapshot $ctx} 'PAGE_INCOMPLETE' 'repeated continuation rejected'

 $ctx=Fixture;$script:behavior='empty-missing';Reject {At58-ReadSnapshot $ctx} 'DATA_MISSING' 'missing history is not zero orders'

 $ctx=Fixture;$script:behavior='prior-open';$s=At58-ReadSnapshot $ctx

 Check ($s.OpenOrdersToday.Count -eq 0 -and $s.PriorUnresolved.Count -eq 1) 'prior-day remainder never represented as current-day order'

 Reject {At58-Holdings @((Holding),(Holding)) '0210A0'} 'HOLDING_DUPLICATE' 'duplicate holdings cannot inflate position'

 $foreign=Holding;$foreign.iscd='AAPL.OQ';$foreign.pros_trgt_cls_code='J';$foreign.rmnd_qty='0.5'

 $h=At58-Holdings @((Holding),$foreign) '0210A0';Check ($h.TargetQty -eq 10 -and $h.Rows.Count -eq 2) 'foreign fractional holdings remain distinct'

 $o=Order;$o.ncnt_qty=4;Reject {At58-Orders @($o) '20261101'} 'ORDER_QUANTITY' 'overcommitted order quantities rejected'

 $o1=Order;$o2=Order;$o2.ncnt_qty=1;Reject {At58-Orders @($o1,$o2) '20261101'} 'ORDER_CHANGED_DURING_READ' 'conflicting repeated order rejected'

 Check (@(At58-Orders @((Order),(Order)) '20261101').Count -eq 1) 'exact repeated order deduplicated'

 $ctx=Fixture;$script:clock=[datetime]::SpecifyKind([datetime]'2026-11-01T14:59:59',[DateTimeKind]::Utc);$script:behavior='rollover';Reject {At58-ReadSnapshot $ctx} 'DATE_CHANGE' 'mixed-day snapshot discarded'

 $ctx=Fixture;$script:behavior='slow';Reject {At58-ReadSnapshot $ctx} 'SNAPSHOT_TIMEOUT' 'overlong snapshot discarded'

 $cal=Envelope ([pscustomobject]@{tday_bsdy='20261102';bef_bsdy='20261030';nx_bsdy='20261103';sta_hour='090000';fin_hour='153000'})

 $session=At58-Session $cal ([datetime]'2026-11-02T08:00:00');Check (!$session.Live -and $session.ExpectedClose -eq '20261030') 'pre-open uses prior trading close'

 $session=At58-Session $cal ([datetime]'2026-11-02T09:00:00');Check $session.Live 'session opens exactly at market open'

 $session=At58-Session $cal ([datetime]'2026-11-02T15:30:00');Check (!$session.Live -and $session.ExpectedClose -eq '20261102') 'session closes exactly at market close'

 Reject {At58-Session $cal ([datetime]'2026-11-01T10:00:00')} 'SESSION_INVALID' 'future calendar rejected'

 # Actual HTTP wrapper gets a fake PowerShell HTTP500 error; no socket is opened.

 $script:capturedUri='';$script:wireMode='error'

 function Invoke-RestMethod {

  param($Method,$Uri,$TimeoutSec,$MaximumRedirection,$ErrorAction,$Headers,$Body,$ContentType)

  $script:capturedUri=$Uri

  $e=[InvalidOperationException]::new('SECRET_RAW_BODY')

  $r=[Management.Automation.ErrorRecord]::new($e,'fixture',[Management.Automation.ErrorCategory]::InvalidOperation,$null)

  $r.ErrorDetails=[Management.Automation.ErrorDetails]::new('{"rsp_cd":"EGW00123","rsp_msg":"SECRET_RAW_BODY"}')

  throw $r

 }

 $ctx=Fixture;$ctx.Transport=$null;$ctx.Token='fixture-token'

 Reject {At58-Wire $ctx 'GET' '/accounts/v1/me/deposit' @{}} 'TOKEN_EXPIRED' 'HTTP wrapper reads bounded error body without leaking it'

 Check ($script:capturedUri -ceq 'https://openapi.imeritz.com:9443/accounts/v1/me/deposit') 'fixed HTTPS broker origin'

 Remove-Item Function:\Invoke-RestMethod

 # DPAPI fixtures use only this test directory and synthetic credentials.

 At58-SaveCredential $testRoot 'fixture-key' 'fixture-secret';$loaded=At58-LoadCredential $testRoot

 Check ($loaded.AppKey -ceq 'fixture-key' -and [IO.File]::ReadAllText((Join-Path $testRoot 'credentials.dpapi')) -notmatch 'fixture-secret') 'credentials persist encrypted'

 $mtPath=Join-Path $testRoot 'fixture-mt.dpapi';At58-Atomic $mtPath (At58-Protect '{"Version":1,"AppKey":"fixture-key","AppSecret":"fixture-secret","JsonPath":"unused"}' 'esbada-meritz-preferences-v1')

 At58-ImportMtCredential $testRoot $mtPath;$loaded=At58-LoadCredential $testRoot

 Check ($loaded.AppKey -ceq 'fixture-key' -and !$loaded.PSObject.Properties['JsonPath']) 'one-time import retains only broker credentials'

 $ctx=Fixture;$r=At58-Cycle $ctx

 Check $r.Ok 'complete cycle commits encrypted snapshot'

 $snapshotPath=Join-Path $testRoot 'snapshot.dpapi';$priorBytes=[IO.File]::ReadAllText($snapshotPath)

 Check ($priorBytes -notmatch 'TargetQty|fixture-token|fixture-secret') 'snapshot encrypted and token-free'

 $cache=At58-Cache $ctx;Check ($cache.TargetQty -eq 10 -and !$cache.ExecutionEnabled) 'encrypted cache reads only as historical display'

 $other=Fixture;$other.Scope='different';Check ($null -eq (At58-Cache $other)) 'cache cannot cross accounts'

 $script:behavior='network';$failed=At58-Cycle $ctx

 Check (!$failed.Ok -and $failed.Status.Code -ceq 'NETWORK' -and $failed.RetrySeconds -eq 30) 'failed cycle exposes bounded retry'

 Check ([IO.File]::ReadAllText($snapshotPath) -ceq $priorBytes -and $ctx.Snapshot.TargetQty -eq 10) 'failure preserves last complete snapshot without overwriting it'

 $diagnostic=[IO.File]::ReadAllText((Join-Path $testRoot 'status.json'))

 Check ($diagnostic -notmatch 'fixture-secret|fixture-token|AppKey|TargetQty|60000') 'plain diagnostics exclude credentials and financial payload'

 $second=At58-Cycle $ctx;Check ($second.RetrySeconds -eq 60) 'repeated failures back off'

 $script:behavior='normal';$recovered=At58-Cycle $ctx;Check ($recovered.Ok -and $ctx.Failures -eq 0) 'next complete cycle recovers and resets failure count'

 # Parse both entry points under the target runtime.

 foreach($file in @('At58.Core.ps1','esbada_Merits_AT_v58.ps1')){

  $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file),[ref]$tokens,[ref]$errors)

  Check ($errors.Count -eq 0) ('PowerShell syntax '+$file)

 }

 Write-Output ('AT58 SELFTEST COMPLETE: '+$script:checks+' passed; synthetic inputs only; broker/Sheets requests 0; real orders 0.')

}finally{

 $resolved=[IO.Path]::GetFullPath($testRoot);$parent=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\'

 if(!$resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^test-state-[a-f0-9]{32}$'){throw 'Unexpected cleanup path'}

 Remove-Item -LiteralPath $resolved -Recurse -Force

}

