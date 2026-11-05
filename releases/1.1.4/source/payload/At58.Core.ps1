# AT58 stage 1: independent Meritz read-only input adapter. Windows PowerShell 5.1.

# Broker transport remains GET-only. Optional local strategy/paper execution is isolated from real account records.

Set-StrictMode -Version 2

$ErrorActionPreference='Stop'

[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

Add-Type -AssemblyName System.Security

function At58-Value($o,[string]$n){if($null -eq $o){return $null};if($o -is [Collections.IDictionary]){return ,$o[$n]};if($o.PSObject.Properties[$n]){return ,$o.$n};return $null}

function At58-Fail([string]$code,[string]$stage='VALIDATE',[string]$api=''){

 $e=[InvalidOperationException]::new($code);$e.Data['At58']=$true;$e.Data['Code']=$code;$e.Data['Stage']=$stage;$e.Data['Api']=$api;throw $e

}

function At58-Error($record){

 $e=$record.Exception

 for($i=0;$e -and $i -lt 8;$i++){

  if($e.Data['At58']){return [pscustomobject]@{Code=[string]$e.Data['Code'];Stage=[string]$e.Data['Stage'];Api=[string]$e.Data['Api']}}

  $e=$e.InnerException

 }

 return [pscustomobject]@{Code='UNEXPECTED';Stage='LOCAL';Api=''}

}

function At58-Number($v,[bool]$integer=$false,[bool]$signed=$false){

 $n=0D

 if($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v) -or ![decimal]::TryParse([string]$v,[Globalization.NumberStyles]::Number,[Globalization.CultureInfo]::InvariantCulture,[ref]$n) -or (!$signed -and $n -lt 0) -or ($integer -and $n -ne [decimal]::Truncate($n))){At58-Fail 'DATA_INVALID'}

 return $n

}

function At58-Text($v){return ([regex]::Replace([string]$v,'[\x00-\x1F\x7F]',' ')).Substring(0,[math]::Min(80,([string]$v).Length))}

function At58-Day([string]$v){$d=[datetime]::MinValue;if(![datetime]::TryParseExact($v,'yyyyMMdd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$d)){At58-Fail 'DATE_INVALID'};return $d}

function At58-Hour([string]$v){$d=[datetime]::MinValue;if(![datetime]::TryParseExact($v,'HHmmss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$d)){At58-Fail 'SESSION_INVALID'};return $d.TimeOfDay}

function At58-Kst([datetime]$utc){return [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([datetime]::SpecifyKind($utc,[DateTimeKind]::Utc),'Korea Standard Time')}

function At58-Now($ctx){if($ctx.Clock){return (& $ctx.Clock)};return [datetime]::UtcNow}

function At58-Hash([string]$v){$h=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($v)))).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}}

function At58-Symbol([string]$v){$v=$v.Trim();if($v -cmatch '^A[0-9A-Z]{6}$'){$v=$v.Substring(1)};return $v}

function At58-Atomic([string]$path,[string]$text){

 [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path)))

 $tmp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'

 try{[IO.File]::WriteAllText($tmp,$text,[Text.UTF8Encoding]::new($false));if([IO.File]::Exists($path)){[IO.File]::Replace($tmp,$path,[Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($tmp,$path)}}finally{if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}}

}

function At58-Protect([string]$plain,[string]$purpose='esbada-at-direct-v1'){

 $bytes=[Text.Encoding]::UTF8.GetBytes($plain)

 try{return [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($bytes,[Text.Encoding]::UTF8.GetBytes($purpose),[Security.Cryptography.DataProtectionScope]::CurrentUser))}finally{[Array]::Clear($bytes,0,$bytes.Length)}

}

function At58-Unprotect([string]$cipher,[string]$purpose='esbada-at-direct-v1'){

 $bytes=$null

 try{$bytes=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($cipher),[Text.Encoding]::UTF8.GetBytes($purpose),[Security.Cryptography.DataProtectionScope]::CurrentUser);return [Text.Encoding]::UTF8.GetString($bytes)}finally{if($bytes){[Array]::Clear($bytes,0,$bytes.Length)}}

}

function At58-CheckCredential($c){

 foreach($n in @('AppKey','AppSecret')){$v=[string](At58-Value $c $n);if([string]::IsNullOrWhiteSpace($v) -or $v.Length -gt 4096 -or $v -cne $v.Trim()){At58-Fail 'CREDENTIAL_INVALID' 'AUTH'}}

}

function At58-SaveCredential([string]$root,[string]$key,[string]$secret){

 $c=@{Version=1;AppKey=$key;AppSecret=$secret};At58-CheckCredential $c

 try{At58-Atomic (Join-Path $root 'credentials.dpapi') (At58-Protect ($c|ConvertTo-Json -Compress))}catch{At58-Fail 'CREDENTIAL_SAVE_FAILED' 'AUTH'}finally{$c=$null}

}

function At58-ImportMtCredential([string]$root,[string]$path){

 # One-time credential copy only. No MT data or runtime dependency is retained.

 $p=$null

 try{$p=(At58-Unprotect ([IO.File]::ReadAllText($path)) 'esbada-meritz-preferences-v1')|ConvertFrom-Json;At58-CheckCredential $p;At58-SaveCredential $root $p.AppKey $p.AppSecret}catch{At58-Fail 'CREDENTIAL_IMPORT_FAILED' 'AUTH'}finally{$p=$null}

}

function At58-LoadCredential([string]$root){

 try{$p=(At58-Unprotect ([IO.File]::ReadAllText((Join-Path $root 'credentials.dpapi'))))|ConvertFrom-Json;At58-CheckCredential $p;return $p}catch{At58-Fail 'CREDENTIAL_READ_FAILED' 'AUTH'}

}

function At58-Mac {

 foreach($n in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()){

  $m=$n.GetPhysicalAddress().ToString();if($n.OperationalStatus -eq 'Up' -and $m -cmatch '^[A-F0-9]{12}$' -and $m -ne '000000000000'){return $m}

 };At58-Fail 'MAC_UNAVAILABLE' 'AUTH'

}

function At58-Context([string]$root,[string]$symbol='0210A0',$credential=$null){

 if($symbol -cnotmatch '^[0-9A-Z]{6}$'){At58-Fail 'SYMBOL_INVALID'}

 if(!$credential){$credential=At58-LoadCredential $root};At58-CheckCredential $credential

 return @{Root=[IO.Path]::GetFullPath($root);Symbol=$symbol;Credential=$credential;Scope=(At58-Hash $credential.AppKey);Token='';TokenUntil=[datetime]::MinValue;Mac='';LastCall=[datetime]::MinValue;Calls=0;Failures=0;Sequence=0;LastSuccess='';Snapshot=$null;Transport=$null;Clock=$null;NoWait=$false;RunId=[guid]::NewGuid().ToString();Started=[datetime]::UtcNow;CycleStart=$null;Stage='IDLE';Version='58.1';EnableStrategy=$false;EnableExecutionFeed=$false;ManagementRoot=''}

}

function At58-ReadRoute([string]$method,[string]$path,$query){

 $rules=@{

  '/oauth2/token'=@();'/reference/v1/market-days'=@();'/market/v1/prices'=@('mrkt_div_code','iscd')

  '/market/v1/candles/days'=@('mrkt_div_code','iscd','mod_stpr_cls_code','tr_cont','tr_cont_key')

  '/accounts/v1/me/deposit'=@();'/accounts/v1/me/valuation'=@();'/accounts/v1/me/holdings'=@('nthn_rmnd_incu_yn','tr_cont','tr_cont_key')
  '/accounts/v1/me/transactions'=@('from','to','sort','tr_cont','tr_cont_key')

  '/trading/v1/orders/history'=@('oder_date','deal_cls_code','cntg_cls_code','sort_stnd_code','iscd','tr_cont','tr_cont_key')

 }

 if(!$rules.ContainsKey($path) -or ($path -ceq '/oauth2/token' -and $method -cne 'POST') -or ($path -cne '/oauth2/token' -and $method -cne 'GET')){At58-Fail 'ROUTE_BLOCKED' 'TRANSPORT'}

 foreach($k in $query.Keys){if($k -cnotin $rules[$path] -or ([string]$query[$k]).Length -gt 4096){At58-Fail 'QUERY_BLOCKED' 'TRANSPORT'}}

}

function At58-Code([string]$code){if($code -cmatch '^(?:(?:EGW|IGW)[0-9]{5}|[0-9]{4,5})$'){return $code};return ''}

function At58-ApiFailure([string]$code,[int]$http,[string]$stage,[string]$network=''){

 $kind=if($code -cin @('EGW00121','EGW00123') -or $http -eq 401){'TOKEN_EXPIRED'}elseif($code -eq 'EGW00103'){'CREDENTIAL_INVALID'}elseif($code -eq 'EGW00200' -or $http -eq 429){'RATE_LIMIT'}elseif($http -eq 403){'PERMISSION'}elseif($code){'API_ERROR'}elseif($network -eq 'NameResolutionFailure'){'DNS'}elseif($network -in @('TrustFailure','SecureChannelFailure')){'TLS'}elseif($network -eq 'Timeout' -or $http -eq 408){'TIMEOUT'}else{'NETWORK'}

 At58-Fail $kind $stage (At58-Code $code)

}

function At58-Wire($ctx,[string]$method,[string]$path,$query,$body=$null){

 At58-Route $method $path $query

 $ctx.Stage=$path

 if($ctx.CycleStart -and ((At58-Now $ctx)-$ctx.CycleStart).TotalSeconds -gt 60){At58-Fail 'SNAPSHOT_TIMEOUT' $path}

 if(!$ctx.NoWait){$ms=700-((At58-Now $ctx)-$ctx.LastCall).TotalMilliseconds;if($ms -gt 0){Start-Sleep -Milliseconds ([int][math]::Ceiling($ms))}}

 $ctx.LastCall=At58-Now $ctx;$ctx.Calls++

 if($ctx.Transport){return (& $ctx.Transport $method $path $query $body $ctx.Token)}

 $uri='https://openapi.imeritz.com:9443'+$path

 if($query.Count){$uri+='?'+(@(foreach($k in ($query.Keys|Sort-Object)){[uri]::EscapeDataString([string]$k)+'='+[uri]::EscapeDataString([string]$query[$k])})-join '&')}

 $a=@{Method=$method;Uri=$uri;TimeoutSec=10;MaximumRedirection=0;ErrorAction='Stop'}

 if($method -ceq 'POST'){$a.ContentType='application/x-www-form-urlencoded';$a.Body=$body}else{$a.Headers=@{authorization=('Bearer '+$ctx.Token);mac_address=$ctx.Mac}}

 try{return (Invoke-RestMethod @a)}catch{

  $record=$_;$http=0;$code='';$raw='';$network=''

  try{$http=[int]$record.Exception.Response.StatusCode}catch{}

  try{$ex=$record.Exception;for($i=0;$ex -and $i -lt 8;$i++){if($ex -is [Net.WebException]){$network=[string]$ex.Status};$ex=$ex.InnerException}}catch{}

  try{if($record.ErrorDetails -and $record.ErrorDetails.Message){$raw=$record.ErrorDetails.Message}else{$stream=$record.Exception.Response.GetResponseStream();$reader=[IO.StreamReader]::new($stream);try{$chars=New-Object char[] 16385;$n=$reader.ReadBlock($chars,0,16385);$raw=[string]::new($chars,0,$n)}finally{$reader.Dispose()}};if($raw.Length -le 16384){$b=$raw|ConvertFrom-Json;$code=At58-Code ([string](At58-Value $b 'rsp_cd'))}}catch{}

  $raw=$null;At58-ApiFailure $code $http $path $network

 }finally{$a=$null;$body=$null}

}

function At58-Token($ctx){

 $now=At58-Now $ctx

 if($ctx.Token -and $now -lt $ctx.TokenUntil){return}

 if(!$ctx.Mac){$ctx.Mac=At58-Mac}

 $body=@{grant_type='client_credentials';client_id=$ctx.Credential.AppKey;client_secret=$ctx.Credential.AppSecret;scope='login'}

 try{

  $r=At58-Wire $ctx 'POST' '/oauth2/token' @{} $body

  $code=At58-Code ([string](At58-Value $r 'rsp_cd'));if($code -and $code -cnotin @('0000','00000')){At58-ApiFailure $code 200 'AUTH'}

  $token=[string](At58-Value $r 'access_token');$life=At58-Number (At58-Value $r 'expires_in') $true

  if([string]::IsNullOrWhiteSpace($token) -or $token -match '[\r\n]' -or $life -le 120){At58-Fail 'TOKEN_SCHEMA' 'AUTH'}

  $ctx.Token=$token;$ctx.TokenUntil=(At58-Now $ctx).AddSeconds([double]$life-60)

 }finally{$body=$null;$r=$null}

}

function At58-Get($ctx,[string]$path,$query){

 At58-Route 'GET' $path $query

 for($attempt=0;$attempt -lt 2;$attempt++){

  try{

   At58-Token $ctx;$r=At58-Wire $ctx 'GET' $path $query

   $code=At58-Code ([string](At58-Value $r 'rsp_cd'))

   if(!$code){At58-Fail 'RESPONSE_SCHEMA' $path}

   if($code -cnotin @('0000','0001','5762','5766','5820','5822')){At58-ApiFailure $code 200 $path}

   if(!(At58-Value $r 'data') -and $null -eq (At58-Value $r 'data')){At58-Fail 'DATA_MISSING' $path}

   if(![string]::IsNullOrWhiteSpace([string](At58-Value $r 'rsp_sub_msg'))){At58-Fail 'API_DETAIL' $path $code}

   return $r

  }catch{

   $e=At58-Error $_

   if($e.Code -eq 'TOKEN_EXPIRED'){$ctx.Token='';$ctx.TokenUntil=[datetime]::MinValue;if($attempt -eq 0){continue}}

   throw

  }

 }

}

function At58-List($ctx,[string]$path,$query){

 $q=@{};foreach($k in $query.Keys){$q[$k]=$query[$k]}

 $rows=New-Object 'Collections.Generic.List[object]';$seen=New-Object 'Collections.Generic.HashSet[string]'

 for($page=1;$page -le 50;$page++){

  $r=At58-Get $ctx $path $q;$data=At58-Value $r 'data'

  if($data -isnot [array]){At58-Fail 'LIST_SCHEMA' $path}

  foreach($row in $data){if($null -eq $row){At58-Fail 'LIST_SCHEMA' $path};$rows.Add($row)}

  $cont=[string](At58-Value $r 'tr_cont')

  if($cont -cnotin @('','0','1')){At58-Fail 'PAGE_SCHEMA' $path}

  if($cont -cne '1' -and [string]$r.rsp_cd -cne '5762'){return ,$rows.ToArray()}

  $key=[string](At58-Value $r 'tr_cont_key')

  if([string]::IsNullOrWhiteSpace($key) -or !$seen.Add($key)){At58-Fail 'PAGE_INCOMPLETE' $path}

  $q.tr_cont='1';$q.tr_cont_key=$key

 };At58-Fail 'PAGE_LIMIT' $path

}

function At58-Object($r){$d=At58-Value $r 'data';if($null -eq $d -or $d -is [array] -or $d -is [string] -or $d -is [ValueType]){At58-Fail 'OBJECT_SCHEMA'};return $d}

function At58-Session($r,[datetime]$now){

 $d=At58-Object $r;$business=At58-Day ([string](At58-Value $d 'tday_bsdy'));$prev=At58-Day ([string](At58-Value $d 'bef_bsdy'));$next=At58-Day ([string](At58-Value $d 'nx_bsdy'))

 $open=At58-Hour ([string](At58-Value $d 'sta_hour'));$close=At58-Hour ([string](At58-Value $d 'fin_hour'))

 if($business -gt $now.Date -or $prev -ge $business -or $next -le $business -or $close -le $open){At58-Fail 'SESSION_INVALID'}

 $live=$business -eq $now.Date -and $now -ge ($business+$open) -and $now -lt ($business+$close)

 $expected=if($business -eq $now.Date -and $now.TimeOfDay -lt $open){$prev}else{$business}

 $nextOpen=if($business -eq $now.Date -and $now.TimeOfDay -lt $open){$business+$open}else{$next+$open}

 if(!$live -and $nextOpen -le $now){At58-Fail 'SESSION_STALE'}

 return [pscustomobject]@{Live=$live;BusinessDay=$business.ToString('yyyyMMdd');PreviousDay=$prev.ToString('yyyyMMdd');ExpectedClose=$expected.ToString('yyyyMMdd');Open=($business+$open);Close=($business+$close);NextOpen=$nextOpen;CalendarDay=$now.ToString('yyyyMMdd')}

}

function At58-Holdings($rows,[string]$target){

 $out=New-Object 'Collections.Generic.List[object]';$seen=New-Object 'Collections.Generic.HashSet[string]';$qty=0D;$cost=0D

 foreach($r in $rows){

  $product=[string](At58-Value $r 'pros_trgt_cls_code');$symbol=At58-Symbol ([string](At58-Value $r 'iscd'))

  if(!$product -or $symbol -cnotmatch '^[0-9A-Z._-]{1,24}$'){At58-Fail 'HOLDING_IDENTITY'}

  $q=At58-Number (At58-Value $r 'rmnd_qty') ($product -ceq '1');$avg=At58-Number (At58-Value $r 'byng_unpr')

  $item=[pscustomobject]@{Symbol=$symbol;Name=(At58-Text (At58-Value $r 'isnm'));Product=$product;Class=(At58-Text (At58-Value $r 'mksc_cls_name'));Qty=$q;Average=$avg;Price=(At58-Number (At58-Value $r 'psnt_prc'));ValueKRW=(At58-Number (At58-Value $r 'vltn_amt') $false $true);ProfitKRW=(At58-Number (At58-Value $r 'vltn_prls_amt') $false $true)}

  $key=At58-Hash ($r|ConvertTo-Json -Depth 10 -Compress)

  if(!$seen.Add($key)){At58-Fail 'HOLDING_DUPLICATE'}

  $out.Add($item);if($product -ceq '1' -and $symbol -ceq $target){$qty+=$q;$cost+=($q*$avg)}

 }

 return [pscustomobject]@{Rows=$out.ToArray();TargetQty=$qty;TargetAverage=if($qty -gt 0){$cost/$qty}else{0D}}

}

function At58-Orders($rows,[string]$day){

 $out=New-Object 'Collections.Generic.List[object]';$seen=@{}

 foreach($r in $rows){

  $id=[string](At58-Value $r 'oder_no');$symbol=At58-Symbol ([string](At58-Value $r 'iscd'));$side=[string](At58-Value $r 'deal_cls_code')

  if($id -cnotmatch '^[0-9]{1,20}$' -or $symbol -cnotmatch '^[0-9A-Z]{6}$' -or $side -cnotin @('1','2')){At58-Fail 'ORDER_IDENTITY'}

  $suppliedDay=[string](At58-Value $r 'oder_date');if($suppliedDay -and $suppliedDay -cne $day){At58-Fail 'ORDER_DATE'}

  $q=At58-Number (At58-Value $r 'odqt') $true;$f=At58-Number (At58-Value $r 'total_cntg_qty') $true;$left=At58-Number (At58-Value $r 'ncnt_qty') $true

  if($f -gt $q -or $left -gt $q -or ($left+$f) -gt $q){At58-Fail 'ORDER_QUANTITY'}

  $item=[pscustomobject]@{Day=$day;Id=$id;Symbol=$symbol;Side=$side;Qty=$q;Filled=$f;Remaining=$left;Price=(At58-Number (At58-Value $r 'oder_unpr'));Kind=[string](At58-Value $r 'rctf_cncl_cls_code');Original=[string](At58-Value $r 'orgl_oder_no');Status=[string](At58-Value $r 'oder_pros_stat_cls_code');Reject=[string](At58-Value $r 'oder_rfus_reas_code')}

  $key=$day+'|'+$id;$signature=$r|ConvertTo-Json -Depth 10 -Compress

  if($seen.ContainsKey($key)){if($seen[$key] -cne $signature){At58-Fail 'ORDER_CHANGED_DURING_READ'};continue}

  $seen[$key]=$signature;$out.Add($item)

 };return ,$out.ToArray()

}

function At58-OptionalAsset($o,[string]$key){try{$v=At58-Value $o $key;if($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v)){return $null};return (At58-Number $v $false $true)}catch{return $null}}

function At58-ReadSnapshot($ctx){

 $start=At58-Now $ctx;$ctx.CycleStart=$start;$kst=At58-Kst $start;$day=$kst.ToString('yyyyMMdd')

 try{

  $session=At58-Session (At58-Get $ctx '/reference/v1/market-days' @{}) $kst

  $quoteData=At58-Object (At58-Get $ctx '/market/v1/prices' @{mrkt_div_code='J';iscd=$ctx.Symbol})

  $quoteStamp=At58-Now $ctx;$price=At58-Number (At58-Value $quoteData 'stck_prpr')

  $quoteId=[string](At58-Value $quoteData 'shrn_iscd');if($quoteId -and (At58-Symbol $quoteId) -cne $ctx.Symbol){At58-Fail 'QUOTE_IDENTITY'}

  if($price -le 0){At58-Fail 'QUOTE_INVALID'}

  $basis=$day;$mode='LIVE_REST'

  if(!$session.Live){

   $days=At58-List $ctx '/market/v1/candles/days' @{mrkt_div_code='J';iscd=$ctx.Symbol;mod_stpr_cls_code='0'}

   $matched=@($days|Where-Object {[string](At58-Value $_ 'date') -ceq $session.ExpectedClose})

   if($matched.Count -ne 1){At58-Fail 'CLOSE_NOT_CONFIRMED'}

   $price=At58-Number (At58-Value $matched[0] 'stck_clpr');if($price -le 0){At58-Fail 'CLOSE_NOT_CONFIRMED'}

   $basis=$session.ExpectedClose;$mode='CLOSED_DAILY';$quoteStamp=At58-Now $ctx

  }

  $dep=At58-Object (At58-Get $ctx '/accounts/v1/me/deposit' @{})

  $cash=[pscustomobject]@{Deposit=(At58-Number (At58-Value $dep 'tfam') $false $true);D2=(At58-Number (At58-Value $dep 'd2_aft_tfam') $false $true);Orderable=(At58-Number (At58-Value $dep 'oder_able_cash_amt') $false $true)}

  foreach($m in @(@('D1','d1_aft_tfam'),@('Withdrawable','drng_able_amt'),@('CreditLoan','crdt_loan_amt'))){$cash|Add-Member -NotePropertyName $m[0] -NotePropertyValue (At58-OptionalAsset $dep $m[1])}
  $cashDue=At58-OptionalAsset $dep 'cash_unam';$otherDue=At58-OptionalAsset $dep 'etc_unam';$cash|Add-Member -NotePropertyName Receivable -NotePropertyValue $(if($null -ne $cashDue -and $null -ne $otherDue){$cashDue+$otherDue}else{$null})

  $val=At58-Object (At58-Get $ctx '/accounts/v1/me/valuation' @{})

  $valuation=[pscustomobject]@{Total=(At58-Number (At58-Value $val 'aset_vltn_amt') $false $true);Securities=(At58-Number (At58-Value $val 'mksc_vltn_amt') $false $true)}

  $valuation|Add-Member -NotePropertyName Loan -NotePropertyValue (At58-OptionalAsset $val 'loan_amt')

  $hold=At58-Holdings (At58-List $ctx '/accounts/v1/me/holdings' @{nthn_rmnd_incu_yn='N'}) $ctx.Symbol

  $orders=At58-Orders (At58-List $ctx '/trading/v1/orders/history' @{oder_date=$day;deal_cls_code='0';cntg_cls_code='0';sort_stnd_code='2'}) $day

  $prior=@()

  if($session.BusinessDay -cne $day){$prior=At58-Orders (At58-List $ctx '/trading/v1/orders/history' @{oder_date=$session.BusinessDay;deal_cls_code='0';cntg_cls_code='0';sort_stnd_code='2'}) $session.BusinessDay}

  $end=At58-Now $ctx;$endKst=At58-Kst $end

  if($end -lt $start -or ($end-$start).TotalSeconds -gt 60){At58-Fail 'SNAPSHOT_TIMEOUT'}

  if($endKst.ToString('yyyyMMdd') -cne $day){At58-Fail 'DATE_CHANGE'}

  if(($session.Live -and $endKst -ge $session.Close) -or (!$session.Live -and $endKst -ge $session.NextOpen)){At58-Fail 'SESSION_CHANGE'}

  return [pscustomobject][ordered]@{Schema='AT-DIRECT-1';Version='58.1';Source='MERITZ_DIRECT';Scope=$ctx.Scope;Day=$day;Symbol=$ctx.Symbol;StartedUtc=$start.ToString('o');CompletedUtc=$end.ToString('o');ExecutionEnabled=$false;Quote=[pscustomobject]@{Mode=$mode;Price=$price;Name=(At58-Text (At58-Value $quoteData 'kor_isnm'));BasisDay=$basis;ReceivedUtc=$quoteStamp.ToString('o');TradeReady=$false;UpperLimit=(At58-OptionalAsset $quoteData 'mxpr');LowerLimit=(At58-OptionalAsset $quoteData 'llam');Volume=(At58-Value $quoteData 'acml_vol');Tick=(At58-Value $quoteData 'aspr_unit')};StrategyEnabled=[bool]$ctx.EnableStrategy;Session=$session;Cash=$cash;Valuation=$valuation;Holdings=$hold.Rows;TargetQty=$hold.TargetQty;TargetAverage=$hold.TargetAverage;OrdersToday=@($orders);OpenOrdersToday=@($orders|Where-Object {$_.Remaining -gt 0});PriorDay=$session.BusinessDay;PriorOrders=@($prior);PriorUnresolved=@($prior|Where-Object {$_.Remaining -gt 0})}

 }finally{$ctx.CycleStart=$null}

}

function At58-Status($ctx,[string]$state,[string]$code='OK',[string]$api=''){

 $now=At58-Now $ctx

 return [pscustomobject][ordered]@{Schema='AT-DIRECT-STATUS-1';RunId=$ctx.RunId;Version='58.1';Source='MERITZ_DIRECT';At=(At58-Kst $now).ToString('yyyy-MM-dd HH:mm:ss');Utc=$now.ToString('o');State=$state;Code=$code;ApiCode=$api;Stage=$ctx.Stage;Failures=$ctx.Failures;LastSuccessUtc=$ctx.LastSuccess;Calls=$ctx.Calls;Sequence=$ctx.Sequence;ExecutionEnabled=$false;OrdersSent=0;SnapshotAvailable=($null -ne $ctx.Snapshot)}

}

function At58-SaveStatus($ctx,$status){

 $text=$status|ConvertTo-Json -Depth 8 -Compress

 At58-Atomic (Join-Path $ctx.Root 'status.json') $text

 $path=Join-Path $ctx.Root ('read-'+$status.At.Substring(0,10).Replace('-','')+'.jsonl')

 [IO.File]::AppendAllText($path,$text+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))

}

function At58-Cycle($ctx){

 try{

  $snapshot=At58-ReadSnapshot $ctx

  if($ctx.EnableExecutionFeed){$snapshot|Add-Member -NotePropertyName Execution -NotePropertyValue (At58E-Run $ctx $snapshot)}

  if($ctx.EnableStrategy){$flow=At58A-Run $ctx $snapshot;$snapshot|Add-Member Strategy $flow.Strategy;$snapshot|Add-Member Simulation $flow.Simulation}

  if($ctx.EnableStrategy){$snapshot|Add-Member -NotePropertyName Trading -NotePropertyValue (At58T-Run $ctx $snapshot)}

  if($ctx.EnableStrategy){$snapshot|Add-Member -NotePropertyName Readiness -NotePropertyValue (At58C-Run $ctx $snapshot)}

  # Publish a complete encrypted snapshot atomically. Partial responses never replace it.

  At58-Atomic (Join-Path $ctx.Root 'snapshot.dpapi') (At58-Protect ($snapshot|ConvertTo-Json -Depth 14 -Compress))

  $ctx.Snapshot=$snapshot;$ctx.LastSuccess=$snapshot.CompletedUtc;$ctx.Failures=0;$ctx.Sequence++;$ctx.Stage='COMPLETE'

  $state=if($snapshot.Quote.Mode -ceq 'CLOSED_DAILY'){'CLOSED'}else{'READ_OK'}

  $status=At58-Status $ctx $state

  At58-SaveStatus $ctx $status

  return [pscustomobject]@{Ok=$true;Status=$status;Snapshot=$snapshot;RetrySeconds=30}

 }catch{

  $e=At58-Error $_;$ctx.Failures=[math]::Min(100000,$ctx.Failures+1);$ctx.Stage=$e.Stage

  $delay=[int][math]::Min(300,30*[math]::Pow(2,[math]::Min(4,$ctx.Failures-1)))

  $status=At58-Status $ctx 'RETRY' $e.Code $e.Api

  try{At58-SaveStatus $ctx $status}catch{$status.State='STOPPED';$status.Code='LOCAL_IO'}

  return [pscustomobject]@{Ok=$false;Status=$status;Snapshot=$null;RetrySeconds=$delay}

 }

}

function At58-Cache($ctx){

 $path=Join-Path $ctx.Root 'snapshot.dpapi';if(![IO.File]::Exists($path)){return $null}

 try{$r=(At58-Unprotect ([IO.File]::ReadAllText($path)))|ConvertFrom-Json;if($r.Schema -cne 'AT-DIRECT-1' -or $r.Scope -cne $ctx.Scope -or $r.Symbol -cne $ctx.Symbol -or $r.ExecutionEnabled){At58-Fail 'CACHE_IDENTITY'};return $r}catch{return $null}

}



# AT58.5: deterministic strategy and local paper execution. No broker POST is dispatched.

function At58S-Cell($rows,[int]$r,[int]$c){if($null -eq $rows -or $r -ge $rows.Count -or $null -eq $rows[$r] -or $c -ge $rows[$r].Count){return $null};return ,$rows[$r][$c]}

function At58S-Clone($value){return ($value|ConvertTo-Json -Depth 40 -Compress|ConvertFrom-Json)}

function At58S-Utc($value){try{return [datetimeoffset]::Parse([string]$value,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime}catch{At58-Fail 'STRATEGY_TIME' 'STRATEGY'}}

function At58S-SessionTime($value){

 if($value -is [datetime]){if($value.Kind -eq [DateTimeKind]::Utc){return (At58-Kst $value)};if($value.Kind -eq [DateTimeKind]::Local){return (At58-Kst $value.ToUniversalTime())};return $value}

 if([string]$value -match '(Z|[+-]\d\d:\d\d)$'){return (At58-Kst (At58S-Utc $value))}

 try{return [datetime]::Parse([string]$value,[Globalization.CultureInfo]::InvariantCulture)}catch{At58-Fail 'STRATEGY_TIME' 'STRATEGY'}

}

function At58S-Num($v,[decimal]$min=0,[decimal]$max=1000000000000,[bool]$whole=$false){$n=At58-Number $v $whole;if($n -lt $min -or $n -gt $max){At58-Fail 'STRATEGY_INPUT' 'STRATEGY'};return $n}

function At58S-Import($raw){

 if(!$raw -or $raw.Schema -cne 'AT-STRATEGY-INPUT-1' -or $raw.Symbol -cne '0210A0'){At58-Fail 'STRATEGY_INPUT' 'STRATEGY'}

 $p=$raw.Params;$settings=$raw.Settings

 if((At58S-Cell $p 0 0) -cne '항목' -or (At58S-Cell $settings 0 0) -cne '설정 항목' -or (At58S-Cell $settings 1 1) -cne 'KRX:0210A0'){At58-Fail 'STRATEGY_HEADER' 'STRATEGY'}

 $policy=[ordered]@{}

 $fields=[ordered]@{BuyGap=1;SellGap=2;Splits=3;BuyDistance=4;BuyWeightMax=5;BelowSellRatio=6;SellRatio=7;SellDistance=8;SellRatioMax=9;BuyFee=10;MaxBuys=11;SellFee=13}

 foreach($name in $fields.Keys){$policy[$name]=At58S-Num (At58S-Cell $p $fields[$name] 1)}

 foreach($pair in @(@('Principal',19),@('LossStop',20),@('MaxInvest',21),@('ReserveRatio',22),@('Tick',23),@('NextEntry',24))){$policy[$pair[0]]=At58S-Num (At58S-Cell $p $pair[1] 4)}

 if($policy.Splits -ne 30 -or $policy.MaxBuys -ne 3 -or $policy.Tick -ne 5 -or $policy.Principal -le 0 -or $policy.BuyDistance -le 0 -or $policy.SellDistance -le 0 -or $policy.BuyGap -le 0 -or $policy.SellGap -le 0){At58-Fail 'STRATEGY_POLICY' 'STRATEGY'}

 foreach($name in @('BuyGap','SellGap','BelowSellRatio','SellRatio','SellRatioMax','BuyFee','SellFee','ReserveRatio','LossStop','MaxInvest')){if($policy[$name] -ge 1 -and $name -cne 'MaxInvest'){At58-Fail 'STRATEGY_POLICY' 'STRATEGY'};if($policy[$name] -gt 1){At58-Fail 'STRATEGY_POLICY' 'STRATEGY'}}

 $policy.Reinvest=([string](At58S-Cell $settings 3 1) -ceq '사용')

 if((At58S-Cell $settings 3 1) -cnotin @('사용','미사용')){At58-Fail 'STRATEGY_POLICY' 'STRATEGY'}

 $policy.Short=[int](At58S-Num (At58S-Cell $settings 6 1) 2 100 $true);$policy.Long=[int](At58S-Num (At58S-Cell $settings 7 1) 3 200 $true)

 $policy.Shock=At58S-Num (At58S-Cell $settings 23 1) 0.1 10;$policy.VolPeriod=[int](At58S-Num (At58S-Cell $settings 24 1) 2 100 $true)

 if($policy.Short -ge $policy.Long -or $policy.BuyWeightMax -lt 1){At58-Fail 'STRATEGY_POLICY' 'STRATEGY'}

 $regimes=[ordered]@{}

 for($i=0;$i -lt 4;$i++){

  $name=[string](At58S-Cell $p ($i+15) 0)

  if($name -cne @('급등','상승','하락','급락')[$i] -or (At58S-Cell $settings ($i+17) 0) -cne $name){At58-Fail 'STRATEGY_REGIME' 'STRATEGY'}

  $regimes[$name]=[pscustomobject]@{Budget=(At58S-Num (At58S-Cell $p ($i+15) 1) 0 3);BuyGap=(At58S-Num (At58S-Cell $p ($i+15) 2) 0.1 5);SellGap=(At58S-Num (At58S-Cell $p ($i+15) 3) 0.1 5);SellWeight=(At58S-Num (At58S-Cell $p ($i+15) 4) 0 5);BuyEnabled=((At58S-Cell $settings ($i+17) 1) -cin @('모의','허용'))}

 }

 if((At58S-Cell $settings 25 0) -ceq 'AT-NEUTRAL-1'){

  $policy.Neutral=At58N-Import $settings $p

  $regimes['보합']=[pscustomobject]@{Budget=(At58S-Num (At58S-Cell $p 27 1) .1 1);BuyGap=(At58S-Num (At58S-Cell $p 27 2) .5 2);SellGap=(At58S-Num (At58S-Cell $p 27 3) .5 2);SellWeight=(At58S-Num (At58S-Cell $p 27 4) .1 2);BuyEnabled=((At58S-Cell $settings 21 1) -cin @('모의','허용'))}

 }

 $policy.Regimes=[pscustomobject]$regimes

 $cycleRows=New-Object 'Collections.Generic.List[object]'

 for($i=1;$i -lt $raw.Cycles.Count;$i++){if($raw.Cycles[$i].Count -gt 0 -and ([string]$raw.Cycles[$i][0]) -cmatch '^[1-9][0-9]*$'){$cycleRows.Add($raw.Cycles[$i])}}

 $cycles=@($cycleRows.ToArray()|Sort-Object {[int]$_[0]} -Descending)

 if(!$cycles.Count){At58-Fail 'STRATEGY_CYCLE' 'STRATEGY'}

 $c=$cycles[0];if($c.Count -lt 4 -or $c[3] -cne $raw.Symbol -or $c[2] -cnotin @('운영중','다음 사이클 대기')){At58-Fail 'STRATEGY_CYCLE' 'STRATEGY'}

 $cycle=[pscustomobject]@{Id=(At58S-Num $c[0] 1 100000 $true);Basis=(At58S-Num $c[1] 5 10000000);Phase=[string]$c[2]}

 $ledger=At58S-Ledger $raw.Ledger ([pscustomobject]$policy) $raw.Day

 if($cycle.Phase -ceq '다음 사이클 대기' -and $ledger.Qty -ne 0){At58-Fail 'STRATEGY_CYCLE' 'STRATEGY'}

 $canonical=[ordered]@{Policy=[pscustomobject]$policy;Cycle=$cycle;Ledger=$ledger.Rows}

 $priorHash=At58-Hash ($canonical|ConvertTo-Json -Depth 15 -Compress)

 $legacyHash=''

 if($policy.Contains('Neutral')){

  $old=At58S-Clone $canonical;$old.Policy.PSObject.Properties.Remove('Neutral');$old.Policy.Regimes.PSObject.Properties.Remove('보합')

  $legacyHash=At58-Hash ($old|ConvertTo-Json -Depth 15 -Compress)

 }

 if($policy.Contains('Neutral')){$policy.Controls=[pscustomobject][ordered]@{Schema='AT-REGIME-2';DownReserve=.30;DownMaxBuys=1;CrashReserve=.50;CrashCooldownSeconds=300;BuyLossStop=.20;ShockFloor=.01}}

 $canonical.Policy=[pscustomobject]$policy

 return [pscustomobject]@{PriorHash=$priorHash;LegacyHash=$legacyHash;Policy=[pscustomobject]$policy;Cycle=$cycle;Ledger=$ledger;Hash=(At58-Hash ($canonical|ConvertTo-Json -Depth 15 -Compress));Utc=$raw.Utc;Scope=$raw.Scope;Symbol=$raw.Symbol;Day=$raw.Day}

}

function At58S-Ledger($rows,$policy,[string]$day){

 $header=@('날짜','차수','구분(매수/매도)','체결단가','수량','체결금액')

 for($i=0;$i -lt 6;$i++){if((At58S-Cell $rows 0 $i) -cne $header[$i]){At58-Fail 'LEDGER_HEADER' 'STRATEGY'}}

 if($rows.Count -ge 1000){At58-Fail 'LEDGER_LIMIT' 'STRATEGY'}

 $qty=0D;$avg=0D;$cash=[decimal]$policy.Principal;$realized=0D;$held=@{};$last=0D;$blank=$false;$clean=New-Object 'Collections.Generic.List[object]'

 $cutoff=(At58-Day $day).ToOADate()

 for($i=1;$i -lt $rows.Count;$i++){

  $r=$rows[$i];if(@($r|Where-Object {$null -ne $_ -and [string]$_ -ne ''}).Count -eq 0){$blank=$true;continue}

  if($blank -or $r.Count -lt 6){At58-Fail 'LEDGER_GAP' 'STRATEGY'}

  $date=At58S-Num $r[0] 1 $cutoff $true;$stage=[int](At58S-Num $r[1] 1 30 $true);$price=At58S-Num $r[3] 0.00001;$n=At58S-Num $r[4] 1 100000000 $true;$amount=At58S-Num $r[5] 0.00001

  if($date -lt $last -or [math]::Abs($amount-$price*$n) -gt 0.01){At58-Fail 'LEDGER_VALUE' 'STRATEGY'};$last=$date

  switch -CaseSensitive ([string]$r[2]){

   '매수'{if($held.ContainsKey($stage)){At58-Fail 'LEDGER_STAGE' 'STRATEGY'};$held[$stage]=$true;$avg=($qty*$avg+$amount)/($qty+$n);$qty+=$n;$cash-=$amount}

   '매도'{if(!$held.ContainsKey($stage) -or $n -gt $qty){At58-Fail 'LEDGER_STAGE' 'STRATEGY'};$held.Remove($stage);$qty-=$n;$cash+=$amount;$realized+=$amount-$avg*$n;if($qty -eq 0){$avg=0D}}

   default{At58-Fail 'LEDGER_SIDE' 'STRATEGY'}

  }

  $clean.Add([pscustomobject]@{Day=([datetime]::FromOADate([double]$date).ToString('yyyyMMdd'));Stage=$stage;Side=[string]$r[2];Price=$price;Qty=$n;Amount=$amount})

 }

 if($cash -lt 0 -or ($qty -gt 0 -and !$held.Count) -or ($qty -eq 0 -and $held.Count)){At58-Fail 'LEDGER_BALANCE' 'STRATEGY'}

 return [pscustomobject]@{Rows=$clean.ToArray();Qty=$qty;Average=$avg;Cash=$cash;Realized=$realized;Held=@($held.Keys|Sort-Object)}

}

# Range regime: closed daily prices only; the live quote is a breakout/entry gate.

function At58N-Import($settings,$params){

 $labels=@('보합 계산 기간','보합 추세효율 상한','보합 평균이격 배수','보합 매수구간','보합 매도구간','보합 일일 매수한도','보합 현금 유지비율','보합 비용 안전여유','보합 밴드 배수')

 $keys=@('Period','EfficiencyMax','MeanGapSigma','BuyZone','SellZone','MaxBuys','ReserveRatio','MinEdge','BandSigma')

 $min=@(10,0.01,0.01,0.05,0.55,1,0.05,0.001,1);$max=@(60,0.5,1,0.45,0.95,3,0.9,0.05,3)

 $n=[ordered]@{Schema='AT-NEUTRAL-1'}

 for($i=0;$i -lt $keys.Count;$i++){

  if((At58S-Cell $settings (26+$i) 0) -cne $labels[$i]){At58-Fail 'NEUTRAL_SETTINGS' 'STRATEGY'}

  $n[$keys[$i]]=At58S-Num (At58S-Cell $settings (26+$i) 1) $min[$i] $max[$i] ($keys[$i] -cin @('Period','MaxBuys'))

 }

 if((At58S-Cell $settings 21 0) -cne '보합' -or (At58S-Cell $settings 21 1) -cnotin @('모의','허용','중단') -or (At58S-Cell $params 27 0) -cne '보합'){At58-Fail 'NEUTRAL_SETTINGS' 'STRATEGY'}

 return [pscustomobject]$n

}

function At58N-Range($prices,$policy,[decimal]$short,[decimal]$long,$snapshot){

 $n=$policy.Neutral;$count=[int]$n.Period

 if($prices.Count -lt $count+1){At58-Fail 'MARKET_HISTORY_SHORT' 'STRATEGY'}

 $path=0D;for($i=$prices.Count-$count;$i -lt $prices.Count;$i++){$path+=[math]::Abs($prices[$i]-$prices[$i-1])}

 # A motionless history has no usable trading range; ER=0 is only a display convention.

 $er=if($path -gt 0){[math]::Abs($prices[-1]-$prices[$prices.Count-$count-1])/$path}else{0D}

 $window=@($prices|Select-Object -Last $count);$mean=0D;foreach($v in $window){$mean+=$v};$mean/=$count

 $variance=0D;foreach($v in $window){$variance+=($v-$mean)*($v-$mean)}

 $sigma=[decimal][math]::Sqrt([double]($variance/$count));$lower=$mean-$n.BandSigma*$sigma;$upper=$mean+$n.BandSigma*$sigma

 $width=$upper-$lower;$price=[decimal]$snapshot.Quote.Price

 $inside=($price -ge $lower -and $price -le $upper)

 $weak=($er -le $n.EfficiencyMax -and [math]::Abs($short-$long) -le $sigma*$n.MeanGapSigma)

 return [pscustomobject]@{Schema='AT-NEUTRAL-RANGE-1';SnapshotUtc=$snapshot.CompletedUtc;BasisDay=$snapshot.Quote.BasisDay;Efficiency=$er;Mean=$mean;Sigma=$sigma;Lower=$lower;Upper=$upper;BuyCeiling=($lower+$width*$n.BuyZone);SellFloor=($lower+$width*$n.SellZone);Inside=$inside;Weak=$weak;Usable=($lower -gt 0 -and $width -ge 4*$policy.Tick);Name=''}

}

function At58N-Allow($policy,$snapshot,[string]$side,[decimal]$price){

 $e=At58-Value $snapshot 'MarketContext';$n=At58-Value $policy 'Neutral'

 if(!$n -or !$e -or $e.Schema -cne 'AT-NEUTRAL-RANGE-1' -or $e.SnapshotUtc -cne $snapshot.CompletedUtc -or $e.BasisDay -cne $snapshot.Quote.BasisDay -or $e.Name -cne '보합' -or !$e.Usable -or !$e.Inside){return $false}

 if($price -lt $e.Lower -or $price -gt $e.Upper){return $false}

 if($side -ceq '매수'){

  if(!$policy.Regimes.'보합'.BuyEnabled){return $false}

  if($price -gt $e.BuyCeiling){return $false}

  $exit=[math]::Floor($e.SellFloor/$policy.Tick)*$policy.Tick

  $edge=$exit*(1-$policy.SellFee)/($price*(1+$policy.BuyFee))-1

  return ($edge -ge $n.MinEdge)

 }

 return ($price -ge $e.SellFloor)

}



function At58S-Market($rows,$snapshot,$policy){

 $basis=[string]$snapshot.Quote.BasisDay;$map=@{}

 foreach($row in $rows){

  $day=[string](At58-Value $row 'date');$null=At58-Day $day;$price=At58S-Num (At58-Value $row 'stck_clpr') 0.00001

  if($day -gt $snapshot.Day){At58-Fail 'MARKET_DATE' 'STRATEGY'}

  if($day -ge $basis){continue};if($map.ContainsKey($day) -and $map[$day] -ne $price){At58-Fail 'MARKET_DUPLICATE' 'STRATEGY'};$map[$day]=$price

 }

 $keys=@($map.Keys|Sort-Object);$needed=[math]::Max([int]$policy.Long-1,[int]$policy.VolPeriod+1)

 if($keys.Count -lt $needed){At58-Fail 'MARKET_HISTORY_SHORT' 'STRATEGY'}

 $expected=if($snapshot.Session.Live){[string](At58-Value $snapshot.Session 'PreviousDay')}else{''}

 if($expected -and $keys[-1] -cne $expected){At58-Fail 'MARKET_HISTORY_STALE' 'STRATEGY'}

 $prices=@(foreach($key in $keys){[decimal]$map[$key]});$returns=@(for($i=$prices.Count-[int]$policy.VolPeriod;$i -lt $prices.Count;$i++){($prices[$i]/$prices[$i-1])-1D})

 $mean=($returns|Measure-Object -Average).Average;$sum=0D;foreach($value in $returns){$sum+=([decimal]$value-[decimal]$mean)*([decimal]$value-[decimal]$mean)}

 $vol=[math]::Sqrt([double]($sum/($returns.Count-1)));if($vol -le 0 -and !(At58-Value $policy 'Neutral')){At58-Fail 'MARKET_VOLATILITY' 'STRATEGY'}

 $series=@($prices)+@([decimal]$snapshot.Quote.Price);$short=0D;$long=0D

 for($i=1;$i -le $policy.Long;$i++){$long+=$series[$series.Count-$i];if($i -le $policy.Short){$short+=$series[$series.Count-$i]}}

 $short/=$policy.Short;$long/=$policy.Long;$change=[decimal]$snapshot.Quote.Price/$prices[-1]-1D

 $e=$null

 if(At58-Value $policy 'Neutral'){

  $history=if(!$snapshot.Session.Live -and $snapshot.Quote.Mode -ceq 'CLOSED_DAILY'){$series}else{$prices}

  $e=At58N-Range $history $policy $short $long $snapshot

 }

 $shock=if($e){[math]::Max([decimal]$policy.Shock*[decimal]$vol,$policy.Tick/$prices[-1])}else{$policy.Shock*$vol}

 if(At58R-Enabled $policy){$shock=[math]::Max($shock,$policy.Controls.ShockFloor)}

 $upShock=($change -ge $shock -and (!(At58R-Enabled $policy) -or $short -ge $long))

 $name=if($upShock){'급등'}elseif($change -le -$shock){'급락'}elseif($e -and $e.Weak -and $e.Inside){'보합'}elseif($e -and $snapshot.Quote.Price -lt $e.Lower){'하락'}elseif($e -and $snapshot.Quote.Price -gt $e.Upper){'상승'}elseif($short -ge $long){'상승'}else{'하락'}

 if($e){$e.Name=$name;$e|Add-Member Trend $(if($short -ge $long){'상승'}else{'하락'}) -Force;$snapshot|Add-Member MarketContext $e -Force}

 return [pscustomobject]@{Name=$name;Short=$short;Long=$long;Change=$change;Volatility=$vol;PreviousDay=$keys[-1];BasisDay=$basis}

}

# Meritz /market/v1/prices supplies the actual daily limits (mxpr/llam).
# No guessed percentage of the last trade is used. A missing pair may only be
# used by legacy paper fixtures; the live send gate requires validated limits.
function At58O-PriceBounds($quote,[bool]$required=$false){
 $upper=At58-Value $quote 'UpperLimit';$lower=At58-Value $quote 'LowerLimit'
 if($null -eq $upper -and $null -eq $lower -and !$required){return $null}
 try{$upper=At58-Number $upper $true;$lower=At58-Number $lower $true;$current=At58-Number $quote.Price $true}catch{At58-Fail 'TRADE_PRICE_LIMITS' 'TRADING'}
 if($lower -le 0 -or $upper -lt $lower -or $lower%5 -ne 0 -or $upper%5 -ne 0 -or $current -lt $lower -or $current -gt $upper){At58-Fail 'TRADE_PRICE_LIMITS' 'TRADING'}
 return [pscustomobject]@{Upper=$upper;Lower=$lower}
}
function At58O-BuyLimit([decimal]$target,$quote){
 $bounds=At58O-PriceBounds $quote
 if(!$bounds){return $target}
 if($target -lt $bounds.Lower){return 0D}
 return [math]::Min($target,$bounds.Upper)
}
function At58O-CheckPrice($intent,$quote){
 $bounds=At58O-PriceBounds $quote $true
 if($intent.Price -lt $bounds.Lower -or $intent.Price -gt $bounds.Upper){At58-Fail 'TRADE_PRICE_LIMIT' 'TRADING'}
}

function At58S-Plan($source,$portfolio,$snapshot,[string]$market){

 $p=$source.Policy;$v2=At58R-Enabled $p;$risk=At58R-Risk $p $market $snapshot;$regime=At58-Value $p.Regimes $market;if(!$regime){At58-Fail 'STRATEGY_REGIME' 'STRATEGY'}

 $qty=[decimal]$portfolio.Qty;$avg=[decimal]$portfolio.Average;$cash=[decimal]$portfolio.Cash;$tick=[decimal]$p.Tick;$current=[decimal]$snapshot.Quote.Price

 $budget=[decimal]$p.Principal+$(if($p.Reinvest){[decimal]$portfolio.Realized}else{0D})

 $neutral=($market -ceq '보합');$neutralBuy=$true;$neutralSell=$true;$reserveRatio=[decimal]$risk.Reserve;$maxBuys=[int]$risk.MaxBuys

 if($neutral){

  if(!(At58-Value $p 'Neutral')){At58-Fail 'NEUTRAL_SETTINGS' 'STRATEGY'}

  $neutralBuy=At58N-Allow $p $snapshot '매수' $current;$neutralSell=At58N-Allow $p $snapshot '매도' $current

  $reserveRatio=[math]::Max($reserveRatio,$p.Neutral.ReserveRatio);$maxBuys=[math]::Min($maxBuys,$p.Neutral.MaxBuys)

 }

 $dailyStages=At58-Value $portfolio 'DailyStages';if($dailyStages){$maxBuys=$dailyStages.Limit}
 $held=@($portfolio.Held);$remaining=if($dailyStages){$dailyStages.NewStageSlots}else{[math]::Max(0,$maxBuys-[int]$portfolio.BuyCount)}

 $reserveBuy=0D;$reserveSell=0D

 foreach($o in @($portfolio.Orders|Where-Object {$_.State -cin @('ACKNOWLEDGED','PARTIAL','CANCEL_PENDING','UNKNOWN','SUBMITTING')})){

  $left=[decimal]$o.Qty-[decimal]$o.Filled;if($o.Side -ceq '매수'){$reserveBuy+=$left*$o.Price+[math]::Ceiling($left*$o.Price*$p.BuyFee)}else{$reserveSell+=$left}

 }

 $riskStop=($risk.Paused -or $cash+$qty*$current -le $p.Principal*(1-$risk.LossStop));$rows=New-Object 'Collections.Generic.List[object]';$weightTotal=0D;$previous=0D

 for($stage=1;$stage -le 30;$stage++){

  $bp=if($stage -eq 1){if($source.Cycle.Phase -ceq '다음 사이클 대기' -and $p.NextEntry -gt 0){$p.NextEntry}else{$source.Cycle.Basis}}else{[math]::Round(($previous*(1-$p.BuyGap*$regime.BuyGap))/$tick,0,[MidpointRounding]::AwayFromZero)*$tick}

  if($v2 -and $neutral -and $stage -eq 1 -and $source.Cycle.Phase -ceq '다음 사이클 대기'){$e=At58-Value $snapshot 'MarketContext';if($e){$bp=[math]::Floor($e.BuyCeiling/$tick)*$tick}}

  if($bp -le 0){At58-Fail 'STRATEGY_PRICE' 'STRATEGY'};$previous=$bp

  $sp=[math]::Ceiling($bp*(1+$p.SellGap*$regime.SellGap)/$tick)*$tick

  if($v2 -and $stage -in $held){$anchor=At58-Value (At58-Value $portfolio 'Anchors') ([string]$stage);if(!$anchor){At58-Fail 'STRATEGY_ANCHOR' 'STRATEGY'};$bp=[decimal]$anchor.Entry;$sp=[decimal]$anchor.SellPrice}

  $weight=if($stage -in $held -or !$regime.BuyEnabled){0D}else{$budget/$p.Splits*$(if($avg -gt 0){[math]::Min([decimal]$p.BuyWeightMax,1D+[math]::Max(0D,1D-$bp/$avg)/$p.BuyDistance)}else{1D})*$(if($neutral -or $v2){1D}else{$regime.Budget})}

  $weightTotal+=$weight;$rows.Add([pscustomobject]@{Stage=$stage;BuyPrice=$bp;BuyQty=0D;SellPrice=$sp;SellQty=0D;Held=($stage -in $held);Weight=$weight})

 }

 $available=[math]::Max(0D,[math]::Min([decimal]$snapshot.Cash.Orderable,[math]::Min($cash-$reserveBuy-$p.Principal*$reserveRatio,[math]::Min($budget*$p.MaxInvest-$qty*$avg,$weightTotal))))

 if($neutral -or $v2){$fundLimit=[math]::Max(0D,[math]::Min([decimal]$snapshot.Cash.Orderable,[math]::Min($cash-$reserveBuy-$p.Principal*$reserveRatio,$budget*$p.MaxInvest-$qty*$avg)));$available=[math]::Min($fundLimit,$available*$regime.Budget)}

 $allocatedSell=0D

 for($i=29;$i -ge 0;$i--){

  $r=$rows[$i]

  if($r.Held){

   $unallocated=[math]::Max(0,$qty-$reserveSell-$allocatedSell)

   if($r.Stage -eq 1){$r.SellQty=$unallocated}else{$ratio=if($r.SellPrice -lt $avg){$p.BelowSellRatio}else{if($avg -le 0){At58-Fail 'STRATEGY_AVERAGE' 'STRATEGY'};[math]::Min($p.SellRatioMax,$p.SellRatio*(1+($r.SellPrice/$avg-1)/$p.SellDistance)*$regime.SellWeight)};$r.SellQty=[math]::Floor($unallocated*$ratio)}

   if($v2 -and $r.Stage -ne 1 -and $ratio -gt 0 -and $unallocated -gt 1){$r.SellQty=[math]::Min($unallocated-1,[math]::Max(1,$r.SellQty))}

   $allocatedSell+=$r.SellQty

  }elseif(!$riskStop -and $(if($dailyStages){At58D-Allow $dailyStages $r.Stage}else{$remaining -gt 0}) -and $weightTotal -gt 0 -and ($source.Cycle.Phase -cne '다음 사이클 대기' -or $r.Stage -eq 1)){

   $alloc=$available*$r.Weight/$weightTotal;$n=[math]::Floor($alloc/($r.BuyPrice*(1+$p.BuyFee)));if($n*$r.BuyPrice+[math]::Ceiling($n*$r.BuyPrice*$p.BuyFee) -gt $alloc){$n--};$r.BuyQty=[math]::Max(0,$n)

  }

 }

 $buy=@($rows|Where-Object {!$_.Held}|Select-Object -First 1);$sell=@($rows|Where-Object {$_.Held -and (!$v2 -or $_.SellQty -gt 0)}|Select-Object -Last 1)

 $candidate=@();$active=@($portfolio.Orders|Where-Object {$_.State -cin @('ACKNOWLEDGED','PARTIAL','SUBMITTING','UNKNOWN','CANCEL_PENDING')})

 if(!$active.Count){

  if($neutralSell -and $sell.Count -and $sell[0].SellQty -gt 0 -and $current -ge $sell[0].SellPrice){$candidate+=,[pscustomobject]@{Side='매도';Stage=$sell[0].Stage;Target=$sell[0].SellPrice;Price=([math]::Ceiling([math]::Max($current,$sell[0].SellPrice)/$tick)*$tick);Qty=$sell[0].SellQty}}

  if($neutralBuy -and $buy.Count -and $buy[0].BuyQty -gt 0 -and $(if($source.Cycle.Phase -ceq '다음 사이클 대기' -and !($v2 -and $neutral)){$current -ge $buy[0].BuyPrice}else{$current -le $buy[0].BuyPrice})){

   # Use the selected regime table price for the limit buy; fills retain broker prices.
   $r=$buy[0];$price=At58O-BuyLimit $r.BuyPrice $snapshot.Quote;if($source.Cycle.Phase -ceq '다음 사이클 대기' -and !($v2 -and $neutral)){$price=[math]::Floor($current/$tick)*$tick}

   if($price -le 0){At58-Fail 'TRADE_PRICE_LIMIT' 'TRADING'}

   $cap=[math]::Min($r.BuyQty*$r.BuyPrice+[math]::Ceiling($r.BuyQty*$r.BuyPrice*$p.BuyFee),[math]::Min([decimal]$snapshot.Cash.Orderable,$cash-$reserveBuy));$n=[math]::Min($r.BuyQty,[math]::Floor($cap/($price*(1+$p.BuyFee))));if($n*$price+[math]::Ceiling($n*$price*$p.BuyFee) -gt $cap){$n--}

   if($n -gt 0){$candidate+=,[pscustomobject]@{Side='매수';Stage=$r.Stage;Target=$r.BuyPrice;Price=$price;Qty=$n}}

  }

 }

 if($candidate.Count -gt 1){if($v2){$candidate=@($candidate|Where-Object {$_.Side -ceq '매도'})}else{At58-Fail 'STRATEGY_OVERLAP' 'STRATEGY'}}

 return [pscustomobject]@{LossStop=$risk.LossStop;RiskPaused=$risk.Paused;Rows=$rows.ToArray();Candidate=$candidate;RemainingBuys=$remaining;BuyStopped=($riskStop -or !$neutralBuy);NeutralBuyAllowed=$neutralBuy;NeutralSellAllowed=$neutralSell;ReserveRatio=$reserveRatio;MaxBuys=$maxBuys;NextBuy=$(if($buy.Count){$buy[0]}else{$null});NextSell=$(if($sell.Count){$sell[0]}else{$null});ReserveBuy=$reserveBuy;ReserveSell=$reserveSell}

}



function At58S-Reconcile($source,$s){

 if($source.Scope -cne $s.Scope -or $source.Symbol -cne $s.Symbol -or $source.Day -cne $s.Day){At58-Fail 'STRATEGY_IDENTITY' 'STRATEGY'}

 if($source.Ledger.Qty -ne $s.TargetQty -or [math]::Abs([decimal]$source.Ledger.Average-[decimal]$s.TargetAverage) -gt 1){At58-Fail 'ACCOUNT_LEDGER_MISMATCH' 'STRATEGY'}

 $orders=@($s.OrdersToday|Where-Object {$_.Symbol -ceq $s.Symbol})

 if(@($orders|Where-Object {$_.Kind -cne '1' -or $_.Original -notin @('','0')}).Count){At58-Fail 'ORDER_CHAIN_REVIEW' 'STRATEGY'}

 foreach($pair in @(@('2','매수'),@('1','매도'))){

  $api=0D;foreach($o in @($orders|Where-Object {$_.Side -ceq $pair[0]})){$api+=[decimal]$o.Filled}

  $book=0D;foreach($r in @($source.Ledger.Rows|Where-Object {$_.Day -ceq $s.Day -and $_.Side -ceq $pair[1]})){$book+=[decimal]$r.Qty}

  if($api -ne $book){At58-Fail 'TODAY_FILL_MISMATCH' 'STRATEGY'}

 }

 return (At58-Hash ((@($source.Hash,$s.Scope,$s.Day,$s.TargetQty,$s.TargetAverage,($orders|ConvertTo-Json -Depth 8 -Compress))) -join '|'))

}

function At58S-NewPaper($source,$s){

 return [pscustomobject][ordered]@{Schema='AT-PAPER-1';Mode='PAPER';Scope=$s.Scope;Symbol=$s.Symbol;SourceHash=$source.Hash;Anchors=(At58R-SeedAnchors $source);InitialQty=[decimal]$s.TargetQty;InitialAverage=[decimal]$s.TargetAverage;InitialCash=[decimal]$source.Ledger.Cash;InitialRealized=[decimal]$source.Ledger.Realized;Qty=[decimal]$s.TargetQty;Average=[decimal]$s.TargetAverage;Cash=[decimal]$source.Ledger.Cash;Realized=[decimal]$source.Ledger.Realized;Held=@($source.Ledger.Held);Orders=@();Fills=@();Revision=0;LastUtc='';LastDay='';LastVolume=0D;LastRunId='';Market='';MarketCandidate='';MarketCandidateUtc='';Cycle=$source.Cycle;BuyCount=0}

}

function At58S-ValidatePaper($state,$source,$s){

 if(!$state -or $state.Schema -cne 'AT-PAPER-1' -or $state.Mode -cne 'PAPER' -or $state.Scope -cne $s.Scope -or $state.Symbol -cne $s.Symbol){At58-Fail 'PAPER_IDENTITY' 'STRATEGY'}

 if($state.SourceHash -cne $source.Hash){

  if(!(At58R-Migrate $source $state.SourceHash)){At58-Fail 'PAPER_SOURCE_CHANGED' 'STRATEGY'}

  At58S-CancelPaper $state 'NEUTRAL_POLICY_UPGRADE';$state.SourceHash=$source.Hash;$state.LastRunId=''

 }

 At58R-PaperAnchors $state $source

 if(@($state.Orders).Count -gt 10000 -or @($state.Fills).Count -gt 50000){At58-Fail 'PAPER_LIMIT' 'STRATEGY'}

 $qty=[decimal]$state.InitialQty;$cash=[decimal]$state.InitialCash;$avg=[decimal]$state.InitialAverage;$realized=[decimal]$state.InitialRealized;$ids=@{};$orderIds=@{}

 foreach($o in @($state.Orders)){

  if($orderIds.ContainsKey([string]$o.Id) -or $o.Id -cnotmatch '^PAPER-[a-f0-9]{24}$' -or $o.Side -cnotin @('매수','매도') -or $o.State -cnotin @('ACKNOWLEDGED','PARTIAL','FILLED','CANCELLED','EXPIRED')){At58-Fail 'PAPER_ORDER' 'STRATEGY'}

  $orderIds[[string]$o.Id]=$o;$null=At58S-Num $o.Qty 1 100000000 $true;$null=At58S-Num $o.Filled 0 $o.Qty $true;$null=At58S-Num $o.Amount;$null=At58S-Num $o.Fee

 }

 $totals=@{}

 foreach($f in @($state.Fills)){

  if($ids.ContainsKey([string]$f.Key) -or !$orderIds.ContainsKey([string]$f.OrderId)){At58-Fail 'PAPER_FILL' 'STRATEGY'};$ids[[string]$f.Key]=$true

  $n=At58S-Num $f.Qty 1 100000000 $true;$amount=At58S-Num $f.Amount 0.00001;$fee=At58S-Num $f.Fee

  $o=$orderIds[[string]$f.OrderId];if($f.Side -cne $o.Side -or $f.Stage -ne $o.Stage -or [math]::Abs($amount-$n*[decimal]$f.Price) -gt 0.01){At58-Fail 'PAPER_FILL' 'STRATEGY'}

  if(!$totals.ContainsKey([string]$o.Id)){$totals[[string]$o.Id]=@{Qty=0D;Amount=0D;Fee=0D}};$t=$totals[[string]$o.Id];$t.Qty+=$n;$t.Amount+=$amount;$t.Fee+=$fee

  if($f.Side -ceq '매수'){$avg=($qty*$avg+$amount)/($qty+$n);$qty+=$n;$cash-=$amount+$fee}else{$realized+=$amount-$n*$avg-$fee;$qty-=$n;$cash+=$amount-$fee;if($qty -eq 0){$avg=0D}};if($qty -lt 0 -or $cash -lt 0){At58-Fail 'PAPER_BALANCE' 'STRATEGY'}

 }

 foreach($o in @($state.Orders)){$t=$totals[[string]$o.Id];if(!$t){$t=@{Qty=0D;Amount=0D;Fee=0D}};if($o.Filled -ne $t.Qty -or $o.Amount -ne $t.Amount -or $o.Fee -ne $t.Fee){At58-Fail 'PAPER_TOTALS' 'STRATEGY'}}

 if($qty -ne $state.Qty -or [math]::Abs($cash-[decimal]$state.Cash) -gt 0.01 -or [math]::Abs($avg-[decimal]$state.Average) -gt 0.00001 -or [math]::Abs($realized-[decimal]$state.Realized) -gt 0.01){At58-Fail 'PAPER_BALANCE' 'STRATEGY'}

}

function At58S-PaperFill($state,$o,[decimal]$qty,[decimal]$price,$source,[string]$utc){

 if($qty -le 0 -or $qty -gt ([decimal]$o.Qty-[decimal]$o.Filled) -or $qty -ne [decimal]::Truncate($qty)){At58-Fail 'PAPER_FILL_QTY' 'STRATEGY'}

 $amount=$qty*$price;$rate=if($o.Side -ceq '매수'){$source.Policy.BuyFee}else{$source.Policy.SellFee};$fee=[math]::Ceiling(($o.Amount+$amount)*$rate)-[decimal]$o.Fee

 if($o.Side -ceq '매수'){

  if($state.Cash -lt $amount+$fee){At58-Fail 'PAPER_CASH' 'STRATEGY'}

  $state.Average=($state.Qty*$state.Average+$amount)/($state.Qty+$qty);$state.Qty+=$qty;$state.Cash-=$amount+$fee

  if($o.Stage -notin @($state.Held)){$state.Held=@($state.Held)+@([int]$o.Stage)}

  if($o.Stage -eq 1 -and $state.Cycle.Phase -ceq '다음 사이클 대기'){$state.Cycle.Id++;$state.Cycle.Basis=$price;$state.Cycle.Phase='운영중'}

 }else{

  if($state.Qty -lt $qty){At58-Fail 'PAPER_POSITION' 'STRATEGY'}

  $state.Realized+=$amount-$qty*$state.Average-$fee;$state.Qty-=$qty;$state.Cash+=$amount-$fee;if($state.Qty -eq 0){$state.Average=0D}

 }

 $o.Filled+=$qty;$o.Amount+=$amount;$o.Fee+=$fee;$o.State=if($o.Filled -eq $o.Qty){'FILLED'}else{'PARTIAL'}

 $state.Fills+=,[pscustomobject]@{Key=($o.Id+'|'+$o.Filled);OrderId=$o.Id;Day=$o.Day;Utc=$utc;Side=$o.Side;Stage=$o.Stage;Price=$price;Qty=$qty;Amount=$amount;Fee=$fee;Evidence='PAPER_QUOTE_VOLUME_ESTIMATE'}

 if($o.State -ceq 'FILLED'){

  if($o.Side -ceq '매도'){$state.Held=@($state.Held|Where-Object {$_ -ne $o.Stage});if($o.Stage -eq 1){if($state.Qty -ne 0){At58-Fail 'PAPER_CYCLE_BALANCE' 'STRATEGY'};$state.Cycle.Phase='다음 사이클 대기';$state.Cycle.Basis=$o.Amount/$o.Filled;if(At58R-Enabled $source.Policy){$state.Held=@()}}}

  elseif($o.Stage -eq 1 -and $state.Cycle.Phase -ceq '다음 사이클 대기'){$state.Cycle.Id++;$state.Cycle.Basis=$o.Amount/$o.Filled;$state.Cycle.Phase='운영중'}

 }

}

function At58S-CancelPaper($state,[string]$reason){

 foreach($o in @($state.Orders|Where-Object {$_.State -cin @('ACKNOWLEDGED','PARTIAL')})){

  $o.State=if($reason -ceq 'DAY_CHANGE'){'EXPIRED'}else{'CANCELLED'};$o.EndReason=$reason

  if($o.Side -ceq '매도' -and $o.Filled -gt 0 -and ($o.Stage -ne 1 -or $state.Qty -eq 0)){$state.Held=@($state.Held|Where-Object {$_ -ne $o.Stage})}

 }

}

function At58S-PaperStep($state,$source,$s,$market,[datetime]$now,[string]$runId,[bool]$ready){

 $next=At58S-Clone $state;$s=At58R-Pause $next $source $s $market.Name;At58R-PaperAnchors $next $source;$utc=$s.CompletedUtc;$stamp=At58S-Utc $utc;$kst=At58-Kst $now

 if($next.LastUtc -and $stamp -le (At58S-Utc $next.LastUtc)){return [pscustomobject]@{State=$next;Code='PAPER_DUPLICATE';Plan=$null}}

 $live=($s.Session.Live -and $s.Quote.Mode -ceq 'LIVE_REST' -and $s.Quote.BasisDay -ceq $s.Day -and $s.Day -ceq $kst.ToString('yyyyMMdd'))

 $volume=At58-Value $s.Quote 'Volume';$tick=At58-Value $s.Quote 'Tick';$delta=0D

 $continuity=($next.LastUtc -and $next.LastRunId -ceq $runId -and $next.LastDay -ceq $s.Day -and ($stamp-(At58S-Utc $next.LastUtc)).TotalSeconds -le 90)

 if($null -ne $volume){$volume=At58S-Num $volume 0 1000000000000 $true;if($continuity -and $volume -ge $next.LastVolume){$delta=$volume-$next.LastVolume}}

 $code='PAPER_WAIT';$marketStable=$true

 if(!$next.Market){$next.Market=$market.Name}

 elseif($next.Market -cne $market.Name){

  $marketStable=$false

  if($next.MarketCandidate -cne $market.Name){$next.MarketCandidate=$market.Name;$next.MarketCandidateUtc=$utc}

  elseif(($stamp-(At58S-Utc $next.MarketCandidateUtc)).TotalSeconds -ge 30){At58S-CancelPaper $next 'REGIME_CHANGE';$next.Market=$market.Name;$next.MarketCandidate='';$marketStable=$true}

 }else{$next.MarketCandidate='';$next.MarketCandidateUtc=''}

 if($next.LastDay -and $next.LastDay -cne $s.Day){At58S-CancelPaper $next 'DAY_CHANGE'}

 $foreign=@($s.OpenOrdersToday|Where-Object {$_.Symbol -ceq $s.Symbol});$prior=@($s.PriorUnresolved|Where-Object {$_.Symbol -ceq $s.Symbol})

 $cutoff=$false;if($live){$cutoff=($kst -ge (At58S-SessionTime $s.Session.Close).AddMinutes(-3))}

 $fresh=(($now-$stamp).TotalSeconds -ge 0 -and ($now-$stamp).TotalSeconds -le 20 -and ($now-(At58S-Utc $s.Quote.ReceivedUtc)).TotalSeconds -le 30)

 if(!$live){At58S-CancelPaper $next 'SESSION_CLOSED';$code='MARKET_CLOSED'}

 elseif($cutoff){At58S-CancelPaper $next 'PRE_CLOSE';$code='PRE_CLOSE'}

 elseif(!$ready){$code='RECONCILE_WAIT'}

 elseif(!$fresh){$code='STRATEGY_STALE'}

 elseif($foreign.Count -or $prior.Count){At58S-CancelPaper $next 'EXTERNAL_ORDER';$code='EXTERNAL_ORDER'}

 elseif(!$marketStable){$code='MARKET_CONFIRM_WAIT'}

 elseif($null -eq $volume -or $null -eq $tick -or $tick -ne $source.Policy.Tick){$code='QUOTE_DETAIL_WAIT'}

 else{

  if($continuity -and $delta -gt 0){

   foreach($o in @($next.Orders|Where-Object {$_.State -cin @('ACKNOWLEDGED','PARTIAL')})){

    if($o.Day -cne $s.Day -or (At58S-Utc $o.CreatedUtc) -ge (At58S-Utc $s.Quote.ReceivedUtc)){continue}

    $cross=if($o.Side -ceq '매수'){$s.Quote.Price -le $o.Price}else{$s.Quote.Price -ge $o.Price}

    if($cross){$n=[math]::Min($o.Qty-$o.Filled,$delta);if($n -gt 0){At58S-PaperFill $next $o $n ([decimal]$o.Price) $source $utc;$delta-=$n}}

   }

  }

 }

 $manualBuys=@($source.Ledger.Rows|Where-Object {$_.Day -ceq $s.Day -and $_.Side -ceq '매수'}).Count

 $paperBuys=@($next.Orders|Where-Object {$_.Day -ceq $s.Day -and $_.Side -ceq '매수' -and ($_.Filled -gt 0 -or $_.State -cin @('ACKNOWLEDGED','PARTIAL'))}).Count

 $next.BuyCount=$manualBuys+$paperBuys

 $effective=[pscustomobject]@{Policy=$source.Policy;Cycle=$next.Cycle}

 At58R-PaperAnchors $next $source

 $plan=At58S-Plan $effective $next $s $next.Market

 if((At58R-Enabled $source.Policy) -and $plan.BuyStopped){foreach($o in @($next.Orders|Where-Object {$_.Side -ceq '매수' -and $_.State -cin @('ACKNOWLEDGED','PARTIAL')})){$o.State='CANCELLED';$o.EndReason='RISK_BUY_STOP'}}

 if($code -ceq 'PAPER_WAIT' -and $plan.Candidate.Count){

  $c=$plan.Candidate[0];$next.Revision++;$id='PAPER-'+(At58-Hash ($s.Scope+'|'+$source.Hash+'|'+$next.Cycle.Id+'|'+$next.Revision+'|'+$s.Day+'|'+$c.Side+'|'+$c.Stage)).Substring(0,24)

  $next.Orders+=,[pscustomobject]@{Id=$id;Day=$s.Day;Side=$c.Side;Stage=$c.Stage;Target=$c.Target;Price=$c.Price;Qty=$c.Qty;Filled=0D;Amount=0D;Fee=0D;State='ACKNOWLEDGED';CreatedUtc=$utc;ExitGap=($source.Policy.SellGap*$source.Policy.Regimes.($next.Market).SellGap);EndReason='';Mode='PAPER'};$code='PAPER_ORDER'

 }

 $next.LastUtc=$utc;$next.LastDay=$s.Day;$next.LastRunId=$runId;$next.LastVolume=if($null -eq $volume){0D}else{$volume}

 At58S-ValidatePaper $next $source $s

 return [pscustomobject]@{State=$next;Code=$code;Plan=$plan}

}

function At58S-Message([string]$code){

 $labels=@{MARKET_CLOSED='장외 대기 · 모의 주문 없음';PRE_CLOSE='마감 3분 전 · 모의 잔량 취소';RECONCILE_WAIT='계좌·기록 연속 대조 중';PAPER_WAIT='모의 운용 · 조건 대기';PAPER_ORDER='모의 주문 접수';PAPER_DUPLICATE='동일 조회 결과 · 중복 처리 안 함';MARKET_CONFIRM_WAIT='시장 전환 30초 확인 중';QUOTE_DETAIL_WAIT='호가단위·거래량 확인 대기';STRATEGY_STALE='오래된 시세 · 모의 처리 중단';EXTERNAL_ORDER='기존 계좌 주문 확인 필요';STRATEGY_INPUT_WAIT='전략·매매일지 읽기 대기';PAPER_SOURCE_CHANGED='원본 기록 변경 · 모의 이력 보존 후 재검토 필요';ACCOUNT_LEDGER_MISMATCH='계좌와 매매일지 불일치';TODAY_FILL_MISMATCH='당일 체결과 일지 대조 필요';MARKET_HISTORY_SHORT='시장분류용 일봉 부족'}

 if($labels.ContainsKey($code)){return $labels[$code]};return ('전략 확인 필요 ['+$code+']')

}

function At58S-Run($ctx,$s){

 $now=At58-Now $ctx;$result=[pscustomobject]@{Mode='PAPER';ExecutionEnabled=$false;Code='STRATEGY_INPUT_WAIT';Text='';Reconciled=$false;Confirmations=0;Market='';NextBuy=$null;NextSell=$null;PaperOrderCount=0;PaperFillCount=0;PaperQty=$null;PaperCash=$null;PaperRealized=$null;Plan=@();Orders=@();OrderCandidate=$null}

 try{

  $path=Join-Path $ctx.Root 'strategy-input.dpapi';if(![IO.File]::Exists($path)){At58-Fail 'STRATEGY_INPUT_WAIT' 'STRATEGY'}

  try{$raw=(At58-Unprotect ([IO.File]::ReadAllText($path)) 'AT58-STRATEGY-INPUT-1')|ConvertFrom-Json}catch{At58-Fail 'STRATEGY_INPUT_WAIT' 'STRATEGY'}

  $age=($now-(At58S-Utc $raw.Utc)).TotalSeconds;if($age -lt -5 -or $age -gt 120){At58-Fail 'STRATEGY_INPUT_WAIT' 'STRATEGY'}

  $source=At58S-Import $raw;$proof=At58S-Reconcile $source $s

  if(!$ctx.ContainsKey('StrategyProof') -or $ctx.StrategyProof -cne $proof){$ctx.StrategyProof=$proof;$ctx.StrategyConfirmations=1}

  elseif(!$ctx.ContainsKey('StrategyProofUtc') -or (At58S-Utc $s.CompletedUtc) -gt (At58S-Utc $ctx.StrategyProofUtc)){$ctx.StrategyConfirmations=[math]::Min(2,$ctx.StrategyConfirmations+1)}

  $ctx.StrategyProofUtc=$s.CompletedUtc

  $result.Confirmations=$ctx.StrategyConfirmations;$result.Reconciled=($ctx.StrategyConfirmations -ge 2)

  # Query daily candles independently of MT. The active read allowlist remains GET-only.

  $days=At58-List $ctx '/market/v1/candles/days' @{mrkt_div_code='J';iscd=$ctx.Symbol;mod_stpr_cls_code='0'}

  $market=At58S-Market $days $s $source.Policy;$result.Market=$market.Name

  $paperPath=Join-Path $ctx.Root 'paper-state.dpapi';$state=$null

  if([IO.File]::Exists($paperPath)){try{$state=(At58-Unprotect ([IO.File]::ReadAllText($paperPath)) 'AT58-PAPER-1')|ConvertFrom-Json}catch{At58-Fail 'PAPER_STORAGE' 'STRATEGY'}}

  if(!$state){$state=At58S-NewPaper $source $s};At58S-ValidatePaper $state $source $s

  if($ctx.ManagementRoot){

   try{$runtime=[IO.File]::ReadAllText((Join-Path $ctx.ManagementRoot 'runtime.json'))|ConvertFrom-Json}catch{At58-Fail 'STRATEGY_PAUSED' 'STRATEGY'}

   if($runtime.RunId -cne $ctx.RunId -or !$runtime.DesiredRunning -or ((At58-Now $ctx)-(At58S-Utc $runtime.Utc)).TotalSeconds -gt 20){At58-Fail 'STRATEGY_PAUSED' 'STRATEGY'}

  }

  $step=At58S-PaperStep $state $source $s $market (At58-Now $ctx) $ctx.RunId $result.Reconciled

  # Commit the complete local simulation before publishing any result. Never reset on an I/O error.

  try{At58-Atomic $paperPath (At58-Protect ($step.State|ConvertTo-Json -Depth 40 -Compress) 'AT58-PAPER-1')}catch{At58-Fail 'PAPER_STORAGE' 'STRATEGY'}

  $result.Code=$step.Code;$result.PaperOrderCount=@($step.State.Orders).Count;$result.PaperFillCount=@($step.State.Fills).Count;$result.PaperQty=$step.State.Qty;$result.PaperCash=$step.State.Cash;$result.PaperRealized=$step.State.Realized-$step.State.InitialRealized

  $result.Orders=@($step.State.Orders|Select-Object -Last 100)

  if($step.Plan){$result.Plan=$step.Plan.Rows;$result.NextBuy=$step.Plan.NextBuy;$result.NextSell=$step.Plan.NextSell}

  # Preview uses a fresh, reconciled real-account baseline, never simulated holdings or fills.

  if($result.Reconciled -and $s.Session.Live -and !$step.State.MarketCandidate){

   $real=At58S-NewPaper $source $s

   $real.BuyCount=@($source.Ledger.Rows|Where-Object {$_.Day -ceq $s.Day -and $_.Side -ceq '매수'}).Count

   $plan=At58S-Plan $source $real $s $step.State.Market

   if($plan.Candidate.Count){$c=At58S-Clone $plan.Candidate[0];$c|Add-Member Symbol $s.Symbol;$result.OrderCandidate=$c}

  }

 }catch{

  $result.Code=(At58-Error $_).Code;if($result.Code -ceq 'UNEXPECTED'){$result.Code='STRATEGY_ERROR'}

  $ctx.StrategyProof='';$ctx.StrategyConfirmations=0;$result.Reconciled=$false;$result.Confirmations=0

  try{

   $saved=(At58-Unprotect ([IO.File]::ReadAllText((Join-Path $ctx.Root 'paper-state.dpapi'))) 'AT58-PAPER-1')|ConvertFrom-Json

   if($saved.Schema -ceq 'AT-PAPER-1' -and $saved.Scope -ceq $s.Scope -and $saved.Symbol -ceq $s.Symbol){$result.PaperOrderCount=@($saved.Orders).Count;$result.PaperFillCount=@($saved.Fills).Count;$result.Orders=@($saved.Orders|Select-Object -Last 100)}

  }catch{}

 }

 $result.Text=At58S-Message $result.Code

 try{At58-Atomic (Join-Path $ctx.Root 'strategy-status.json') (@{Utc=(At58-Now $ctx).ToString('o');RunId=$ctx.RunId;Code=$result.Code;Mode='PAPER';ExecutionEnabled=$false;Reconciled=$result.Reconciled;Confirmations=$result.Confirmations;PaperOrders=$result.PaperOrderCount;PaperFills=$result.PaperFillCount}|ConvertTo-Json -Compress)}catch{$result.Code='PAPER_STORAGE';$result.Text=At58S-Message $result.Code}

 return $result

}



# Broker order lifecycle primitives. The installed host is READ_ONLY, so the live send gate stays closed.

# Source: https://openapi.imeritz.com/samplecode-py (2026-11-01).

function At58O-Request($intent,[string]$action='NEW',[string]$original=''){

 if($intent.Symbol -cnotmatch '^[0-9A-Z]{6}$' -or $intent.Side -cnotin @('매수','매도')){At58-Fail 'ORDER_INTENT' 'ORDER'}

 $qty=At58S-Num $intent.Qty 1 100000000 $true;$price=At58S-Num $intent.Price 5 10000000 $true

 if($price%5 -ne 0){At58-Fail 'ORDER_TICK' 'ORDER'}

 $body=[ordered]@{iscd=('A'+$intent.Symbol);odqt=$qty;oder_unpr=$price;oder_cls_code='01';oder_cond_cls_code='0';orgl_oder_no=0;whol_rctf_cncl_yn='N';warn_cnfr_yn='N';exch_kind_code='01'}

 $path=if($intent.Side -ceq '매수'){'/trading/v1/orders/buy'}else{'/trading/v1/orders/sell'}

 if($action -cin @('CANCEL','MODIFY')){

  if($original -cnotmatch '^[0-9]{1,20}$' -or $original -cmatch '^0+$'){At58-Fail 'ORDER_ORIGINAL' 'ORDER'}

  $body.orgl_oder_no=$original.TrimStart('0');$path=if($action -ceq 'CANCEL'){'/trading/v1/orders/cancel'}else{'/trading/v1/orders/modify'}

 }elseif($action -cne 'NEW'){At58-Fail 'ORDER_ACTION' 'ORDER'}

 return [pscustomobject]@{Method='POST';Path=$path;ContentType='application/json; charset=utf-8';Body=[pscustomobject]$body;Action=$action;ExecutionEnabled=$false}

}

function At58O-New($intent,[string]$scope,[string]$day,[string]$key){

 if($scope -cnotmatch '^[a-f0-9]{64}$' -or $key -cnotmatch '^[a-f0-9]{64}$'){At58-Fail 'ORDER_IDENTITY' 'ORDER'};$null=At58-Day $day;$null=At58O-Request $intent

 return [pscustomobject]@{Schema='AT-ORDER-1';Key=$key;Scope=$scope;Day=$day;Intent=(At58S-Clone $intent);State='STAGED';BrokerId='';Filled=0D;Amount=0D;Fee=0D;FillKeys=@();LastResponse='';ExecutionEnabled=$false}

}

function At58O-Ack($order,$response){

 if($order.State -cnotin @('SUBMITTING','UNKNOWN')){At58-Fail 'ORDER_ACK_STATE' 'ORDER'}

 $next=At58S-Clone $order;$code=[string](At58-Value $response 'rsp_cd');$data=At58-Value $response 'data';$warn=[string](At58-Value $data 'warn_cls_code');$id=[string](At58-Value $data 'oder_no')

 $next.LastResponse=At58-Code $code

 if($code -ceq '0001' -and $warn -ceq '0' -and $id -cmatch '^[0-9]{1,20}$' -and $id -cnotmatch '^0+$'){$next.BrokerId=$id.TrimStart('0');$next.State='ACKNOWLEDGED'}

 elseif($code -ceq '0001' -and $warn -cin @('1','2','3','4','5','6','7','8','9','a','b','c','d','e','f','g','h')){$next.State='WARNING_REVIEW'}

 elseif($code -and $code -cne '0001'){$next.State='UNKNOWN'}

 else{$next.State='UNKNOWN'}

 return $next

}

function At58O-Send($order,[string]$journal,[scriptblock]$testTransport=$null){

 if($order.State -cne 'STAGED'){At58-Fail 'ORDER_NO_RESEND' 'ORDER'}

 # There is no live transport in this release. A test callback is never supplied by UI/settings/Telegram.

 if(!$testTransport){At58-Fail 'LIVE_TRANSPORT_DISABLED' 'ORDER'}

 $orderLock=[Threading.Mutex]::new($false,('Local\AT58Order_'+(At58-Hash ([IO.Path]::GetFullPath($journal).ToLowerInvariant()))));$held=$false

 try{

 try{$held=$orderLock.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true};if(!$held){At58-Fail 'ORDER_BUSY' 'ORDER'}

 if([IO.File]::Exists($journal)){At58-Fail 'ORDER_NO_RESEND' 'ORDER'}

 $next=At58S-Clone $order;$next.State='SUBMITTING'

 At58-Atomic $journal (At58-Protect ($next|ConvertTo-Json -Depth 20 -Compress) 'AT58-ORDER-1')

 try{$reply=& $testTransport (At58O-Request $next.Intent);$next=At58O-Ack $next $reply}catch{$next.State='UNKNOWN'}

 At58-Atomic $journal (At58-Protect ($next|ConvertTo-Json -Depth 20 -Compress) 'AT58-ORDER-1')

 return $next

 }finally{if($held){$orderLock.ReleaseMutex()};$orderLock.Dispose()}

}

function At58O-Reconcile($order,$rows,[string]$scope,[string]$day){

 if($scope -cne $order.Scope -or $day -cne $order.Day -or !$order.BrokerId){At58-Fail 'ORDER_RECONCILE_IDENTITY' 'ORDER'}

 $matched=@($rows|Where-Object {(At58E-Id $_.Id) -ceq (At58E-Id $order.BrokerId) -and $_.Day -ceq $order.Day})

 if($matched.Count -ne 1){At58-Fail 'ORDER_RECONCILE_MISSING' 'ORDER'};$row=$matched[0]

 $side=if($order.Intent.Side -ceq '매수'){'2'}else{'1'}

 if($row.Symbol -cne $order.Intent.Symbol -or $row.Side -cne $side -or $row.Qty -ne $order.Intent.Qty -or $row.Price -ne $order.Intent.Price -or $row.Kind -cne '1'){At58-Fail 'ORDER_RECONCILE_TERMS' 'ORDER'}

 if($row.Filled -lt $order.Filled -or $row.Remaining+$row.Filled -gt $row.Qty){At58-Fail 'ORDER_RECONCILE_QUANTITY' 'ORDER'}

 # A history row's reported cntg_unpr is not assumed to be the cumulative weighted fill price.

 $next=At58S-Clone $order

 if($row.Filled -gt $next.Filled){$next.State='FILL_DETAIL_REQUIRED'}

 elseif($row.Remaining -eq 0){$next.State=if($row.Filled -eq $row.Qty){'FILLED'}else{'CANCELLED'}}

 elseif($next.Filled -gt 0){$next.State='PARTIAL'}else{$next.State='ACKNOWLEDGED'}

 return $next

}

function At58O-Fill($order,$fill){

 if($fill.Scope -cne $order.Scope -or $fill.Day -cne $order.Day -or (At58E-Id $fill.BrokerId) -cne (At58E-Id $order.BrokerId) -or $fill.Symbol -cne $order.Intent.Symbol -or $fill.Side -cne $order.Intent.Side -or $fill.Evidence -cne 'BROKER_EXECUTION'){At58-Fail 'FILL_IDENTITY' 'ORDER'}

 if([string]$fill.Key -cnotmatch '^[A-Za-z0-9|:_-]{1,100}$'){At58-Fail 'FILL_KEY' 'ORDER'}

 $n=At58S-Num $fill.Qty 1 100000000 $true;$amount=At58S-Num $fill.Amount 0.00001;$fee=At58S-Num $fill.Fee

 $old=@($order.FillKeys|Where-Object {$_.Key -ceq $fill.Key})

 if($old.Count){if($old.Count -ne 1 -or $old[0].Qty -ne $n -or $old[0].Amount -ne $amount -or $old[0].Fee -ne $fee){At58-Fail 'FILL_CONFLICT' 'ORDER'};return (At58S-Clone $order)}

 if($order.Filled+$n -gt $order.Intent.Qty){At58-Fail 'FILL_OVERFLOW' 'ORDER'}

 $price=$amount/$n;if(($order.Intent.Side -ceq '매수' -and $price -gt $order.Intent.Price) -or ($order.Intent.Side -ceq '매도' -and $price -lt $order.Intent.Price)){At58-Fail 'FILL_LIMIT' 'ORDER'}

 $next=At58S-Clone $order;$next.Filled+=$n;$next.Amount+=$amount;$next.Fee+=$fee;$next.FillKeys+=,[pscustomobject]@{Key=$fill.Key;Qty=$n;Amount=$amount;Fee=$fee}

 $next.State=if($next.Filled -eq $next.Intent.Qty){'FILLED'}else{'PARTIAL'};return $next

}



# Official Meritz receipt/execution observation. Every trade remains externally sourced.

# A cumulative history quantity confirms notification coverage; it cannot supply missing prices or fees.

function At58E-Init {

 if(!('At58ReceiptFeed' -as [type])){

  Add-Type -ReferencedAssemblies @('System.dll','System.Core.dll','System.Security.dll','System.Web.Extensions.dll') -TypeDefinition @'

using System;

using System.IO;

using System.Text;

using System.Threading;

using System.Threading.Tasks;

using System.Net.WebSockets;

using System.Security.Cryptography;

using System.Collections.Generic;

using System.Web.Script.Serialization;



// Notification subscription only. This class has no trading REST transport.

public sealed class At58ReceiptFeed : IDisposable {

    static readonly object RegistryLock = new object();

    static readonly Dictionary<string, At58ReceiptFeed> Registry = new Dictionary<string, At58ReceiptFeed>(StringComparer.OrdinalIgnoreCase);

    readonly object gate = new object();

    readonly Queue<string> protocolTrace = new Queue<string>();

    readonly string root, scope;

    CancellationTokenSource cancel;

    ClientWebSocket socket;

    Task task;

    string code = "STOPPED", tokenHash = "", lastFault = "", protocol = "";

    DateTime retryUtc = DateTime.MinValue, listeningUtc = DateTime.MinValue;

    int failures, sessions, controlFrames;

    bool receiptAck, fillAck;

    public At58ReceiptFeed(string directory, string identity) { root = Path.GetFullPath(directory); scope = identity; }

    public static At58ReceiptFeed Get(string directory, string identity) {

        string key = Path.GetFullPath(directory);

        lock (RegistryLock) {

            At58ReceiptFeed f;

            if (!Registry.TryGetValue(key, out f)) Registry[key] = f = new At58ReceiptFeed(key, identity);

            if (f.scope != identity) {

                f.Dispose();

                lock(f.gate) { if(f.task != null && !f.task.IsCompleted) throw new InvalidOperationException("FEED_SCOPE"); }

                Registry[key] = f = new At58ReceiptFeed(key,identity);

            }

            return f;

        }

    }

    public static void Stop(string directory) {

        lock (RegistryLock) { At58ReceiptFeed f; if (Registry.TryGetValue(Path.GetFullPath(directory), out f)) f.Dispose(); }

    }

    public string Code { get { lock(gate) return code; } }

    public bool Ready { get { lock(gate) return receiptAck && fillAck && code == "LISTENING"; } }

    public int Sessions { get { lock(gate) return sessions; } }

    public DateTime RetryUtc { get { lock(gate) return retryUtc; } }

    public string LastFault { get { lock(gate) return lastFault; } }

    public string Protocol { get { lock(gate) return protocol; } }

    public bool ReceiptAck { get { lock(gate) return receiptAck; } }

    public bool FillAck { get { lock(gate) return fillAck; } }

    public string ProtocolTrace { get { lock(gate) return String.Join(" > ",protocolTrace.ToArray()); } }

    public static string Hash(string text) {

        using (var h = SHA256.Create()) return BitConverter.ToString(h.ComputeHash(Encoding.UTF8.GetBytes(text))).Replace("-", "").ToLowerInvariant();

    }

    public void Ensure(string token) {

        if (String.IsNullOrWhiteSpace(token) || token.Length > 8192 || token.Contains("\r") || token.Contains("\n")) throw new InvalidOperationException("FEED_TOKEN");

        string hash = Hash(token);

        lock(gate) {

            if (task != null && !task.IsCompleted) {

                if (hash == tokenHash) return;

                cancel.Cancel(); if(socket != null) socket.Abort(); return; // replace only after the previous receiver exits

            }

            if (DateTime.UtcNow < retryUtc) return;

            if(cancel != null) cancel.Dispose();

            cancel = new CancellationTokenSource(); tokenHash = hash;

            receiptAck = fillAck = false; listeningUtc = DateTime.MinValue; controlFrames = 0; code = "CONNECTING"; sessions++;

            task = Task.Run(() => Run(token, cancel.Token));

        }

    }

    static string Field(IDictionary<string, object> value, string name) {

        object x; return value != null && value.TryGetValue(name, out x) ? Convert.ToString(x) : "";

    }

    public static string Subscription(string token, string channel) {

        if(channel != "ohhts_cntg_infr" && channel != "ohhts_cntg_rslt") throw new InvalidOperationException("FEED_CHANNEL");

        return new JavaScriptSerializer().Serialize(new { header = new { token = "Bearer " + token, tr_type = "1" }, body = new { tr_cd = channel } });

    }

    // Also used by the offline tests. Fragment bytes are decoded only after EndOfMessage.

    public static byte[] Assemble(byte[][] pieces, int limit) {

        using(var m = new MemoryStream()) {

            foreach(var p in pieces) { if(m.Length + p.Length > limit) throw new InvalidOperationException("FEED_MESSAGE_LIMIT"); m.Write(p,0,p.Length); }

            return m.ToArray();

        }

    }

    public string Accept(byte[] bytes) {

        if(bytes.Length > 65536) throw new InvalidOperationException("FEED_MESSAGE_LIMIT");

        string text = new UTF8Encoding(false,true).GetString(bytes);

        var json = new JavaScriptSerializer { MaxJsonLength = 65536, RecursionLimit = 16 };

        var msg = json.DeserializeObject(text) as IDictionary<string,object>;

        object h = null, b = null;

        bool hasHeader = msg != null && msg.TryGetValue("header",out h);

        bool hasBody = msg != null && msg.TryGetValue("body",out b);

        var header = h as IDictionary<string,object>; var body = b as IDictionary<string,object>;

        string channel = Field(header,"tr_cd"), rsp = Field(header,"rsp_cd");

        if(!hasHeader) rsp = Field(msg,"rsp_cd");

        string type = Field(header,"tr_type");

        string safeRsp = System.Text.RegularExpressions.Regex.IsMatch(rsp,"^(?:(?:WSC|EGW|IGW)[0-9]{5}|[0-9]{4,5})$") ? rsp : "OTHER";

        lock(gate) {

            protocol = (hasHeader ? "HEADER" : "NO_HEADER")+"/"+(hasBody ? "BODY" : "NO_BODY")+"/"+(channel == "ohhts_cntg_infr" || channel == "ohhts_cntg_rslt" ? channel : "OTHER")+"/"+(type == "1" || type == "2" ? type : "OTHER")+"/"+safeRsp;

            protocolTrace.Enqueue(protocol); while(protocolTrace.Count > 8) protocolTrace.Dequeue();

        }

        if(!hasHeader) {

            // Some gateways emit a connection envelope before subscription ACKs.

            // Preserve it for inspection; it NEVER counts as a subscription or execution.

            SaveProtocol(bytes);

            if(rsp == "WSC00113" && !Ready) return "SERVER_WAIT";

            if(rsp == "WSC00110") throw new InvalidOperationException("FEED_SESSION_LIMIT");

            if(rsp != "") throw new InvalidOperationException("FEED_SUBSCRIBE_REJECTED");

            lock(gate) { if(!receiptAck && !fillAck && controlFrames++ < 2) return "CONTROL_PENDING"; }

            throw new InvalidOperationException("FEED_SCHEMA");

        }

        if(header == null) throw new InvalidOperationException("FEED_SCHEMA");

        if(channel != "ohhts_cntg_infr" && channel != "ohhts_cntg_rslt") throw new InvalidOperationException("FEED_CHANNEL");

        if(rsp != "") {

            if(rsp != "0000" && rsp != "00000") throw new InvalidOperationException(rsp == "WSC00110" ? "FEED_SESSION_LIMIT" : "FEED_SUBSCRIBE_REJECTED");

            // Meritz subscription acknowledgements may omit the body entirely.

            if(type != "1" || (body != null && body.Count != 0) || (b != null && body == null && Convert.ToString(b) != "")) throw new InvalidOperationException("FEED_ACK_SCHEMA");

            lock(gate) { if(channel == "ohhts_cntg_infr") receiptAck = true; else fillAck = true; if(receiptAck && fillAck) { if(listeningUtc == DateTime.MinValue) listeningUtc = DateTime.UtcNow; code = "LISTENING"; } }

            return "ACK";

        }

        if(body == null || body.Count == 0) throw new InvalidOperationException("FEED_SCHEMA");

        var envelope = new { Schema = "AT-RECEIPT-RAW-1", Scope = scope, ReceivedUtc = DateTime.UtcNow.ToString("o"), Message = msg };

        byte[] plain = Encoding.UTF8.GetBytes(json.Serialize(envelope));

        string folder = Path.Combine(root, "receipt-inbox"); Directory.CreateDirectory(folder);

        if(Directory.GetFiles(folder,"*.dpapi").Length >= 10000) throw new InvalidOperationException("FEED_INBOX_LIMIT");

        string path = Path.Combine(folder,DateTime.UtcNow.Ticks.ToString("D19")+"-"+Guid.NewGuid().ToString("N")+".dpapi");

        try {

            byte[] data = Encoding.ASCII.GetBytes(Convert.ToBase64String(ProtectedData.Protect(plain,Encoding.UTF8.GetBytes("AT58-RECEIPT-RAW-1"),DataProtectionScope.CurrentUser)));

            using(var stream = new FileStream(path+".tmp",FileMode.CreateNew,FileAccess.Write,FileShare.None)) { stream.Write(data,0,data.Length); stream.Flush(true); }

            File.Move(path+".tmp",path);

        } finally { Array.Clear(plain,0,plain.Length); if(File.Exists(path+".tmp")) File.Delete(path+".tmp"); }

        return "EVENT";

    }

    void SaveProtocol(byte[] plain) {

        Directory.CreateDirectory(root);

        string path = Path.Combine(root,"receipt-protocol.dpapi"), tmp = path+"."+Guid.NewGuid().ToString("N")+".tmp";

        try {

            byte[] data = Encoding.ASCII.GetBytes(Convert.ToBase64String(ProtectedData.Protect(plain,Encoding.UTF8.GetBytes("AT58-RECEIPT-DIAG-1"),DataProtectionScope.CurrentUser)));

            using(var stream = new FileStream(tmp,FileMode.CreateNew,FileAccess.Write,FileShare.None)) { stream.Write(data,0,data.Length); stream.Flush(true); }

            if(File.Exists(path)) File.Replace(tmp,path,null); else File.Move(tmp,path);

        } finally { if(File.Exists(tmp)) File.Delete(tmp); }

    }

    static async Task Subscribe(ClientWebSocket ws,string token,string channel,CancellationToken ct) {

        byte[] request = Encoding.UTF8.GetBytes(Subscription(token,channel));

        try { await ws.SendAsync(new ArraySegment<byte>(request),WebSocketMessageType.Text,true,ct).ConfigureAwait(false); }

        finally { Array.Clear(request,0,request.Length); }

    }

    // The earliest deadline owns the classification. An idle session refresh is not a transport failure.

    static int ReceiveTimeout(DateTime now, DateTime connected, DateTime ackStarted, bool ready, bool fragmented, out string reason) {

        double remaining = (connected.AddMinutes(30)-now).TotalMilliseconds;

        reason = "FEED_REFRESH";

        if(fragmented && 10000 < remaining) { remaining = 10000; reason = "FEED_TIMEOUT"; }

        double acknowledgement = (ackStarted.AddSeconds(15)-now).TotalMilliseconds;

        if(!ready && acknowledgement <= remaining) { remaining = acknowledgement; reason = "FEED_ACK_TIMEOUT"; }

        return (int)Math.Max(0,Math.Ceiling(remaining));

    }

    static async Task<WebSocketReceiveResult> ReceiveWithDeadline(WebSocket ws, byte[] buffer, int milliseconds, string reason, CancellationToken ct) {

        ct.ThrowIfCancellationRequested();

        if(milliseconds <= 0) throw new InvalidOperationException(reason);

        using(var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct)) {

            timeout.CancelAfter(milliseconds);

            try { return await ws.ReceiveAsync(new ArraySegment<byte>(buffer),timeout.Token).ConfigureAwait(false); }

            catch(OperationCanceledException) {

                if(ct.IsCancellationRequested) throw;

                if(timeout.IsCancellationRequested) throw new InvalidOperationException(reason);

                throw;

            }

        }

    }

    void CompleteSession(string failure, bool stopped, DateTime now) {

        lock(gate) {

            bool stable = receiptAck && fillAck && listeningUtc != DateTime.MinValue && (now-listeningUtc).TotalSeconds >= 60;

            socket = null; receiptAck = fillAck = false; listeningUtc = DateTime.MinValue;

            code = stopped ? "STOPPED" : failure;

            if(stopped) { retryUtc = DateTime.MinValue; return; }

            if(failure == "FEED_REFRESH") { failures = 0; retryUtc = now; return; }

            lastFault = failure;

            // Successful, silent subscriptions also reset old failures; no execution event is required.

            if(stable) failures = 0;

            failures = Math.Min(5,failures+1);

            retryUtc = now.AddSeconds(failure == "FEED_SESSION_LIMIT" ? 300 : Math.Min(300,30*Math.Pow(2,failures-1)));

        }

    }

    async Task Run(string token, CancellationToken ct) {

        string failure = "FEED_DISCONNECTED";

        try {

            using(var ws = new ClientWebSocket()) {

                lock(gate) socket = ws;

                ws.Options.KeepAliveInterval = TimeSpan.FromSeconds(30);

                using(var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct)) {

                    timeout.CancelAfter(10000);

                    await ws.ConnectAsync(new Uri("wss://openapi.imeritz.com:29443/websocket"),timeout.Token).ConfigureAwait(false);

                }

                await Subscribe(ws,token,"ohhts_cntg_infr",ct).ConfigureAwait(false);

                bool secondSent = false;

                int subscribeRetries = 0;

                var buffer = new byte[8192]; var connected = DateTime.UtcNow; var ackStarted = connected;

                while(!ct.IsCancellationRequested) {

                    string outcome;

                    using(var memory = new MemoryStream()) {

                        WebSocketReceiveResult received;

                        do {

                            string timeoutReason;

                            int wait = ReceiveTimeout(DateTime.UtcNow,connected,ackStarted,Ready,memory.Length > 0,out timeoutReason);

                            received = await ReceiveWithDeadline(ws,buffer,wait,timeoutReason,ct).ConfigureAwait(false);

                            if(received.MessageType == WebSocketMessageType.Close) throw new InvalidOperationException("FEED_DISCONNECTED");

                            if(received.MessageType != WebSocketMessageType.Text) throw new InvalidOperationException("FEED_MESSAGE_TYPE");

                            if(memory.Length + received.Count > 65536) throw new InvalidOperationException("FEED_MESSAGE_LIMIT");

                            memory.Write(buffer,0,received.Count);

                        } while(!received.EndOfMessage);

                        outcome = Accept(memory.ToArray());

                    }

                    if(outcome == "SERVER_WAIT") {

                        if(subscribeRetries >= 3 || token == null) throw new InvalidOperationException("FEED_SERVER_WAIT");

                        await Task.Delay(1000 * (1 << subscribeRetries++),ct).ConfigureAwait(false);

                        await Subscribe(ws,token,secondSent ? "ohhts_cntg_rslt" : "ohhts_cntg_infr",ct).ConfigureAwait(false);

                        ackStarted = DateTime.UtcNow;

                    }

                    if(ReceiptAck && !secondSent) {

                        await Subscribe(ws,token,"ohhts_cntg_rslt",ct).ConfigureAwait(false);

                        secondSent = true; subscribeRetries = 0; ackStarted = DateTime.UtcNow;

                    }

                    if(Ready) token = null;

                }

            }

        } catch(InvalidOperationException e) {

            if(e.Message.StartsWith("FEED_",StringComparison.Ordinal) && e.Message.Length < 48) failure = e.Message;

        } catch(OperationCanceledException) { failure = ct.IsCancellationRequested ? "STOPPED" : "FEED_TIMEOUT"; }

        catch { failure = "FEED_CONNECTION_ERROR"; }

        finally {

            token = null;

            CompleteSession(failure,ct.IsCancellationRequested,DateTime.UtcNow);

        }

    }

    public void Dispose() { lock(gate) { if(cancel != null) cancel.Cancel(); if(socket != null) socket.Abort(); code = "STOPPED"; receiptAck = fillAck = false; } }

}



'@

 }

}

function At58E-Id($value,[bool]$optional=$false){

 $v=([string]$value).Trim();if($optional -and (!$v -or $v -cmatch '^0+$')){return ''}

 if($v -cnotmatch '^[0-9]{1,20}$' -or $v -cmatch '^0+$'){At58-Fail 'RECEIPT_ORDER_ID' 'EXECUTION'};return $v.TrimStart('0')

}

function At58E-Decode($raw,[string]$scope){

 if((At58-Value $raw 'Schema') -cne 'AT-RECEIPT-RAW-1' -or (At58-Value $raw 'Scope') -cne $scope){At58-Fail 'RECEIPT_SCOPE' 'EXECUTION'}

 $received=At58S-Utc $raw.ReceivedUtc;$h=At58-Value $raw.Message 'header';$b=At58-Value $raw.Message 'body';$channel=[string](At58-Value $h 'tr_cd')

 if($channel -cnotin @('ohhts_cntg_infr','ohhts_cntg_rslt')){At58-Fail 'RECEIPT_CHANNEL' 'EXECUTION'}

 $user=[string](At58-Value $b 'user_id');$account=[string](At58-Value $b 'acno');$sub=[string](At58-Value $b 'asno')

 if(!$user -or $user.Length -gt 100 -or $user -cne [string](At58-Value $h 'tr_key') -or $account -cnotmatch '^[0-9]{8}$' -or $sub -cnotmatch '^[0-9]{2}$'){At58-Fail 'RECEIPT_ACCOUNT' 'EXECUTION'}

 $fill=$channel -ceq 'ohhts_cntg_rslt';$day=[string](At58-Value $b $(if($fill){'cntg_date'}else{'oder_date'}));$null=At58-Day $day

 $time=[string](At58-Value $b $(if($fill){'cntg_pros_time'}else{'mbcr_oder_time'}));if($time -cnotmatch '^[0-9]{9}$'){At58-Fail 'RECEIPT_TIME' 'EXECUTION'};$null=At58-Hour $time.Substring(0,6)

 $id=At58E-Id (At58-Value $b 'oder_no');$original=At58E-Id (At58-Value $b 'orgl_oder_no') $true

 $side=[string](At58-Value $b 'deal_cls_code');$isin=[string](At58-Value $b 'stnd_iscd')

 if($side -cnotin @('1','2') -or $isin -cnotmatch '^[A-Z]{2}[A-Z0-9]{9}[0-9]$'){At58-Fail 'RECEIPT_INSTRUMENT' 'EXECUTION'}

 $price=At58S-Num (At58-Value $b $(if($fill){'cntg_prc'}else{'aspr_prc'})) 0 1000000000

 $qty=At58S-Num (At58-Value $b $(if($fill){'cntg_qty'}else{'tlms_aspr_qty'})) $(if($fill){1}else{0}) 1000000000 $true

 if($fill -and $price -le 0){At58-Fail 'RECEIPT_PRICE' 'EXECUTION'}

 $action=if($fill){'FILL'}else{[string](At58-Value $b 'rctf_cncl_cls_code')};if(!$fill -and $action -cnotin @('1','2','3')){At58-Fail 'RECEIPT_ACTION' 'EXECUTION'}

 $reject=if($fill){''}else{([string](At58-Value $b 'aspr_rfus_reas_code')).Trim()};if($reject -and $reject -cnotmatch '^[A-Za-z0-9]{1,12}$'){At58-Fail 'RECEIPT_REJECT_CODE' 'EXECUTION'}

 $service=[string](At58-Value $b 'svc_id');$seq=[string](At58-Value $b 'pros_srno')

 if($service -cnotmatch '^[A-Za-z0-9_]{1,32}$' -or $seq -cnotmatch '^[0-9]{1,20}$'){At58-Fail 'RECEIPT_SEQUENCE' 'EXECUTION'}

 $accountHash=At58-Hash ($scope+'|'+$user+'|'+$account+'|'+$sub)

 $key=At58-Hash (@($accountHash,$day,$time,$id,$original,$side,$isin,$price.ToString([Globalization.CultureInfo]::InvariantCulture),$qty,$action,$reject,$service,$seq) -join '|')

 return [pscustomobject][ordered]@{Key=$key;Account=$accountHash;Day=$day;Time=$time;Id=$id;Original=$original;Side=$side;Isin=$isin;Price=$price;Qty=$qty;Kind=$(if($fill){'FILL'}else{'RECEIPT'});Action=$action;Reject=$reject;ReceivedUtc=$received.ToString('o');Symbol='';State='HISTORY_WAIT';Fee=$null;Tax=$null;Source='BROKER_NOTIFICATION';Ownership='EXTERNAL';Duplicates=0}

}

function At58E-NewBook([string]$scope,[string]$symbol,[datetime]$now){

 return [pscustomobject]@{Schema='AT-RECEIPTS-1';Scope=$scope;Symbol=$symbol;StartedUtc=$now.ToString('o');Account='';Events=@();Baseline=@();HistoryInitialized=$false;Revision=0;Gaps=@()}

}

function At58E-Add($book,$event){

 if($book.Account -and $event.Account -cne $book.Account){At58-Fail 'RECEIPT_ACCOUNT_CHANGED' 'EXECUTION'}

 $same=@($book.Events|Where-Object {$_.Key -ceq $event.Key})

 if($same.Count -gt 1){At58-Fail 'RECEIPT_BOOK_CORRUPT' 'EXECUTION'}

 if($same.Count){$same[0].Duplicates=[math]::Min(1000000,$same[0].Duplicates+1);return}

 if($book.Events.Count -ge 50000){At58-Fail 'RECEIPT_BOOK_LIMIT' 'EXECUTION'}

 if(!$book.Account){$book.Account=$event.Account};$book.Events+=,$event

}

function At58E-Reconcile($book,$rows,[string[]]$days,[datetime]$now){

 $map=@{};$gaps=New-Object 'Collections.Generic.List[object]';$baseline=@{}

 foreach($b in $book.Baseline){$baseline[$b.Day+'|'+$b.Id]=$b}

 foreach($r in $rows){

  $id=At58E-Id $r.Id;$key=$r.Day+'|'+$id

  if($map.ContainsKey($key)){At58-Fail 'RECEIPT_HISTORY_DUPLICATE' 'EXECUTION'};$map[$key]=$r

  if($r.Symbol -ceq $book.Symbol -and !$baseline.ContainsKey($key)){

   $b=[pscustomobject]@{Day=$r.Day;Id=$id;Filled=$(if(!$book.HistoryInitialized){[decimal]$r.Filled}else{0D})}

   $book.Baseline+=,$b;$baseline[$key]=$b

  }

 }

 foreach($e in $book.Events){

  if($e.Day -cnotin $days){continue};$key=$e.Day+'|'+$e.Id

  if(!$map.ContainsKey($key)){$e.State=if(($now-(At58S-Utc $e.ReceivedUtc)).TotalSeconds -gt 120){'HISTORY_MISSING'}else{'HISTORY_WAIT'};continue}

  $r=$map[$key];$root=At58E-Id $r.Original $true

  if($r.Side -cne $e.Side -or $root -cne $e.Original){$e.State='TERMS_CONFLICT';continue}

  $e.Symbol=$r.Symbol

  if($e.Kind -ceq 'RECEIPT'){

   if($r.Kind -cne $e.Action -or $r.Price -ne $e.Price -or $r.Qty -ne $e.Qty){$e.State='TERMS_CONFLICT';continue}

   $e.State=if($e.Reject -and $e.Reject -cnotmatch '^0+$'){'REJECTED'}elseif($r.Status -ceq '3' -or ($r.Reject -and $r.Reject -cnotmatch '^0+$')){'REJECTED'}else{'RECEIPT_MATCHED'}

  }else{

   if(($r.Side -ceq '2' -and $r.Price -gt 0 -and $e.Price -gt $r.Price) -or ($r.Side -ceq '1' -and $r.Price -gt 0 -and $e.Price -lt $r.Price)){$e.State='PRICE_CONFLICT';continue}

   # cntg_type_code and pros_srno are not documented as globally unique execution IDs.

   $e.State='CUMULATIVE_WAIT'

  }

 }

 foreach($key in $map.Keys){

  $r=$map[$key];$events=@($book.Events|Where-Object {$_.Day -ceq $r.Day -and $_.Id -ceq (At58E-Id $r.Id)})

  $isins=@($events|Select-Object -ExpandProperty Isin -Unique)

  if($isins.Count -gt 1){foreach($e in $events){$e.State='INSTRUMENT_CONFLICT'}}

  $fills=@($events|Where-Object {$_.Kind -ceq 'FILL'});$sum=0D;foreach($e in $fills){$sum+=$e.Qty}

  $base=if($baseline.ContainsKey($key)){$baseline[$key].Filled}else{0D};$expected=[decimal]$r.Filled-$base

  if($expected -lt 0){$gaps.Add([pscustomobject]@{Day=$r.Day;Id=(At58E-Id $r.Id);Code='CUMULATIVE_REGRESSION'});continue}

  if($r.Symbol -ceq $book.Symbol -and $sum -ne $expected){

   $gaps.Add([pscustomobject]@{Day=$r.Day;Id=(At58E-Id $r.Id);Code=$(if($sum -lt $expected){'FILL_DETAIL_GAP'}else{'FILL_CUMULATIVE_CONFLICT'})})

  }

  foreach($e in $fills){if($e.State -ceq 'CUMULATIVE_WAIT'){$e.State=if($sum -eq $expected){'FILL_MATCHED_FEE_PENDING'}elseif(($now-(At58S-Utc $e.ReceivedUtc)).TotalSeconds -le 120){'CUMULATIVE_WAIT'}else{'FILL_DETAIL_REVIEW'}}}

 }

 # Older unresolved days remain visible instead of being silently discarded at midnight.

 foreach($e in $book.Events){if($e.Day -cnotin $days -and $e.State -cin @('HISTORY_WAIT','CUMULATIVE_WAIT')){$e.State='HISTORY_DAY_REVIEW'}}

 $book.Gaps=@($book.Gaps|Where-Object {$_.Day -cnotin $days})+@($gaps.ToArray());$book.HistoryInitialized=$true

}

function At58E-StateLabel([string]$state){

 $labels=@{RECEIPT_MATCHED='접수 대조 완료';REJECTED='주문 거절';FILL_MATCHED_FEE_PENDING='체결 대조 · 비용 미확정';HISTORY_WAIT='주문 내역 대기';CUMULATIVE_WAIT='누적 체결 대기';HISTORY_MISSING='주문 내역 누락';HISTORY_DAY_REVIEW='이전 날짜 확인 필요';TERMS_CONFLICT='주문 조건 불일치';PRICE_CONFLICT='체결 가격 확인';INSTRUMENT_CONFLICT='종목 정보 불일치';FILL_DETAIL_REVIEW='체결 누락·중복 확인'}

 if($labels.ContainsKey($state)){return $labels[$state]};return '대조 확인 필요'

}

function At58E-Message([string]$code){

 $map=@{LISTENING='통보 구독 완료 · 수신 대기';CONNECTING='접수·체결 통보 연결 중';RECEIPT_REVIEW='통보와 주문 내역 대조 필요';FEED_SESSION_LIMIT='통보 연결 수 제한 · 5분 후 재연결';FEED_CONNECTION_ERROR='통보 연결 재시도 대기';STOPPED='통보 수신 중지'}

 if($map.ContainsKey($code)){return $map[$code]};return ('통보 확인 필요 ['+$code+']')

}

function At58E-Run($ctx,$snapshot){

 $now=At58-Now $ctx;$result=[pscustomobject]@{Mode='OBSERVE';ExecutionEnabled=$false;Code='CONNECTING';Text='';Connected=$false;Sessions=0;LastFault='';Protocol='';ProtocolTrace='';ReceiptAck=$false;FillAck=$false;Receipts=0;Fills=0;Pending=0;Gaps=0;Duplicates=0;BaselineFilled=0;FeeStatus='UNAVAILABLE';OrdersSent=0;Events=@()};$lock=$null;$held=$false

 try{

  At58E-Init

  $lock=[Threading.Mutex]::new($false,('Local\AT58ReceiptBook_'+(At58-Hash $ctx.Root)));try{$held=$lock.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true};if(!$held){At58-Fail 'RECEIPT_BOOK_BUSY' 'EXECUTION'}

  $path=Join-Path $ctx.Root 'receipt-book.dpapi';$book=$null

  if([IO.File]::Exists($path)){

   if(([IO.FileInfo]$path).Length -gt 60000000){At58-Fail 'RECEIPT_BOOK_LIMIT' 'EXECUTION'}

   try{$book=(At58-Unprotect ([IO.File]::ReadAllText($path)) 'AT58-RECEIPTS-1')|ConvertFrom-Json}catch{At58-Fail 'RECEIPT_BOOK_STORAGE' 'EXECUTION'}

   if($book.Schema -cne 'AT-RECEIPTS-1' -or $book.Scope -cne $ctx.Scope -or $book.Symbol -cne $ctx.Symbol -or $book.Events.Count -gt 50000){At58-Fail 'RECEIPT_BOOK_IDENTITY' 'EXECUTION'}

  }else{$book=At58E-NewBook $ctx.Scope $ctx.Symbol $now}

  $folder=Join-Path $ctx.Root 'receipt-inbox';$files=@();if([IO.Directory]::Exists($folder)){$files=@(Get-ChildItem -LiteralPath $folder -Filter '*.dpapi' -File|Sort-Object Name|Select-Object -First 200)}

  foreach($file in $files){

   if($file.Length -gt 120000){At58-Fail 'RECEIPT_INBOX_SIZE' 'EXECUTION'}

   try{$raw=(At58-Unprotect ([IO.File]::ReadAllText($file.FullName)) 'AT58-RECEIPT-RAW-1')|ConvertFrom-Json}catch{At58-Fail 'RECEIPT_INBOX_STORAGE' 'EXECUTION'}

   At58E-Add $book (At58E-Decode $raw $ctx.Scope)

  }

  $priorRows=At58-Value $snapshot 'PriorOrders';$rows=@($snapshot.OrdersToday)+@($priorRows);$rows=@($rows|Where-Object {$null -ne $_})

  $days=@($snapshot.Day);if($snapshot.PriorDay -cne $snapshot.Day){$days+=,$snapshot.PriorDay}

  $older=@(@($book.Events|Where-Object {$_.State -cnotin @('RECEIPT_MATCHED','REJECTED','FILL_MATCHED_FEE_PENDING')}|Select-Object -ExpandProperty Day)+@($book.Gaps|Select-Object -ExpandProperty Day)|Where-Object {$_ -cnotin $days}|Sort-Object -Unique -Descending|Select-Object -First 2)

  foreach($day in $older){$null=At58-Day $day;$rows+=@(At58-Orders (At58-List $ctx '/trading/v1/orders/history' @{oder_date=$day;deal_cls_code='0';cntg_cls_code='0';sort_stnd_code='2'}) $day);$days+=,$day}

  At58E-Reconcile $book $rows $days $now;$book.Revision++

  # Commit before deleting inbox items; a crash between these steps replays idempotently.

  At58-Atomic $path (At58-Protect ($book|ConvertTo-Json -Depth 20 -Compress) 'AT58-RECEIPTS-1')

  foreach($file in $files){[IO.File]::Delete($file.FullName)}

  if(!$ctx.Transport){$feed=[At58ReceiptFeed]::Get($ctx.Root,$ctx.Scope);$feed.Ensure($ctx.Token);$result.Code=$feed.Code;$result.Connected=$feed.Ready;$result.Sessions=$feed.Sessions;$result.LastFault=$feed.LastFault;$result.Protocol=$feed.Protocol;$result.ProtocolTrace=$feed.ProtocolTrace;$result.ReceiptAck=$feed.ReceiptAck;$result.FillAck=$feed.FillAck}

  $today=@($book.Events|Where-Object {$_.Day -ceq $snapshot.Day})

  $result.Receipts=@($today|Where-Object {$_.Kind -ceq 'RECEIPT'}).Count;$result.Fills=@($today|Where-Object {$_.Kind -ceq 'FILL'}).Count

  $result.Pending=@($book.Events|Where-Object {$_.State -cnotin @('RECEIPT_MATCHED','REJECTED','FILL_MATCHED_FEE_PENDING')}).Count;$result.Gaps=$book.Gaps.Count

  foreach($e in $book.Events){$result.Duplicates+=$e.Duplicates};foreach($b in $book.Baseline){$result.BaselineFilled+=$b.Filled}

  if($result.Pending -gt 0 -or $result.Gaps -gt 0){$result.Code='RECEIPT_REVIEW'}

  $result.Events=@($book.Events|Where-Object {$_.Symbol -ceq $ctx.Symbol -or !$_.Symbol}|Select-Object -Last 100|Select-Object Day,Time,Id,Kind,Side,Symbol,Qty,Price,State,Ownership)

 }catch{

  $code=(At58-Error $_).Code;if($code -ceq 'UNEXPECTED'){$code='RECEIPT_LOCAL_ERROR'};$result.Code=$code

  if('At58ReceiptFeed' -as [type]){[At58ReceiptFeed]::Stop($ctx.Root)}

 }finally{if($held){$lock.ReleaseMutex()};if($lock){$lock.Dispose()}}

 $result.Text=At58E-Message $result.Code

 try{

  $text=[pscustomobject]@{Utc=$now.ToString('o');RunId=$ctx.RunId;Mode='OBSERVE';Code=$result.Code;Connected=$result.Connected;Sessions=$result.Sessions;LastFault=$result.LastFault;Protocol=$result.Protocol;ProtocolTrace=$result.ProtocolTrace;ReceiptAck=$result.ReceiptAck;FillAck=$result.FillAck;Receipts=$result.Receipts;Fills=$result.Fills;Pending=$result.Pending;Gaps=$result.Gaps;Duplicates=$result.Duplicates;ExecutionEnabled=$false;OrdersSent=0}|ConvertTo-Json -Compress

  At58-Atomic (Join-Path $ctx.Root 'execution-status.json') $text

  [IO.File]::AppendAllText((Join-Path $ctx.Root ('execution-'+(At58-Kst $now).ToString('yyyyMMdd')+'.jsonl')),$text+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))

 }catch{$result.Code='RECEIPT_STATUS_STORAGE';$result.Text=At58E-Message $result.Code}

 return $result

}



# Cash limit order coordinator. No production caller enables LIVE or supplies a live permit.

# Official request/response contract: official-spec.json downloaded 2026-11-01.

function At58T-Packet($intent,[string]$action='NEW',[string]$parentId=''){

 if($intent.Symbol -cne '0210A0'){At58-Fail 'TRADE_SYMBOL' 'TRADING'}

 $p=At58O-Request $intent $action $parentId

 if($action -cne 'NEW'){

  $id=At58E-Id $parentId;if($id.Length -gt 11){At58-Fail 'TRADE_ORDER_ID' 'TRADING'}

  $p.Body.orgl_oder_no=[long]$id;$p.Body.whol_rctf_cncl_yn='Y'

 }

 return $p

}

function At58T-Key($ctx,[string]$day,[string]$decision,[string]$action,[string]$parent=''){

 if($decision -cnotmatch '^[a-f0-9]{64}$' -or $action -cnotin @('NEW','MODIFY','CANCEL')){At58-Fail 'TRADE_DECISION' 'TRADING'}

 $null=At58-Day $day

 return (At58-Hash (@($ctx.Scope,$ctx.Symbol,$day,$decision,$action,$parent) -join '|'))

}

function At58T-NewBook($ctx){

 return [pscustomobject]@{Schema='AT-TRADING-1';Scope=$ctx.Scope;Symbol=$ctx.Symbol;Mode=$(if((At58-Value $ctx 'OrderMode') -ceq 'SIMULATED'){'SIMULATED'}else{'LIVE'});Revision=0;Account='';Orders=@();Fills=@();LastUtc=''}

}

function At58T-Path($ctx){return (Join-Path $ctx.Root $(if((At58-Value $ctx 'OrderMode') -ceq 'SIMULATED'){'order-simulation.dpapi'}else{'order-book.dpapi'}))}

function At58T-Validate($ctx,$book){

 if(!$book -or $book.Schema -cne 'AT-TRADING-1' -or $book.Scope -cne $ctx.Scope -or $book.Symbol -cne $ctx.Symbol -or $book.Mode -cne (At58T-NewBook $ctx).Mode){At58-Fail 'TRADE_BOOK_IDENTITY' 'TRADING'}

 if(@($book.Orders).Count -gt 5000 -or @($book.Fills).Count -gt 50000){At58-Fail 'TRADE_BOOK_LIMIT' 'TRADING'}

 $keys=@{};$ids=@{};$fills=@{}

 foreach($o in $book.Orders){

  if($o.Key -cnotmatch '^[a-f0-9]{64}$' -or $keys.ContainsKey($o.Key)){At58-Fail 'TRADE_BOOK_CORRUPT' 'TRADING'}

  if($o.State -cnotin @('SUBMITTING','UNKNOWN','WARNING_REVIEW','ACKNOWLEDGED','OPEN','PARTIAL','FILLED','REPLACED','CANCELLED','REJECTED','REVIEW')){At58-Fail 'TRADE_BOOK_CORRUPT' 'TRADING'}

  $null=At58T-Packet $o.Intent $o.Action $o.ParentId;$null=At58-Day $o.Day

  if($o.Action -ceq 'NEW'){if($o.ParentKey -or $o.RootKey -cne $o.Key){At58-Fail 'TRADE_BOOK_CHAIN' 'TRADING'}}

  else{if(!$keys.ContainsKey($o.ParentKey) -or $keys[$o.ParentKey].BrokerId -cne $o.ParentId -or $keys[$o.ParentKey].RootKey -cne $o.RootKey -or $keys[$o.ParentKey].Day -cne $o.Day){At58-Fail 'TRADE_BOOK_CHAIN' 'TRADING'}}

  if($o.BrokerId){$id=$o.Day+'|'+(At58E-Id $o.BrokerId);if($ids.ContainsKey($id)){At58-Fail 'TRADE_BOOK_CORRUPT' 'TRADING'};$ids[$id]=$true}

  $keys[$o.Key]=$o

 }

 foreach($f in $book.Fills){

  if($f.Key -cnotmatch '^[a-f0-9]{64}$' -or $fills.ContainsKey($f.Key) -or !$keys.ContainsKey($f.OrderKey) -or $f.Account -cne $book.Account){At58-Fail 'TRADE_FILL_CORRUPT' 'TRADING'}

  $null=At58S-Num $f.Qty 1 100000000 $true;$null=At58S-Num $f.Price 0.00001

  if($f.Amount -ne $f.Price*$f.Qty -or $null -ne $f.Fee -or $null -ne $f.Tax){At58-Fail 'TRADE_FILL_CORRUPT' 'TRADING'};$fills[$f.Key]=$true

 }

 foreach($o in $book.Orders){

  $qty=0D;$amount=0D;foreach($f in @($book.Fills|Where-Object {$_.OrderKey -ceq $o.Key})){$qty+=$f.Qty;$amount+=$f.Amount}

  if($o.Filled -ne $qty -or $o.Amount -ne $amount -or $qty -gt $o.Intent.Qty -or ($o.Action -ceq 'CANCEL' -and $qty -ne 0)){At58-Fail 'TRADE_FILL_TOTAL' 'TRADING'}

  $null=At58S-Num $o.Remaining 0 $o.Intent.Qty $true

  if($o.Filled+$o.Remaining -gt $o.Intent.Qty){At58-Fail 'TRADE_BOOK_QUANTITY' 'TRADING'}

 }

 foreach($root in @($book.Orders|Where-Object {$_.Action -ceq 'NEW'})){

  $total=0D;foreach($o in @($book.Orders|Where-Object {$_.RootKey -ceq $root.Key})){$total+=$o.Filled}

  if($total -gt $root.Intent.Qty){At58-Fail 'TRADE_CHAIN_OVERFILL' 'TRADING'}

 }

}

function At58T-Load($ctx){

 $path=At58T-Path $ctx;if(![IO.File]::Exists($path)){return (At58T-NewBook $ctx)}

 try{$b=(At58-Unprotect ([IO.File]::ReadAllText($path)) 'AT58-TRADING-1')|ConvertFrom-Json}catch{At58-Fail 'TRADE_BOOK_STORAGE' 'TRADING'}

 At58T-Validate $ctx $b;return $b

}

function At58T-Save($ctx,$book){

 At58T-Validate $ctx $book;$path=At58T-Path $ctx;$tmp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'

 $bytes=$null;$fs=$null

 try{

  [void][IO.Directory]::CreateDirectory($ctx.Root)

  $bytes=[Text.Encoding]::UTF8.GetBytes((At58-Protect ($book|ConvertTo-Json -Depth 32 -Compress) 'AT58-TRADING-1'))

  $fs=[IO.FileStream]::new($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)

  $fs.Write($bytes,0,$bytes.Length);$fs.Flush($true);$fs.Dispose();$fs=$null

  if([IO.File]::Exists($path)){[IO.File]::Replace($tmp,$path,[Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($tmp,$path)}

 }catch{At58-Fail 'TRADE_BOOK_STORAGE' 'TRADING'}finally{if($fs){$fs.Dispose()};if($bytes){[Array]::Clear($bytes,0,$bytes.Length)};if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}}

}

function At58T-Lock($ctx){return [Threading.Mutex]::new($false,('Local\AT58Trading_'+(At58-Hash ([IO.Path]::GetFullPath((At58T-Path $ctx)).ToLowerInvariant()))))}

function At58T-Permit($ctx,$packet){

 $permit=At58-Value $ctx 'OrderPermit';$now=At58-Now $ctx

 if((At58-Value $ctx 'OrderMode') -cne 'LIVE' -or !$permit){At58-Fail 'LIVE_TRANSPORT_DISABLED' 'TRADING'}

 # A future operator controller must grant one exact packet for this process. Settings and Telegram cannot do so.

 if($permit.Scope -cne $ctx.Scope -or $permit.RunId -cne $ctx.RunId -or $permit.PacketHash -cne (At58-Hash ($packet|ConvertTo-Json -Depth 8 -Compress)) -or (At58S-Utc $permit.ExpiresUtc) -le $now -or ((At58S-Utc $permit.ExpiresUtc)-$now).TotalSeconds -gt 30){At58-Fail 'TRADE_PERMIT' 'TRADING'}

}

function At58T-Wire($ctx,$packet){

 At58T-Permit $ctx $packet

 if($packet.Method -cne 'POST' -or $packet.Path -cnotin @('/trading/v1/orders/buy','/trading/v1/orders/sell','/trading/v1/orders/modify','/trading/v1/orders/cancel') -or $packet.Body.warn_cnfr_yn -cne 'N' -or $packet.Body.exch_kind_code -cne '01'){At58-Fail 'TRADE_ROUTE' 'TRADING'}

 if(!$ctx.Token -or (At58-Now $ctx) -ge $ctx.TokenUntil -or $ctx.Mac -cnotmatch '^[A-Fa-f0-9]{12}$'){At58-Fail 'TRADE_AUTH' 'TRADING'}

 $ctx.OrderPermit=$null # Single use, including timeout / HTTP failure. Never retry a POST.

 $a=@{Method='Post';Uri=('https://openapi.imeritz.com:9443'+$packet.Path);Headers=@{authorization=('Bearer '+$ctx.Token);mac_address=$ctx.Mac};ContentType='application/json; charset=utf-8';Body=($packet.Body|ConvertTo-Json -Depth 5 -Compress);TimeoutSec=10;MaximumRedirection=0;ErrorAction='Stop'}

 try{return (Invoke-RestMethod @a)}catch{

  # A broker failure may be HTTP 500 with a valid body. Preserve only code/data, never raw error text.

  $raw='';try{$raw=[string]$_.ErrorDetails.Message;if($raw.Length -gt 0 -and $raw.Length -le 16384){$r=$raw|ConvertFrom-Json;return [pscustomobject]@{rsp_cd=(At58-Code ([string](At58-Value $r 'rsp_cd')));data=(At58-Value $r 'data')}}}catch{}

  At58-Fail 'TRADE_RESPONSE_UNKNOWN' 'TRADING'

 }finally{$a=$null;$raw=$null}

}

function At58T-Gate($ctx,$s,$book,$intent,[string]$action,$parent=$null){

 $now=At58-Now $ctx;$kst=At58-Kst $now

 if($s.Scope -cne $ctx.Scope -or $s.Symbol -cne $ctx.Symbol -or $intent.Symbol -cne $s.Symbol -or $s.Day -cne $kst.ToString('yyyyMMdd')){At58-Fail 'TRADE_IDENTITY' 'TRADING'}

 $age=($now-(At58S-Utc $s.CompletedUtc)).TotalSeconds

 if($age -lt -2 -or $age -gt 15 -or !$s.Session.Live -or $kst -ge (At58S-SessionTime $s.Session.Close)){At58-Fail 'TRADE_SNAPSHOT_STALE' 'TRADING'}

 $runtime=$null;try{$runtime=[IO.File]::ReadAllText((Join-Path $ctx.ManagementRoot 'runtime.json'))|ConvertFrom-Json}catch{}

 if(!$runtime -or $runtime.RunId -cne $ctx.RunId -or !$runtime.DesiredRunning -or ($now-(At58S-Utc $runtime.Utc)).TotalSeconds -gt 20 -or ($now-(At58S-Utc $runtime.Utc)).TotalSeconds -lt -2){At58-Fail 'TRADE_PAUSED' 'TRADING'}

 if(@($book.Orders|Where-Object {$_.State -cin @('SUBMITTING','UNKNOWN','WARNING_REVIEW','ACKNOWLEDGED','REVIEW')}).Count){At58-Fail 'TRADE_PENDING_REVIEW' 'TRADING'}

 if($action -cne 'NEW'){

  if(!$parent -or $parent.Day -cne $s.Day -or $parent.Action -ceq 'CANCEL' -or $parent.State -cnotin @('OPEN','PARTIAL') -or !$parent.BrokerId -or $parent.Remaining -le 0 -or ($now-(At58S-Utc $parent.HistoryUtc)).TotalSeconds -gt 15){At58-Fail 'TRADE_PARENT' 'TRADING'}

  if($intent.Side -cne $parent.Intent.Side -or $intent.Symbol -cne $parent.Intent.Symbol -or $intent.Qty -ne $parent.Remaining -or ($action -ceq 'CANCEL' -and $intent.Price -ne $parent.Intent.Price)){At58-Fail 'TRADE_AMEND_TERMS' 'TRADING'}

  if(@($book.Orders|Where-Object {$_.ParentKey -ceq $parent.Key -and $_.State -cne 'REJECTED'}).Count){At58-Fail 'TRADE_PARENT_BUSY' 'TRADING'}

 }

 if($action -ceq 'CANCEL'){return} # Closing or strategy failure must not prevent cancelling a known owned order.

 if($kst -ge (At58S-SessionTime $s.Session.Close).AddMinutes(-3)){At58-Fail 'TRADE_CLOSING' 'TRADING'}

 $quoteAge=($now-(At58S-Utc $s.Quote.ReceivedUtc)).TotalSeconds

 if($s.Quote.Mode -cne 'LIVE_REST' -or $s.Quote.BasisDay -cne $s.Day -or $s.Quote.Tick -ne 5 -or $quoteAge -gt 15 -or $quoteAge -lt -2){At58-Fail 'TRADE_QUOTE' 'TRADING'}

 if((At58-Value $ctx 'OrderMode') -ceq 'LIVE'){At58O-CheckPrice $intent $s.Quote}

 $x=At58-Value $s 'Execution';$strategy=At58-Value $s 'Strategy'

 if(!$x -or !$x.Connected -or !$x.ReceiptAck -or !$x.FillAck -or $x.Pending -or $x.Gaps){At58-Fail 'TRADE_FEED' 'TRADING'}

 if(!$strategy -or !$strategy.Reconciled -or $strategy.Confirmations -lt 2){At58-Fail 'TRADE_RECONCILE' 'TRADING'}

 if(@($s.PriorUnresolved|Where-Object {$_.Symbol -ceq $s.Symbol}).Count){At58-Fail 'TRADE_PRIOR_ORDER' 'TRADING'}

 foreach($r in @($s.OpenOrdersToday|Where-Object {$_.Symbol -ceq $s.Symbol})){

  if(!@($book.Orders|Where-Object {$_.BrokerId -and $_.Day -ceq $r.Day -and $_.BrokerId -ceq (At58E-Id $r.Id)}).Count){At58-Fail 'TRADE_EXTERNAL_ORDER' 'TRADING'}

 }

 if($action -ceq 'NEW' -and @($book.Orders|Where-Object {$_.State -cin @('OPEN','PARTIAL')}).Count){At58-Fail 'TRADE_ACTIVE_ORDER' 'TRADING'}

 if($intent.Side -ceq '매수'){

  # Conservative: do not add back the old order's reservation during an amendment.

  $need=$intent.Qty*$intent.Price+[math]::Ceiling($intent.Qty*$intent.Price*0.01)

  if($need -gt [decimal]$s.Cash.Orderable){At58-Fail 'TRADE_CASH' 'TRADING'}

 }else{

  $ordinary=0D;foreach($h in @($s.Holdings|Where-Object {$_.Symbol -ceq $s.Symbol -and $_.Product -ceq '1' -and $_.Class -ceq '주식일반'})){$ordinary+=$h.Qty}

  if($intent.Qty -gt $ordinary -or $intent.Qty -gt $s.TargetQty){At58-Fail 'TRADE_POSITION' 'TRADING'}

 }

}

function At58T-Submit($ctx,$snapshot,$intent,[string]$action,[string]$decision,[string]$parentKey='', [scriptblock]$testTransport=$null){

 if($testTransport -and (At58-Value $ctx 'OrderMode') -cne 'SIMULATED'){At58-Fail 'TRADE_TEST_ISOLATION' 'TRADING'}

 $mutex=At58T-Lock $ctx;$held=$false

 try{

  try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true};if(!$held){At58-Fail 'TRADE_BUSY' 'TRADING'}

  $book=At58T-Load $ctx;$key=At58T-Key $ctx $snapshot.Day $decision $action $parentKey

  if(@($book.Orders|Where-Object {$_.Key -ceq $key}).Count){At58-Fail 'TRADE_NO_RESEND' 'TRADING'}

  $parent=$null;if($parentKey){$matches=@($book.Orders|Where-Object {$_.Key -ceq $parentKey});if($matches.Count -ne 1){At58-Fail 'TRADE_PARENT' 'TRADING'};$parent=$matches[0]}

  $packet=At58T-Packet $intent $action $(if($parent){$parent.BrokerId}else{''})

  if(!$testTransport){At58T-Permit $ctx $packet;At58-Token $ctx}

  At58T-Gate $ctx $snapshot $book $intent $action $parent

  $node=[pscustomobject]@{Key=$key;Day=$snapshot.Day;Action=$action;ParentKey=$parentKey;ParentId=$(if($parent){$parent.BrokerId}else{''});RootKey=$(if($parent){$parent.RootKey}else{$key});Intent=(At58S-Clone $intent);BrokerId='';State='SUBMITTING';CreatedUtc=(At58-Now $ctx).ToString('o');HistoryUtc='';Filled=0D;Amount=0D;Remaining=[decimal]$intent.Qty;Response='';Issue='';FeeStatus='UNCONFIRMED'}

  $book.Orders+=,$node;$book.Revision++;At58T-Save $ctx $book

  try{

   if($testTransport){$response=& $testTransport $packet}else{$response=At58T-Wire $ctx $packet}

   $ack=At58O-Ack ([pscustomobject]@{State='SUBMITTING';LastResponse='';BrokerId=''}) $response

   $node.State=$ack.State;$node.Response=$ack.LastResponse;$node.BrokerId=$ack.BrokerId

   if($node.BrokerId -and (@($book.Orders|Where-Object {$_.Key -cne $key -and $_.Day -ceq $node.Day -and $_.BrokerId -ceq $node.BrokerId}).Count -or $node.BrokerId.Length -gt 11)){$node.BrokerId='';$node.State='UNKNOWN';$node.Issue='TRADE_ACK_ID'}

  }catch{$node.State='UNKNOWN';$node.Issue='TRADE_RESPONSE_UNKNOWN'}

  $book.Revision++;At58T-Save $ctx $book;return (At58S-Clone $node)

 }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}

}

function At58T-Reconcile($ctx,$book,$rows,$receiptBook,[string[]]$days,[datetime]$now){

 At58T-Validate $ctx $book;$next=At58S-Clone $book;$map=@{};$nodeMap=@{};$seen=@{}

 foreach($o in $next.Orders){$nodeMap[$o.Key]=$o}

 foreach($f in $next.Fills){$seen[$f.Key]=$f}

 foreach($r in $rows){$key=$r.Day+'|'+(At58E-Id $r.Id);if($map.ContainsKey($key)){At58-Fail 'TRADE_HISTORY_DUPLICATE' 'TRADING'};$map[$key]=$r}

 if($receiptBook -and ($receiptBook.Scope -cne $ctx.Scope -or $receiptBook.Symbol -cne $ctx.Symbol)){At58-Fail 'TRADE_RECEIPT_SCOPE' 'TRADING'}

 foreach($o in $next.Orders){

  if(!$o.BrokerId){continue};if($o.Day -cnotin $days){continue}

  $key=$o.Day+'|'+$o.BrokerId;$o.Issue=''

  if(!$map.ContainsKey($key)){$o.State='REVIEW';$o.Issue='TRADE_HISTORY_MISSING';continue}

  $r=$map[$key];$kind=if($o.Action -ceq 'NEW'){'1'}elseif($o.Action -ceq 'MODIFY'){'2'}else{'3'}

  $null=At58S-Num $r.Filled 0 $r.Qty $true;$null=At58S-Num $r.Remaining 0 $r.Qty $true

  if($r.Filled+$r.Remaining -gt $r.Qty){At58-Fail 'TRADE_HISTORY_QUANTITY' 'TRADING'}

  $root=if($o.Action -ceq 'NEW'){''}else{$nodeMap[$o.RootKey].BrokerId}

  $side=if($o.Intent.Side -ceq '매수'){'2'}else{'1'}

  if($r.Symbol -cne $ctx.Symbol -or $r.Side -cne $side -or $r.Qty -ne $o.Intent.Qty -or $r.Price -ne $o.Intent.Price -or $r.Kind -cne $kind -or (At58E-Id $r.Original $true) -cne $root){$o.State='REVIEW';$o.Issue='TRADE_HISTORY_TERMS';continue}

  $rejected=($r.Status -ceq '3' -or ($r.Reject -and $r.Reject -cnotmatch '^0+$'))

  $events=if($receiptBook){@($receiptBook.Events|Where-Object {$_.Day -ceq $o.Day -and $_.Id -ceq $o.BrokerId -and $_.Kind -ceq 'FILL'})}else{@()}

  foreach($e in $events){

   if($e.State -cne 'FILL_MATCHED_FEE_PENDING' -or $e.Symbol -cne $ctx.Symbol -or $e.Side -cne $side -or $e.Original -cne $root -or $e.Source -cne 'BROKER_NOTIFICATION' -or $e.Account -cnotmatch '^[a-f0-9]{64}$' -or $o.Action -ceq 'CANCEL'){$o.Issue='TRADE_FILL_REVIEW';continue}

   if(($side -ceq '2' -and $e.Price -gt $o.Intent.Price) -or ($side -ceq '1' -and $e.Price -lt $o.Intent.Price)){At58-Fail 'TRADE_FILL_LIMIT' 'TRADING'}

   if($next.Account -and $next.Account -cne $e.Account){At58-Fail 'TRADE_FILL_ACCOUNT' 'TRADING'};$next.Account=$e.Account

   if($seen.ContainsKey($e.Key)){if($seen[$e.Key].OrderKey -cne $o.Key -or $seen[$e.Key].Qty -ne $e.Qty -or $seen[$e.Key].Price -ne $e.Price){At58-Fail 'TRADE_FILL_CONFLICT' 'TRADING'};continue}

   $f=[pscustomobject]@{Key=$e.Key;OrderKey=$o.Key;Account=$e.Account;Day=$e.Day;Time=$e.Time;Qty=[decimal]$e.Qty;Price=[decimal]$e.Price;Amount=([decimal]$e.Qty*[decimal]$e.Price);Fee=$null;Tax=$null;Evidence='BROKER_NOTIFICATION_RECONCILED'}

   $next.Fills+=,$f;$seen[$f.Key]=$f;$o.Filled+=$f.Qty;$o.Amount+=$f.Amount

  }

  if($r.Filled -lt $o.Filled){At58-Fail 'TRADE_CUMULATIVE_REGRESSION' 'TRADING'}

  if($r.Filled -ne $o.Filled){$o.Issue='TRADE_FILL_DETAIL_MISSING'}

  if($o.Issue){$o.Remaining=[math]::Min($o.Remaining,($o.Intent.Qty-$o.Filled));$o.State='REVIEW';continue}

  if($rejected){if($o.Filled -gt 0){$o.State='REVIEW';$o.Issue='TRADE_REJECT_WITH_FILL'}else{$o.State='REJECTED';$o.Remaining=0D};continue}

  $o.Remaining=[decimal]$r.Remaining;$o.HistoryUtc=$now.ToString('o')

  if($r.Status -cnotin @('1','2')){$o.State='ACKNOWLEDGED';continue}

  if($o.Action -ceq 'CANCEL'){

   $parent=$nodeMap[$o.ParentKey]

   if($r.Status -ceq '2' -and $parent.Remaining -eq 0 -and $parent.State -cnotin @('REVIEW','UNKNOWN','SUBMITTING')){$o.State='CANCELLED';$o.Remaining=0D;if($parent.Filled -lt $parent.Intent.Qty){$parent.State='CANCELLED'}}else{$o.State='ACKNOWLEDGED'}

  }elseif($o.Remaining -gt 0){$o.State=if($o.Filled -gt 0){'PARTIAL'}else{'OPEN'}}

  elseif($o.Filled -eq $o.Intent.Qty){$o.State='FILLED'}

  else{$o.State='REVIEW';$o.Issue='TRADE_CLOSE_UNCONFIRMED'}

 }

 # A replacement or cancellation is confirmed only by both child and parent REST evidence.

 $children=@($next.Orders|Where-Object {$_.Action -cne 'NEW' -and $_.BrokerId -and $_.Day -cin $days});[array]::Reverse($children)

 foreach($o in $children){

  $parent=$nodeMap[$o.ParentKey];$rk=$o.Day+'|'+$o.BrokerId;$pk=$parent.Day+'|'+$parent.BrokerId

  if(!$map.ContainsKey($rk) -or !$map.ContainsKey($pk) -or $map[$rk].Status -cne '2' -or $map[$pk].Remaining -ne 0 -or $map[$rk].Reject -cnotin @('','0','0000')){continue}

  if($parent.Issue -cne 'TRADE_CLOSE_UNCONFIRMED' -and $parent.State -cnotin @('FILLED','REPLACED','CANCELLED')){continue}

  if($o.Action -ceq 'MODIFY' -and $o.State -cin @('OPEN','PARTIAL','FILLED','REPLACED','CANCELLED')){$parent.State='REPLACED';$parent.Issue='';$parent.Remaining=0D}

  elseif($o.Action -ceq 'CANCEL' -and !$o.Issue -and $map[$rk].Filled -eq 0){$o.State='CANCELLED';$o.Remaining=0D;$parent.State=if($parent.Filled -eq $parent.Intent.Qty){'FILLED'}else{'CANCELLED'};$parent.Issue='';$parent.Remaining=0D}

 }

 $next.LastUtc=$now.ToString('o');$next.Revision++;At58T-Validate $ctx $next;return $next

}

function At58T-Label([string]$state){

 $labels=@{SUBMITTING='전송 결과 확인 중';UNKNOWN='전송 결과 불명 · 재전송 금지';WARNING_REVIEW='증권사 경고 확인 필요';ACKNOWLEDGED='접수 · 확정 대기';OPEN='미체결';PARTIAL='부분 체결';FILLED='체결 완료';REPLACED='정정 완료';CANCELLED='취소 완료';REJECTED='거부';REVIEW='대조 확인 필요'}

 if($labels.ContainsKey($state)){return $labels[$state]};return $state

}

function At58T-Run($ctx,$s){

 $result=[pscustomobject]@{Mode='PREVIEW';ExecutionEnabled=$false;OrdersSent=0;Code='ORDER_PREVIEW_WAIT';Text='주문 관리 준비 · 실제 전송 꺼짐';Orders=@();FillCount=0;FeeStatus='UNCONFIRMED';Candidate=$null;Request=$null}

 $mutex=At58T-Lock $ctx;$held=$false

 try{

  try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true};if(!$held){At58-Fail 'TRADE_BUSY' 'TRADING'}

  $book=At58T-Load $ctx

  if($book.Orders.Count){

   $receipts=$null;$path=Join-Path $ctx.Root 'receipt-book.dpapi'

   if([IO.File]::Exists($path)){$receipts=(At58-Unprotect ([IO.File]::ReadAllText($path)) 'AT58-RECEIPTS-1')|ConvertFrom-Json}

   $rows=@($s.OrdersToday)+@(At58-Value $s 'PriorOrders');$days=@($s.Day);if(At58-Value $s 'PriorDay'){$days+=,$s.PriorDay}

   $book=At58T-Reconcile $ctx $book $rows $receipts $days (At58-Now $ctx);At58T-Save $ctx $book

  }

  $result.Orders=@($book.Orders|Select-Object -Last 100);$result.FillCount=@($book.Fills).Count

  if(@($book.Orders|Where-Object {$_.State -cin @('UNKNOWN','SUBMITTING','WARNING_REVIEW','REVIEW')}).Count){$result.Code='ORDER_REVIEW';$result.Text='주문 이력 확인 필요 · 중복 전송 차단'}

  elseif(!$s.Session.Live){$result.Code='MARKET_CLOSED';$result.Text='장외 대기 · 주문 전송 꺼짐'}

  else{

   $strategy=At58-Value $s 'Strategy';$candidate=At58-Value $strategy 'OrderCandidate'

   if($candidate){$result.Candidate=$candidate;At58T-Gate $ctx $s $book $candidate 'NEW';$result.Request=At58T-Packet $candidate;$result.Code='ORDER_PREVIEW_READY';$result.Text='주문 후보 검증 완료 · 실제 전송 꺼짐'}

  }

 }catch{$result.Code=(At58-Error $_).Code;$result.Text='주문 준비 보류 · '+$result.Code}

 finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}

 try{At58-Atomic (Join-Path $ctx.Root 'order-status.json') (@{RunId=$ctx.RunId;Utc=(At58-Now $ctx).ToString('o');Code=$result.Code;Mode='PREVIEW';ExecutionEnabled=$false;OrdersSent=0;Orders=$result.Orders.Count;Fills=$result.FillCount}|ConvertTo-Json -Compress)}catch{$result.Code='TRADE_STATUS_STORAGE';$result.Text='주문 상태 기록 확인 필요'}

 return $result

}



# Replayable strategy ledger for the isolated exchange simulator. Never writes a manual sheet.

function At58L-Project($source,$book,[string]$day){

 if($book.Mode -cne 'SIMULATED' -or $book.Symbol -cne $source.Symbol -or $book.Scope -cne $source.Scope){At58-Fail 'SIM_LEDGER_IDENTITY' 'SIMULATION'}

 $p=[pscustomobject]@{Qty=[decimal]$source.Ledger.Qty;Average=[decimal]$source.Ledger.Average;Cash=[decimal]$source.Ledger.Cash;Realized=[decimal]$source.Ledger.Realized;Held=@($source.Ledger.Held);Cycle=(At58S-Clone $source.Cycle);Anchors=(At58R-SeedAnchors $source);BuyCount=0;Orders=@();Goals=@();FeeEstimate=0D;Code='OK'}

 $groups=@{};$keys=@{};$ordered=New-Object 'Collections.Generic.List[object]'

 foreach($o in $book.Orders){$keys[$o.Key]=$o;if($o.Action -cne 'NEW'){continue}

  $i=$o.Intent;$id=[string](At58-Value $i 'GoalId')

  if($id -cnotmatch '^[a-f0-9]{64}$'){At58-Fail 'SIM_GOAL_IDENTITY' 'SIMULATION'}

  $null=At58S-Num $i.Stage 1 30 $true;$null=At58S-Num $i.GoalQty 1 100000000 $true;$null=At58S-Num $i.CycleId 1 100000 $true;$null=At58S-Num $i.Target 5 10000000

  if(!$groups.ContainsKey($id)){

   $g=[pscustomobject]@{Id=$id;CycleId=$i.CycleId;Stage=$i.Stage;Side=$i.Side;Target=$i.Target;GoalQty=$i.GoalQty;Entry=[bool]$i.Entry;EntryMode=(At58-Value $i 'EntryMode');ExitGap=(At58-Value $i 'ExitGap');RootKeys=@();Nodes=@();Filled=0D;Amount=0D;FeeEstimate=0D;Remaining=$i.GoalQty;State='';Day=$o.Day;Price=$i.Price}

   $groups[$id]=$g;$ordered.Add($g)

  };$g=$groups[$id]

  if($g.CycleId -ne $i.CycleId -or $g.Stage -ne $i.Stage -or $g.Side -cne $i.Side -or $g.Target -ne $i.Target -or $g.GoalQty -ne $i.GoalQty -or $g.Entry -ne $i.Entry -or $g.EntryMode -cne (At58-Value $i 'EntryMode') -or $g.ExitGap -ne (At58-Value $i 'ExitGap')){At58-Fail 'SIM_GOAL_CONFLICT' 'SIMULATION'}

  $g.RootKeys+=,$o.Key

 }

 foreach($o in $book.Orders){

  if(!$keys.ContainsKey($o.RootKey)){At58-Fail 'SIM_GOAL_ROOT' 'SIMULATION'}

  $g=$groups[$keys[$o.RootKey].Intent.GoalId];$g.Nodes+=,$o

 }

 foreach($f in $book.Fills){

  $o=$keys[$f.OrderKey];$g=$groups[$keys[$o.RootKey].Intent.GoalId];$g.Filled+=$f.Qty;$g.Amount+=$f.Amount

 }

 $capRows=At58-Value $book 'GoalCaps';$caps=@($capRows|Where-Object {$null -ne $_});if($caps.Count -gt 5000){At58-Fail 'SIM_GOAL_CAP' 'SIMULATION'}

 foreach($cap in $caps){if(!$groups.ContainsKey([string]$cap.GoalId) -or $groups[[string]$cap.GoalId].Side -cne '매수'){At58-Fail 'SIM_GOAL_CAP' 'SIMULATION'}}

 $today=@{}

 foreach($g in $ordered){

  if($g.Filled -gt $g.GoalQty){At58-Fail 'SIM_GOAL_OVERFILL' 'SIMULATION'}

  $limit=$g.GoalQty

  foreach($cap in $caps){if($cap.GoalId -ceq $g.Id){$n=At58S-Num $cap.Qty 0 $limit $true;if($g.Side -cne '매수' -or $n -lt $g.Filled){At58-Fail 'SIM_GOAL_CAP' 'SIMULATION'};$limit=$n}}

  $g.Remaining=$limit-$g.Filled

  $uncertain=@($g.Nodes|Where-Object {$_.State -cin @('SUBMITTING','UNKNOWN','WARNING_REVIEW','REVIEW')})

  $active=@($g.Nodes|Where-Object {$_.State -cin @('ACKNOWLEDGED','OPEN','PARTIAL')})

  if($limit -lt $g.GoalQty){$openRoots=@{};foreach($o in $active){if($o.Action -ceq 'CANCEL'){continue};if(!$openRoots.ContainsKey($o.RootKey)){$openRoots[$o.RootKey]=0D};$openRoots[$o.RootKey]=[math]::Max($openRoots[$o.RootKey],$o.Remaining)};$openQty=0D;foreach($n in $openRoots.Values){$openQty+=$n};if($g.Filled+$openQty -gt $limit){At58-Fail 'SIM_GOAL_CAP' 'SIMULATION'}}

  $g.State=if($uncertain.Count){'REVIEW'}elseif($active.Count){'ACTIVE'}elseif($g.Remaining -eq 0){'FILLED'}elseif($g.Filled -gt 0){'PARTIAL_CLOSED'}else{'CANCELLED'}

  if($g.Side -ceq '매수' -and @($g.Nodes|Where-Object {$_.Day -ceq $day -and $_.Action -cne 'CANCEL' -and $_.State -cne 'REJECTED'}).Count){$today[$g.Id]=$true}

  if($g.Filled -gt 0){

   if($g.Side -ceq '매수'){

    if($g.Stage -in $p.Held){At58-Fail 'SIM_STAGE_OCCUPIED' 'SIMULATION'}

    $entry=($g.Stage -eq 1 -and $p.Cycle.Phase -ceq '다음 사이클 대기')

    if($g.CycleId -ne ($p.Cycle.Id+$(if($entry){1}else{0})) -or $g.Entry -ne $entry){At58-Fail 'SIM_CYCLE_IDENTITY' 'SIMULATION'}

    if($entry){if($p.Qty -ne 0){At58-Fail 'SIM_CYCLE_BALANCE' 'SIMULATION'};$p.Cycle.Id++;$p.Cycle.Basis=$g.Amount/$g.Filled;$p.Cycle.Phase='운영중'}

    $g.FeeEstimate=[math]::Ceiling($g.Amount*$source.Policy.BuyFee)

    $exitGap=if($null -ne $g.ExitGap){$g.ExitGap}else{$source.Policy.SellGap};At58R-Anchor $p.Anchors $g.Stage ($g.Amount/$g.Filled) $exitGap $source.Policy

    $p.Average=($p.Qty*$p.Average+$g.Amount)/($p.Qty+$g.Filled);$p.Qty+=$g.Filled;$p.Cash-=$g.Amount+$g.FeeEstimate;$p.Realized-=$g.FeeEstimate;$p.Held+=,[int]$g.Stage

   }else{

    if($g.Stage -notin $p.Held -or $g.Filled -gt $p.Qty -or $g.CycleId -ne $p.Cycle.Id){At58-Fail 'SIM_STAGE_POSITION' 'SIMULATION'}

    if($g.Stage -eq 1 -and $g.GoalQty -ne $p.Qty){At58-Fail 'SIM_CYCLE_BALANCE' 'SIMULATION'}

    $g.FeeEstimate=[math]::Ceiling($g.Amount*$source.Policy.SellFee)

    $p.Realized+=$g.Amount-$g.Filled*$p.Average-$g.FeeEstimate;$p.Qty-=$g.Filled;$p.Cash+=$g.Amount-$g.FeeEstimate

    if($g.Remaining -eq 0){$p.Held=@($p.Held|Where-Object {$_ -ne $g.Stage});$p.Anchors.PSObject.Properties.Remove([string]$g.Stage)}

    if($p.Qty -eq 0){$p.Average=0D;if($g.Stage -ne 1 -or $g.Remaining -ne 0){At58-Fail 'SIM_CYCLE_BALANCE' 'SIMULATION'};$p.Cycle.Phase='다음 사이클 대기';$p.Cycle.Basis=$g.Amount/$g.Filled;if(At58R-Enabled $source.Policy){$p.Held=@()}}

   }

   $p.FeeEstimate+=$g.FeeEstimate;if($p.Cash -lt 0){At58-Fail 'SIM_LEDGER_CASH' 'SIMULATION'}

  }

  if($g.State -ceq 'REVIEW'){$p.Code='SIM_ORDER_REVIEW'}

  if($g.Nodes[-1].Action -ceq 'NEW' -and $g.Nodes[-1].State -ceq 'REJECTED'){$g.State='REVIEW';$p.Code='SIM_ORDER_REJECTED'}

  $p.Orders+=,[pscustomobject]@{Id=('PAPER-'+$g.Id.Substring(0,24));Day=$g.Day;Stage=$g.Stage;Side=$g.Side;Price=$g.Price;Qty=$limit;OriginalQty=$g.GoalQty;Filled=$g.Filled;Amount=$g.Amount;Fee=$g.FeeEstimate;State=$(if($g.State -cin @('ACTIVE','REVIEW')){if($g.State -ceq 'REVIEW'){'UNKNOWN'}elseif($g.Filled -gt 0){'PARTIAL'}else{'ACKNOWLEDGED'}}elseif($g.State -ceq 'PARTIAL_CLOSED'){'CANCEL_PENDING'}else{$g.State});GoalId=$g.Id;CycleId=$g.CycleId}

 }

 $p.BuyCount=@($source.Ledger.Rows|Where-Object {$_.Day -ceq $day -and $_.Side -ceq '매수'}).Count+$today.Count

 $p.Goals=$ordered.ToArray();return $p

}

function At58L-Candidate($source,$p,$s,[string]$market,$book){

 $effective=[pscustomobject]@{Policy=$source.Policy;Cycle=$p.Cycle};$plan=At58S-Plan $effective $p $s $market

 $plan|Add-Member Intent $null
 $dailyStages=At58-Value $p 'DailyStages'
 if($dailyStages){$plan|Add-Member DailyStages $dailyStages;if($plan.NextBuy -and !(At58D-Allow $dailyStages $plan.NextBuy.Stage)){$plan.NextBuy=$null}}

 if($p.Code -cne 'OK' -or @($p.Goals|Where-Object {$_.State -cin @('ACTIVE','REVIEW')}).Count){return $plan}

 $pending=@($p.Goals|Where-Object {$_.State -ceq 'PARTIAL_CLOSED'})

 if($pending.Count -gt 1){At58-Fail 'SIM_MULTIPLE_PARTIAL_GOALS' 'SIMULATION'}

 if($pending.Count){

  $g=$pending[0];$price=[decimal]$s.Quote.Price

  $target=$g.Target

  if((At58R-Enabled $source.Policy) -and $g.Side -ceq '매도'){$a=At58-Value $p.Anchors ([string]$g.Stage);if(!$a){At58-Fail 'STRATEGY_ANCHOR' 'STRATEGY'};$target=[math]::Max($target,$a.SellPrice)}

  $cross=if($g.Side -ceq '매도' -or ($g.Entry -and $g.EntryMode -cne 'RANGE')){$price -ge $target}else{$price -le $target}

  if(!$cross -or ($market -ceq '보합' -and !(At58N-Allow $source.Policy $s $g.Side $price))){return $plan}

  # A cancelled partial buy resumes at its original table target, without repricing to last trade.
  $orderPrice=if($g.Side -ceq '매수' -and (!$g.Entry -or $g.EntryMode -ceq 'RANGE')){At58O-BuyLimit $g.Target $s.Quote}else{[math]::Floor($price/$source.Policy.Tick)*$source.Policy.Tick}
  if($orderPrice -le 0){return $plan}
  $i=[pscustomobject]@{Symbol=$source.Symbol;Side=$g.Side;Stage=$g.Stage;Price=$orderPrice;Qty=$g.Remaining;Target=$g.Target;GoalId=$g.Id;GoalQty=$g.GoalQty;CycleId=$g.CycleId;Entry=$g.Entry;EntryMode=$g.EntryMode;ExitGap=$g.ExitGap}

  if($i.Side -ceq '매수'){

   if($plan.BuyStopped -or !$source.Policy.Regimes.$market.BuyEnabled){return $plan}

   $today=@($book.Orders|Where-Object {$_.Day -ceq $s.Day -and $_.Action -ceq 'NEW' -and $_.Intent.GoalId -ceq $g.Id}).Count

   if($dailyStages){if(!(At58D-Allow $dailyStages $g.Stage)){return $plan}}elseif(!$today -and $p.BuyCount -ge $plan.MaxBuys){return $plan}

   $budget=$source.Policy.Principal+$(if($source.Policy.Reinvest){$p.Realized}else{0D})

   $cap=[math]::Max(0D,[math]::Min([math]::Min($p.Cash-$source.Policy.Principal*$plan.ReserveRatio,$s.Cash.Orderable),($budget*$source.Policy.MaxInvest-$p.Qty*$p.Average)))

   if($i.Qty*$i.Price+[math]::Ceiling($i.Qty*$i.Price*$source.Policy.BuyFee) -gt $cap){return $plan}

  }

  $plan.Intent=$i;return $plan

 }

 if($plan.Candidate.Count){

  $i=At58S-Clone $plan.Candidate[0];$entry=($i.Side -ceq '매수' -and $i.Stage -eq 1 -and $p.Cycle.Phase -ceq '다음 사이클 대기')

  foreach($pair in @{Symbol=$source.Symbol;GoalId=(At58-Hash ($source.Scope+'|'+$source.Hash+'|'+$p.Cycle.Id+'|'+$book.Orders.Count+'|'+$i.Side+'|'+$i.Stage));GoalQty=$i.Qty;CycleId=($p.Cycle.Id+$(if($entry){1}else{0}));Entry=$entry}.GetEnumerator()){$i|Add-Member $pair.Key $pair.Value}

  if(At58R-Enabled $source.Policy){$i|Add-Member ExitGap ($source.Policy.SellGap*$source.Policy.Regimes.$market.SellGap);$i|Add-Member EntryMode $(if($entry -and $market -ceq '보합'){'RANGE'}else{'BREAKOUT'})}

  $plan.Intent=$i

 };return $plan

}



# In-process fake exchange. All order transport is a local callback; no broker key is copied.

function At58Sim-Context($owner,[datetime]$now){

 $root=Join-Path $owner.Root 'order-simulation-v1'

 $ctx=At58-Context $root $owner.Symbol ([pscustomobject]@{AppKey=('SIMULATION|'+$owner.Scope);AppSecret='NOT_A_BROKER_CREDENTIAL'})

 $ctx.OrderMode='SIMULATED';$ctx.RunId=$owner.RunId;$ctx.ManagementRoot=$root;$ctx.NoWait=$true;$fixed=$now;$ctx.Clock={$fixed}.GetNewClosure()

 $ctx.Transport={At58-Fail 'SIM_NETWORK_FORBIDDEN' 'SIMULATION'};$ctx.Sim=$null;$ctx.SimFaults=@{};$ctx.ParentManagementRoot=$(if(At58-Value $owner 'RequireSimRuntime'){$owner.ManagementRoot}else{''})

 return $ctx

}

function At58Sim-Save($ctx){

 At58-Atomic (Join-Path $ctx.Root 'exchange.dpapi') (At58-Protect ($ctx.Sim|ConvertTo-Json -Depth 40 -Compress) 'AT58-SIM-EXCHANGE-1')

}

function At58Sim-Load($ctx,$source,$snapshot){

 $path=Join-Path $ctx.Root 'exchange.dpapi'

 if([IO.File]::Exists($path)){

  try{$state=(At58-Unprotect ([IO.File]::ReadAllText($path)) 'AT58-SIM-EXCHANGE-1')|ConvertFrom-Json}catch{At58-Fail 'SIM_STORAGE' 'SIMULATION'}

  if($state.Schema -cne 'AT-SIM-EXCHANGE-1' -or $state.Scope -cne $ctx.Scope -or $state.Symbol -cne $ctx.Symbol){At58-Fail 'SIM_IDENTITY' 'SIMULATION'}

  if($state.SourceHash -cne $source.Hash){

   if(!(At58R-Migrate $source $state.SourceHash) -or $state.Seed.Hash -cne $state.SourceHash){At58-Fail 'SIM_SOURCE_CHANGED' 'SIMULATION'}

   $state.SourceHash=$source.Hash;$state.Seed.Hash=$source.Hash;$state.Seed.Policy=At58S-Clone $source.Policy

   $state.LastRunId='';$state.Proof='';$state.Confirmations=0;$state|Add-Member NeutralUpgradePending $true -Force

  }

  if($state.Rows.Count -gt 5000 -or $state.Events.Count -gt 50000 -or $state.Trades.Count -gt 50000){At58-Fail 'SIM_LIMIT' 'SIMULATION'}

 }else{

  if([IO.File]::Exists((At58T-Path $ctx))){At58-Fail 'SIM_EXCHANGE_MISSING' 'SIMULATION'}

  $seed=At58S-Clone $source;$seed.Scope=$ctx.Scope;$seed.Ledger.Qty=[decimal]$snapshot.TargetQty;$seed.Ledger.Average=[decimal]$snapshot.TargetAverage

  $state=[pscustomobject]@{Schema='AT-SIM-EXCHANGE-1';Mode='SIMULATED';Scope=$ctx.Scope;Symbol=$ctx.Symbol;SourceHash=$source.Hash;Seed=$seed;InitialBrokerCash=([math]::Min($source.Ledger.Cash,$snapshot.Cash.Orderable));Rows=@();Events=@();Trades=@();NextId=100000;Sequence=0;Posts=0;LastUtc='';LastRunId='';LastDay='';LastVolume=0D;Market='';MarketCandidate='';MarketCandidateUtc='';Proof='';Confirmations=0;AuthUntil='2000-01-01T00:00:00Z';AuthRefreshes=0}

 }

 # Upgrade the simulation checkpoint without resetting any existing order or ledger.

 if(!$state.PSObject.Properties['LastSessionLive']){$state|Add-Member LastSessionLive $false}

 if(!$state.PSObject.Properties['LastQuoteBasis']){$state|Add-Member LastQuoteBasis ''}

 $ctx.Sim=$state;return $state

}

function At58Sim-Event($ctx,$row,[bool]$fill,[decimal]$qty,[decimal]$price){

 $now=At58-Now $ctx;$ctx.Sim.Sequence++;$channel=if($fill){'ohhts_cntg_rslt'}else{'ohhts_cntg_infr'}

 $body=@{user_id='SIMULATOR';acno='00000001';asno='01';oder_no=$row.Id;orgl_oder_no=$(if($row.Original){$row.Original}else{'0'});deal_cls_code=$row.Side;stnd_iscd='KR7000000001';svc_id='CASH_SIM';pros_srno=[string]$ctx.Sim.Sequence}

 if($fill){$body.cntg_date=$row.Day;$body.cntg_pros_time=(At58-Kst $now).ToString('HHmmssfff');$body.cntg_prc=$price;$body.cntg_qty=$qty}

 else{$body.oder_date=$row.Day;$body.mbcr_oder_time=(At58-Kst $now).ToString('HHmmssfff');$body.aspr_prc=$price;$body.tlms_aspr_qty=$qty;$body.rctf_cncl_cls_code=$row.Kind;$body.aspr_rfus_reas_code=$row.Reject}

 return [pscustomobject]@{Schema='AT-RECEIPT-RAW-1';Scope=$ctx.Scope;ReceivedUtc=$now.ToString('o');Message=@{header=@{tr_cd=$channel;tr_key='SIMULATOR'};body=$body}}

}

function At58Sim-Fill($ctx,$row,[decimal]$qty,[decimal]$price){

 if($qty -le 0 -or $qty -gt $row.Remaining -or $row.Kind -ceq '3' -or $row.Status -cne '2'){At58-Fail 'SIM_FILL_QUANTITY' 'SIMULATION'}

 $row.Filled+=$qty;$row.Remaining-=$qty

 $raw=At58Sim-Event $ctx $row $true $qty $price

 $ctx.Sim.Trades+=,[pscustomobject]@{Id=$row.Id;Day=$row.Day;Qty=$qty;Price=$price;Side=$row.Side;GoalId=$row.GoalId;Amount=($qty*$price);Sequence=$ctx.Sim.Sequence}

 if(!(At58-Value $ctx.SimFaults 'DropFill')){$ctx.Sim.Events+=,$raw}

 if(At58-Value $ctx.SimFaults 'DuplicateFill'){$ctx.Sim.Events+=,$raw}

}

function At58Sim-Balance($ctx){

 $seed=$ctx.Sim.Seed;$qty=[decimal]$seed.Ledger.Qty;$avg=[decimal]$seed.Ledger.Average;$cash=[decimal]$ctx.Sim.InitialBrokerCash;$fees=@{}

 foreach($t in $ctx.Sim.Trades){

  if(!$fees.ContainsKey($t.GoalId)){$fees[$t.GoalId]=@{Amount=0D;Fee=0D}};$g=$fees[$t.GoalId];$g.Amount+=$t.Amount

  $rate=if($t.Side -ceq '2'){$seed.Policy.BuyFee}else{$seed.Policy.SellFee};$fee=[math]::Ceiling($g.Amount*$rate)-$g.Fee;$g.Fee+=$fee

  if($t.Side -ceq '2'){$avg=($qty*$avg+$t.Amount)/($qty+$t.Qty);$qty+=$t.Qty;$cash-=$t.Amount+$fee}else{$qty-=$t.Qty;$cash+=$t.Amount-$fee;if($qty -eq 0){$avg=0D}}

  if($qty -lt 0 -or $cash -lt 0){At58-Fail 'SIM_EXCHANGE_BALANCE' 'SIMULATION'}

 }

 $reserved=0D;foreach($r in @($ctx.Sim.Rows|Where-Object {$_.Side -ceq '2' -and $_.Kind -cne '3' -and $_.Status -ceq '2' -and $_.Remaining -gt 0})){$reserved+=$r.Remaining*$r.Price+[math]::Ceiling($r.Remaining*$r.Price*$seed.Policy.BuyFee)}

 return [pscustomobject]@{Qty=$qty;Average=$avg;Cash=$cash;Orderable=[math]::Max(0D,($cash-$reserved))}

}

function At58Sim-Wire($ctx,$packet){

 if($ctx.OrderMode -cne 'SIMULATED' -or !$ctx.Sim -or $ctx.Sim.Mode -cne 'SIMULATED'){At58-Fail 'SIM_TRANSPORT_ISOLATION' 'SIMULATION'}

 $b=$packet.Body;$day=(At58-Kst (At58-Now $ctx)).ToString('yyyyMMdd');$parent=$null

 if($packet.Method -cne 'POST' -or $b.warn_cnfr_yn -cne 'N' -or $b.exch_kind_code -cne '01' -or $b.oder_cls_code -cne '01' -or $b.iscd -cne ('A'+$ctx.Symbol)){At58-Fail 'SIM_REQUEST' 'SIMULATION'}

 $action=$packet.Action;$expected=if($action -ceq 'NEW'){@('/trading/v1/orders/buy','/trading/v1/orders/sell')}elseif($action -ceq 'MODIFY'){@('/trading/v1/orders/modify')}elseif($action -ceq 'CANCEL'){@('/trading/v1/orders/cancel')}else{@()}

 if($packet.Path -cnotin $expected){At58-Fail 'SIM_REQUEST' 'SIMULATION'}

 $book=At58T-Load $ctx;$pending=@($book.Orders|Where-Object {$_.State -ceq 'SUBMITTING'})

 if($pending.Count -ne 1){At58-Fail 'SIM_INTENT_MISSING' 'SIMULATION'};$node=$pending[0]

 if($action -cne 'NEW'){

  $parents=@($ctx.Sim.Rows|Where-Object {$_.Day -ceq $day -and $_.Id -ceq ([string]$b.orgl_oder_no)})

  if($parents.Count -ne 1 -or $parents[0].Remaining -ne $b.odqt -or $b.whol_rctf_cncl_yn -cne 'Y'){At58-Fail 'SIM_PARENT' 'SIMULATION'};$parent=$parents[0]

 }

 $ctx.Sim.NextId++;$ctx.Sim.Posts++

 $row=[pscustomobject]@{Day=$day;Id=[string]$ctx.Sim.NextId;Symbol=$ctx.Symbol;Side=$(if($action -ceq 'NEW'){if($packet.Path.EndsWith('/buy')){'2'}else{'1'}}else{$parent.Side});Qty=[decimal]$b.odqt;Filled=0D;Remaining=$(if($action -ceq 'CANCEL'){0D}else{[decimal]$b.odqt});Price=[decimal]$b.oder_unpr;Kind=$(if($action -ceq 'NEW'){'1'}elseif($action -ceq 'MODIFY'){'2'}else{'3'});Original=$(if($parent){if($parent.Original){$parent.Original}else{$parent.Id}}else{''});Status='2';Reject='0000';GoalId=$node.Intent.GoalId}

 if(At58-Value $ctx.SimFaults 'Reject'){$row.Status='3';$row.Reject='S607';$row.Remaining=0D}

 elseif($parent){

  $race=At58-Value $ctx.SimFaults 'CancelRaceQty'

  if($action -ceq 'CANCEL' -and $race){At58Sim-Fill $ctx $parent ([decimal]$race) ([decimal]$parent.Price)}

  $parent.Remaining=0D

 }

 $ctx.Sim.Rows+=,$row;$ctx.Sim.Events+=,(At58Sim-Event $ctx $row $false $row.Qty $row.Price)

 At58Sim-Save $ctx # Exchange acceptance is durable before returning the response.

 if(At58-Value $ctx.SimFaults 'LoseResponse'){At58-Fail 'SIM_RESPONSE_LOST' 'SIMULATION'}

 return @{rsp_cd='0001';data=@{oder_no=$row.Id;warn_cls_code='0'}}

}

function At58Sim-Reconcile($ctx){

 $book=At58T-Load $ctx;$receipts=At58E-NewBook $ctx.Scope $ctx.Symbol (At58-Now $ctx);$receipts.HistoryInitialized=$true

 foreach($raw in $ctx.Sim.Events){At58E-Add $receipts (At58E-Decode $raw $ctx.Scope)}

 $days=@($ctx.Sim.Rows|Select-Object -ExpandProperty Day -Unique);if(!$days.Count){$days=@((At58-Kst (At58-Now $ctx)).ToString('yyyyMMdd'))}

 At58E-Reconcile $receipts @($ctx.Sim.Rows) $days (At58-Now $ctx)

 $book=At58T-Reconcile $ctx $book @($ctx.Sim.Rows) $receipts $days (At58-Now $ctx);At58T-Save $ctx $book

 return [pscustomobject]@{Book=$book;Receipts=$receipts}

}

function At58Sim-Snapshot($ctx,$market,$reconciled){

 $s=At58S-Clone $market;$balance=At58Sim-Balance $ctx;$s.Scope=$ctx.Scope;$s.TargetQty=$balance.Qty;$s.TargetAverage=$balance.Average;$s.Cash.Orderable=$balance.Orderable

 $s.Holdings=@([pscustomobject]@{Symbol=$ctx.Symbol;Product='1';Class='주식일반';Qty=$balance.Qty})

 $s.OrdersToday=@($ctx.Sim.Rows|Where-Object {$_.Day -ceq $s.Day});$s.OpenOrdersToday=@($s.OrdersToday|Where-Object {$_.Remaining -gt 0})

 $s.PriorUnresolved=@($ctx.Sim.Rows|Where-Object {$_.Day -cne $s.Day -and $_.Remaining -gt 0});$s.PriorOrders=@();$s.PriorDay=$s.Day

 $s|Add-Member Execution ([pscustomobject]@{Connected=$true;ReceiptAck=$true;FillAck=$true;Pending=@($reconciled.Receipts.Events|Where-Object {$_.State -cnotin @('RECEIPT_MATCHED','FILL_MATCHED_FEE_PENDING','REJECTED')}).Count;Gaps=$reconciled.Receipts.Gaps.Count}) -Force

 $s|Add-Member Strategy ([pscustomobject]@{Reconciled=($ctx.Sim.Confirmations -ge 2);Confirmations=$ctx.Sim.Confirmations}) -Force

 return $s

}

function At58Sim-Submit($ctx,$s,$intent,[string]$action='NEW',[string]$parent=''){

 if($ctx.ParentManagementRoot){

  $runtime=$null;try{$runtime=[IO.File]::ReadAllText((Join-Path $ctx.ParentManagementRoot 'runtime.json'))|ConvertFrom-Json}catch{}

  if(!$runtime -or $runtime.RunId -cne $ctx.RunId -or !$runtime.DesiredRunning -or ((At58-Now $ctx)-(At58S-Utc $runtime.Utc)).TotalSeconds -gt 20 -or ((At58-Now $ctx)-(At58S-Utc $runtime.Utc)).TotalSeconds -lt -5){At58-Fail 'SIM_PAUSED' 'SIMULATION'}

 }

 $decision=At58-Hash ($intent.GoalId+'|'+$s.CompletedUtc+'|'+$action+'|'+$parent)

 $callback={param($packet) At58Sim-Wire $ctx $packet}.GetNewClosure()

 return (At58T-Submit $ctx $s $intent $action $decision $parent $callback)

}

function At58Sim-Message([string]$code){

 $labels=@{SIM_ORDER='통합 모의 주문 접수';SIM_WAIT='통합 모의 운용 · 조건 대기';SIM_DUPLICATE='같은 시세 · 중복 처리 없음';SIM_RECONCILE_WAIT='가상 계좌·원장 연속 대조 중';SIM_ORDER_REVIEW='가상 주문 결과 확인 필요 · 추가 주문 중지';SIM_FILL_GAP='가상 체결 통보 누락 · 원장 반영 보류';SIM_STALE='오래된 시세 · 모의 처리 보류';SIM_CANCEL='가상 주문 잔량 취소 접수';MARKET_CLOSED='장외 대기 · 통합 모의 운용';PRE_CLOSE='마감 3분 전 · 모의 신규 주문 중지';SIM_SOURCE_CHANGED='원본 변경 · 기존 모의 이력 보존';SIM_AUTH_WAIT='가상 인증 복구 대기';SIM_MARKET_WAIT='시장 전환 확인 중';SIM_INPUT_WAIT='실계좌·전략 입력 확인 대기';SIM_PARTIAL_WAIT='부분 체결 잔량 · 가격 조건 대기'}

 $labels['SIM_VOLUME_REGRESSION']='거래량 역행 · 모의 체결 보류';$labels['SIM_PRIOR_ORDER_REVIEW']='전일 가상 주문 미확정 · 추가 주문 중지';$labels['SIM_ORDER_REJECTED']='가상 주문 거부 · 자동 재시도 중지'

 if($labels.ContainsKey($code)){return $labels[$code]};return ('통합 모의 확인 필요 ['+$code+']')

}

function At58Sim-Result($ctx,$p,$book,$plan,[string]$code){

 $actions=@($book.Orders|Select-Object -Last 100)

 return [pscustomobject]@{RiskSummary=$(if($plan -and (At58R-Enabled $ctx.Sim.Seed.Policy)){'현금 최소 '+((100*$plan.ReserveRatio).ToString('0.#'))+'% · 하루 매수 '+$plan.MaxBuys+'회 · 손실 '+((100*$plan.LossStop).ToString('0.#'))+'% 신규매수 중단'+$(if($plan.BuyStopped){' · 현재 매수 중단'}else{''})}else{''});Mode='SIMULATED_CHAIN';ExecutionEnabled=$false;OrdersSent=0;Code=$code;Text=(At58Sim-Message $code);Market=$ctx.Sim.Market;Reconciled=($ctx.Sim.Confirmations -ge 2);Confirmations=$ctx.Sim.Confirmations;PaperOrderCount=$p.Orders.Count;PaperFillCount=$book.Fills.Count;PaperQty=$p.Qty;PaperCash=$p.Cash;PaperRealized=($p.Realized-$ctx.Sim.Seed.Ledger.Realized);FeeEstimate=$p.FeeEstimate;FeeStatus='SIMULATED_RATE';Cycle=$p.Cycle;Held=$p.Held;Orders=@($p.Orders|Select-Object -Last 100);Actions=$actions;Plan=$(if($plan){@($plan.Rows)}else{@()});NextBuy=$(if($plan){$plan.NextBuy}else{$null});NextSell=$(if($plan){$plan.NextSell}else{$null});Posts=$ctx.Sim.Posts;AuthRefreshes=$ctx.Sim.AuthRefreshes}

}

function At58Sim-Step($owner,$source,$market,[string]$regime,[bool]$inputReady=$true,$faults=@{}){

 if($source.Scope -cne $owner.Scope -or $market.Scope -cne $owner.Scope -or $source.Symbol -cne $owner.Symbol -or $market.Symbol -cne $owner.Symbol){At58-Fail 'SIM_INPUT_IDENTITY' 'SIMULATION'}

 $now=At58-Now $owner;$ctx=At58Sim-Context $owner $now;$ctx.SimFaults=$faults;$mutex=[Threading.Mutex]::new($false,('Local\AT58Simulation_'+(At58-Hash $ctx.Root)));$held=$false

 try{

  try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true};if(!$held){At58-Fail 'SIM_BUSY' 'SIMULATION'}

  $state=At58Sim-Load $ctx $source $market;$seed=At58S-Clone $state.Seed;$seed.Day=$market.Day

  $book=At58T-Load $ctx;$p=At58L-Project $seed $book $market.Day;$plan=$null;$code='SIM_WAIT'

  $stamp=At58S-Utc $market.CompletedUtc;$kst=At58-Kst $now;$volume=At58-Value $market.Quote 'Volume'

  if($state.LastUtc -and $stamp -le (At58S-Utc $state.LastUtc)){return (At58Sim-Result $ctx $p $book $plan 'SIM_DUPLICATE')}

  if(!$inputReady){return (At58Sim-Result $ctx $p $book $plan 'SIM_INPUT_WAIT')}

  if(($now-$stamp).TotalSeconds -lt -2 -or ($now-$stamp).TotalSeconds -gt 15 -or ($now-(At58S-Utc $market.Quote.ReceivedUtc)).TotalSeconds -gt 30 -or (At58S-Utc $market.Quote.ReceivedUtc) -gt $now.AddSeconds(2)){return (At58Sim-Result $ctx $p $book $plan 'SIM_STALE')}

  if((At58S-Utc $state.AuthUntil) -le $now){

   if(At58-Value $faults 'AuthFailure'){return (At58Sim-Result $ctx $p $book $plan 'SIM_AUTH_WAIT')}

   $state.AuthRefreshes++;$state.AuthUntil=$now.AddMinutes(30).ToString('o')

  }

  $live=($market.Session.Live -and $market.Quote.Mode -ceq 'LIVE_REST' -and $market.Day -ceq $kst.ToString('yyyyMMdd') -and $market.Quote.BasisDay -ceq $market.Day -and $kst -lt (At58S-SessionTime $market.Session.Close))

  $sessionChange=($state.LastSessionLive -ne $live -or $state.LastQuoteBasis -cne $market.Quote.BasisDay)

  $continuity=($state.LastUtc -and $state.LastRunId -ceq $owner.RunId -and $state.LastDay -ceq $market.Day -and ($stamp-(At58S-Utc $state.LastUtc)).TotalSeconds -le 90 -and $live -and !$sessionChange)

  $paused=$false;$pausePath=Join-Path $owner.Root 'simulation-pause.json'

  if([IO.File]::Exists($pausePath)){

   $pause=[IO.File]::ReadAllText($pausePath)|ConvertFrom-Json;$pauseUtc=At58S-Utc $pause.Utc

   if($pauseUtc -gt $now.AddSeconds(5)){At58-Fail 'SIM_PAUSE_TIME' 'SIMULATION'}

   $paused=($state.LastUtc -and $pauseUtc -ge (At58S-Utc $state.LastUtc));if($paused){$continuity=$false}

  }

  $null=At58S-Num $market.Quote.Price 0.00001 10000000

  if($null -ne $volume){$volume=At58S-Num $volume 0 1000000000000 $true}

  if($continuity -and $null -ne $volume -and $volume -lt $state.LastVolume){return (At58Sim-Result $ctx $p $book $plan 'SIM_VOLUME_REGRESSION')}

  if($live -and $continuity -and $null -ne $volume -and $market.Quote.Tick -eq 5){

   $delta=[math]::Max(0D,([decimal]$volume-$state.LastVolume))

   foreach($row in @($state.Rows|Where-Object {$_.Day -ceq $market.Day -and $_.Remaining -gt 0 -and $_.Kind -cne '3' -and $_.Status -ceq '2'})){

    $cross=if($row.Side -ceq '2'){$market.Quote.Price -le $row.Price}else{$market.Quote.Price -ge $row.Price}

    if($cross -and $delta -gt 0){$q=[math]::Min($row.Remaining,$delta);At58Sim-Fill $ctx $row $q ([decimal]$row.Price);$delta-=$q}

   }

  }

  if(!$state.Market){$state.Market=$regime}

  $stable=$true

  if($state.Market -cne $regime){

   $stable=$false;if($state.MarketCandidate -cne $regime){$state.MarketCandidate=$regime;$state.MarketCandidateUtc=$market.CompletedUtc}

   elseif(($stamp-(At58S-Utc $state.MarketCandidateUtc)).TotalSeconds -ge 30){$state.Market=$regime;$state.MarketCandidate='';$stable=$true}

  }else{$state.MarketCandidate=''}

  if($state.LastRunId -cne $owner.RunId -or $state.LastDay -cne $market.Day -or $paused -or $sessionChange){$state.Proof='';$state.Confirmations=0}

  $state.LastSessionLive=$live;$state.LastQuoteBasis=$market.Quote.BasisDay

  $state.LastUtc=$market.CompletedUtc;$state.LastRunId=$owner.RunId;$state.LastDay=$market.Day;$state.LastVolume=if($null -ne $volume){[decimal]$volume}else{0D}

  At58Sim-Save $ctx

  $reconciled=At58Sim-Reconcile $ctx;$book=$reconciled.Book;$p=At58L-Project $seed $book $market.Day;$balance=At58Sim-Balance $ctx

  $offset=$seed.Ledger.Cash-$state.InitialBrokerCash

  if($p.Qty -ne $balance.Qty -or [math]::Abs($p.Average-$balance.Average) -gt .00001 -or [math]::Abs(($p.Cash-$offset)-$balance.Cash) -gt .01 -or $reconciled.Receipts.Gaps.Count){$state.Confirmations=0;$state.Proof='';$code='SIM_FILL_GAP'}

  else{

   $proof=At58-Hash (@($source.Hash,$market.Day,$p.Qty,$p.Average,$p.Cash,$p.Cycle.Id,$p.Cycle.Phase,($p.Held -join ',')) -join '|')

   if($proof -ceq $state.Proof){$state.Confirmations=[math]::Min(2,$state.Confirmations+1)}else{$state.Proof=$proof;$state.Confirmations=1}

  }

  At58-Atomic (Join-Path $ctx.Root 'runtime.json') (@{RunId=$ctx.RunId;DesiredRunning=$true;Utc=$now.ToString('o')}|ConvertTo-Json -Compress)

  $s=At58Sim-Snapshot $ctx $market $reconciled;$s=At58R-Pause $state $seed $s $regime

 if($stable -and $state.Confirmations -ge 2 -and $p.Code -ceq 'OK'){if(At58R-LimitGoals $ctx $seed $p $s $state.Market $book){$p=At58L-Project $seed $book $market.Day}}

 $plan=At58L-Candidate $seed $p $s $state.Market $book

  if($p.Code -cne 'OK'){$code=$p.Code}

  if($s.PriorUnresolved.Count){$code='SIM_PRIOR_ORDER_REVIEW'}

  $active=@($book.Orders|Where-Object {$_.State -cin @('OPEN','PARTIAL')})

  $pending=@($book.Orders|Where-Object {$_.State -cin @('ACKNOWLEDGED','SUBMITTING','UNKNOWN','WARNING_REVIEW','REVIEW')})

  $closing=$live -and $kst -ge (At58S-SessionTime $market.Session.Close).AddMinutes(-3)

  $upgrade=[bool](At58-Value $state 'NeutralUpgradePending')

  if($upgrade -and !$active.Count -and !$pending.Count){$state.NeutralUpgradePending=$false;$upgrade=$false}

  $neutralCancel=($state.Market -ceq '보합' -and $active.Count -eq 1 -and $active[0].Intent.Side -ceq '매수' -and !(At58N-Allow $seed.Policy $s '매수' ([decimal]$s.Quote.Price)))

  $riskCancel=((At58R-Enabled $seed.Policy) -and $active.Count -eq 1 -and $active[0].Intent.Side -ceq '매수' -and ($plan.BuyStopped -or !$seed.Policy.Regimes.($state.Market).BuyEnabled))

  if($code -cin @('SIM_FILL_GAP','SIM_ORDER_REVIEW','SIM_ORDER_REJECTED','SIM_PRIOR_ORDER_REVIEW')){}

  elseif(!$live){$code='MARKET_CLOSED'}

  elseif($active.Count -eq 1 -and !$pending.Count -and ($closing -or !$stable -or $upgrade -or $neutralCancel -or $riskCancel -or (At58-Value $faults 'Command') -ceq 'CANCEL')){

   $o=$active[0];$i=At58S-Clone $o.Intent;$i.Qty=$o.Remaining;$null=At58Sim-Submit $ctx $s $i 'CANCEL' $o.Key;$code='SIM_CANCEL'

  }

  elseif($upgrade){$code='SIM_INPUT_WAIT'}

  elseif($closing){$code='PRE_CLOSE'}

  elseif(!$stable){$code='SIM_MARKET_WAIT'}

  elseif($state.Confirmations -lt 2){$code='SIM_RECONCILE_WAIT'}

  elseif($active.Count -eq 1 -and !$pending.Count -and (At58-Value $faults 'Command') -ceq 'MODIFY'){

   $o=$active[0];$i=At58S-Clone $o.Intent;$i.Qty=$o.Remaining;$i.Price=At58S-Num (At58-Value $faults 'Price') 5 10000000 $true

   if(($i.Side -ceq '매도' -and $i.Price -lt $i.Target) -or ($i.Side -ceq '매수' -and (!$i.Entry -or (At58-Value $i 'EntryMode') -ceq 'RANGE') -and $i.Price -gt $i.Target)){At58-Fail 'SIM_MODIFY_TARGET' 'SIMULATION'}

   $null=At58Sim-Submit $ctx $s $i 'MODIFY' $o.Key;$code='SIM_ORDER'

  }

  elseif($null -eq $volume -or $market.Quote.Tick -ne 5){$code='QUOTE_DETAIL_WAIT'}

  elseif(!$pending.Count -and !$active.Count -and $plan.Intent){$null=At58Sim-Submit $ctx $s $plan.Intent;$code='SIM_ORDER'}

  elseif(@($p.Goals|Where-Object {$_.State -ceq 'PARTIAL_CLOSED'}).Count){$code='SIM_PARTIAL_WAIT'}

  At58Sim-Save $ctx;$book=At58T-Load $ctx;$p=At58L-Project $seed $book $market.Day

  if($p.Code -cne 'OK'){$code=$p.Code}

  return (At58Sim-Result $ctx $p $book $plan $code)

 }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}

}



function At58A-Pause([string]$root,[datetime]$now=[datetime]::UtcNow){

 try{At58-Atomic (Join-Path $root 'simulation-pause.json') (@{Utc=$now.ToString('o')}|ConvertTo-Json -Compress);return $true}catch{return $false}

}

function At58A-Run($ctx,$s){

 $now=At58-Now $ctx

 $strategy=[pscustomobject]@{Mode='PAPER';ExecutionEnabled=$false;Code='STRATEGY_INPUT_WAIT';Text='';Reconciled=$false;Confirmations=0;Market='';NextBuy=$null;NextSell=$null;PaperOrderCount=0;PaperFillCount=0;PaperQty=$null;PaperCash=$null;PaperRealized=$null;Plan=@();Orders=@();OrderCandidate=$null}

 $sim=[pscustomobject]@{Mode='SIMULATED_CHAIN';ExecutionEnabled=$false;OrdersSent=0;Code='SIM_INPUT_WAIT';Text=(At58Sim-Message 'SIM_INPUT_WAIT');Market='';Reconciled=$false;Confirmations=0;PaperOrderCount=0;PaperFillCount=0;PaperQty=$null;PaperCash=$null;PaperRealized=$null;FeeEstimate=0D;FeeStatus='SIMULATED_RATE';Cycle=$null;Held=@();Orders=@();Actions=@();Plan=@();NextBuy=$null;NextSell=$null;Posts=0;AuthRefreshes=0}

 try{

  $raw=(At58-Unprotect ([IO.File]::ReadAllText((Join-Path $ctx.Root 'strategy-input.dpapi'))) 'AT58-STRATEGY-INPUT-1')|ConvertFrom-Json

  $age=($now-(At58S-Utc $raw.Utc)).TotalSeconds;if($age -lt -5 -or $age -gt 120){At58-Fail 'STRATEGY_INPUT_WAIT' 'STRATEGY'}

  $source=At58S-Import $raw;$proof=At58S-Reconcile $source $s

  if(!$ctx.ContainsKey('StrategyProof') -or $ctx.StrategyProof -cne $proof){$ctx.StrategyProof=$proof;$ctx.StrategyConfirmations=1}

  elseif(!$ctx.ContainsKey('StrategyProofUtc') -or (At58S-Utc $s.CompletedUtc) -gt (At58S-Utc $ctx.StrategyProofUtc)){$ctx.StrategyConfirmations=[math]::Min(2,$ctx.StrategyConfirmations+1)}

  $ctx.StrategyProofUtc=$s.CompletedUtc;$strategy.Confirmations=$ctx.StrategyConfirmations;$strategy.Reconciled=($ctx.StrategyConfirmations -ge 2)

  $days=At58-List $ctx '/market/v1/candles/days' @{mrkt_div_code='J';iscd=$ctx.Symbol;mod_stpr_cls_code='0'}

  $market=At58S-Market $days $s $source.Policy;$strategy.Market=$market.Name

  if($ctx.ManagementRoot){

   $runtime=[IO.File]::ReadAllText((Join-Path $ctx.ManagementRoot 'runtime.json'))|ConvertFrom-Json

   if($runtime.RunId -cne $ctx.RunId -or !$runtime.DesiredRunning -or ((At58-Now $ctx)-(At58S-Utc $runtime.Utc)).TotalSeconds -gt 20){At58-Fail 'STRATEGY_PAUSED' 'STRATEGY'}

  }

  $ready=$strategy.Reconciled -and !@($s.OpenOrdersToday|Where-Object {$_.Symbol -ceq $s.Symbol}).Count -and !@($s.PriorUnresolved|Where-Object {$_.Symbol -ceq $s.Symbol}).Count

  $ctx.RequireSimRuntime=[bool]$ctx.ManagementRoot

  $sim=At58Sim-Step $ctx $source $s $market.Name $ready

  $strategy.Code=$sim.Code;$strategy.Text=$sim.Text

  # Keep the actual-account preview separate from the simulated account and its profits.

  $real=At58S-NewPaper $source $s;$real.BuyCount=@($source.Ledger.Rows|Where-Object {$_.Day -ceq $s.Day -and $_.Side -ceq '매수'}).Count

  $plan=At58S-Plan $source $real $s $market.Name;$strategy.Plan=$plan.Rows;$strategy.NextBuy=$plan.NextBuy;$strategy.NextSell=$plan.NextSell

  if($ready -and $s.Session.Live -and $plan.Candidate.Count){$c=At58S-Clone $plan.Candidate[0];$c|Add-Member Symbol $s.Symbol;$strategy.OrderCandidate=$c}

 }catch{

  $code=(At58-Error $_).Code;if($code -ceq 'UNEXPECTED'){$code='SIM_INPUT_WAIT'}

  $strategy.Code=$code;$strategy.Text=At58Sim-Message $code;$strategy.Reconciled=$false;$strategy.Confirmations=0;$ctx.StrategyProof='';$ctx.StrategyConfirmations=0

  # Preserve the last complete display on a storage/input failure; never reset an existing ledger.

  try{

   $saved=(At58-Unprotect ([IO.File]::ReadAllText((Join-Path $ctx.Root 'simulation-display.dpapi'))) 'AT58-SIM-DISPLAY-1')|ConvertFrom-Json

   if($saved.Schema -ceq 'AT-SIM-DISPLAY-1' -and $saved.Scope -ceq $ctx.Scope -and $saved.Symbol -ceq $ctx.Symbol){$sim=$saved.Result}

  }catch{}

  $sim.Code=$code;$sim.Text=At58Sim-Message $code;$sim.Reconciled=$false;$sim.Confirmations=0

 }

 try{

  At58-Atomic (Join-Path $ctx.Root 'simulation-display.dpapi') (At58-Protect (@{Schema='AT-SIM-DISPLAY-1';Scope=$ctx.Scope;Symbol=$ctx.Symbol;Result=$sim}|ConvertTo-Json -Depth 32 -Compress) 'AT58-SIM-DISPLAY-1')

  $status=@{RunId=$ctx.RunId;Utc=(At58-Now $ctx).ToString('o');Code=$sim.Code;Mode='SIMULATED_CHAIN';ExecutionEnabled=$false;OrdersSent=0;Reconciled=$sim.Reconciled;Confirmations=$sim.Confirmations;PaperOrders=$sim.PaperOrderCount;PaperFills=$sim.PaperFillCount;SimulatedPosts=$sim.Posts;CycleId=$(if($sim.Cycle){$sim.Cycle.Id}else{$null});CyclePhase=$(if($sim.Cycle){$sim.Cycle.Phase}else{''})}

  At58-Atomic (Join-Path $ctx.Root 'simulation-status.json') ($status|ConvertTo-Json -Compress)

  At58-Atomic (Join-Path $ctx.Root 'strategy-status.json') (@{RunId=$ctx.RunId;Utc=(At58-Now $ctx).ToString('o');Code=$strategy.Code;Mode='PAPER';ExecutionEnabled=$false;Reconciled=$strategy.Reconciled;Confirmations=$strategy.Confirmations;PaperOrders=$sim.PaperOrderCount;PaperFills=$sim.PaperFillCount}|ConvertTo-Json -Compress)

 }catch{$sim.Code='SIM_STATUS_STORAGE';$sim.Text=At58Sim-Message $sim.Code}

 return [pscustomobject]@{Strategy=$strategy;Simulation=$sim}

}



# Five-regime policy v2. These are conservative PAPER defaults, not optimized returns.

function At58R-Enabled($policy){return [bool](At58-Value $policy 'Controls')}

function At58R-Migrate($source,[string]$hash){return (($hash -and $hash -ceq (At58-Value $source 'LegacyHash')) -or ((At58R-Enabled $source.Policy) -and $hash -and $hash -ceq (At58-Value $source 'PriorHash')))}

function At58R-Risk($policy,[string]$market,$snapshot){

 $reserve=[decimal]$policy.ReserveRatio;$max=[int]$policy.MaxBuys;$stop=[decimal]$policy.LossStop;$paused=$false

 if($market -ceq '보합'){$reserve=[math]::Max($reserve,$policy.Neutral.ReserveRatio);$max=[math]::Min($max,$policy.Neutral.MaxBuys)}

 if(At58R-Enabled $policy){

  $c=$policy.Controls;$stop=[math]::Min($stop,$c.BuyLossStop)

  if($market -ceq '하락'){$reserve=[math]::Max($reserve,$c.DownReserve);$max=[math]::Min($max,$c.DownMaxBuys)}

  if($market -ceq '급락'){$reserve=[math]::Max($reserve,$c.CrashReserve);$max=0;$paused=$true}

  $until=At58-Value $snapshot 'RegimePauseUntil'

  if($until -and (At58S-Utc $snapshot.CompletedUtc) -lt (At58S-Utc $until)){$paused=$true}

 }

 return [pscustomobject]@{Reserve=$reserve;MaxBuys=$max;LossStop=$stop;Paused=$paused}

}

function At58R-Pause($state,$source,$snapshot,[string]$regime){

 if(!(At58R-Enabled $source.Policy)){return $snapshot}

 if(!$state.PSObject.Properties['CrashPauseUntil']){$state|Add-Member CrashPauseUntil ''}

 if($regime -ceq '급락'){$state.CrashPauseUntil=(At58S-Utc $snapshot.CompletedUtc).AddSeconds($source.Policy.Controls.CrashCooldownSeconds).ToString('o')}

 $copy=At58S-Clone $snapshot;$copy|Add-Member RegimePauseUntil $state.CrashPauseUntil -Force;return $copy

}

function At58R-Exit([decimal]$entry,[decimal]$gap,$policy){

 return ([math]::Ceiling(($entry*(1+$policy.BuyFee)*(1+$gap)/(1-$policy.SellFee))/$policy.Tick)*$policy.Tick)

}

function At58R-Anchor($anchors,[int]$stage,[decimal]$entry,[decimal]$gap,$policy){

 $anchors|Add-Member -MemberType NoteProperty -Name ([string]$stage) -Value ([pscustomobject]@{Entry=$entry;ExitGap=$gap;SellPrice=(At58R-Exit $entry $gap $policy)}) -Force

}

function At58R-SeedAnchors($source){

 $a=[pscustomobject]@{}

 foreach($row in $source.Ledger.Rows){

  if($row.Side -ceq '매수'){At58R-Anchor $a $row.Stage $row.Price $source.Policy.SellGap $source.Policy}

  else{$a.PSObject.Properties.Remove([string]$row.Stage)}

 }

 return $a

}

function At58R-PaperAnchors($state,$source){

 if(!(At58R-Enabled $source.Policy)){return}

 $a=At58R-SeedAnchors $source

 foreach($o in $state.Orders){if($o.Filled -le 0){continue}

  if($o.Side -ceq '매수'){$gap=At58-Value $o 'ExitGap';if($null -eq $gap){$gap=$source.Policy.SellGap};At58R-Anchor $a $o.Stage ($o.Amount/$o.Filled) $gap $source.Policy}

  elseif($o.State -ceq 'FILLED'){$a.PSObject.Properties.Remove([string]$o.Stage)}

 }

 $state|Add-Member Anchors $a -Force

}

function At58R-LimitGoals($ctx,$source,$p,$s,[string]$market,$book){

 if(!(At58R-Enabled $source.Policy)){return $false}

 $goals=@($p.Goals|Where-Object {$_.State -ceq 'PARTIAL_CLOSED' -and $_.Side -ceq '매수'})

 if(!$goals.Count){return $false}

 if(!$book.PSObject.Properties['GoalCaps']){$book|Add-Member GoalCaps @()}

 $changed=$false

 foreach($g in $goals){

  $risk=At58R-Risk $source.Policy $market $s;$reg=$source.Policy.Regimes.$market

  $loss=($p.Cash+$p.Qty*$s.Quote.Price -le $source.Policy.Principal*(1-$risk.LossStop))

  $today=@($book.Orders|Where-Object {$_.Day -ceq $s.Day -and $_.Action -ceq 'NEW' -and $_.Intent.GoalId -ceq $g.Id}).Count

  $cap=$g.Filled

  if(!$risk.Paused -and !$loss -and $reg.BuyEnabled -and $(if(At58-Value $p 'DailyStages'){At58D-Allow $p.DailyStages $g.Stage}else{$today -or $p.BuyCount -lt $risk.MaxBuys})){

   # Reprice the whole original goal, including already executed shares. Never refill a fresh allowance every retry.

   $ref=At58S-Clone $p;$ref.Held=@($ref.Held|Where-Object {$_ -ne $g.Stage});$ref.Orders=@();$ref.BuyCount=[math]::Max(0,$ref.BuyCount-$(if($today){1}else{0}))

   $ref.Cash+=$g.Amount+$g.FeeEstimate;$oldCost=$ref.Qty*$ref.Average-$g.Amount;$ref.Qty-=$g.Filled;$ref.Average=if($ref.Qty -gt 0){$oldCost/$ref.Qty}else{0D}

   $snap=At58S-Clone $s;$snap.Cash.Orderable+=$g.Amount+$g.FeeEstimate

   $effective=[pscustomobject]@{Policy=$source.Policy;Cycle=$ref.Cycle}

   $fresh=At58S-Plan $effective $ref $snap $market;$row=@($fresh.Rows|Where-Object {$_.Stage -eq $g.Stage})[0]

   $cap=[math]::Max($g.Filled,[math]::Min($g.GoalQty,$row.BuyQty))

  }

  $oldLimit=$g.GoalQty;foreach($c in $book.GoalCaps){if($c.GoalId -ceq $g.Id){$oldLimit=$c.Qty}}

  $cap=[math]::Max($g.Filled,[math]::Min($oldLimit,$cap))

  if($cap -lt $oldLimit){$book.GoalCaps+=,[pscustomobject]@{GoalId=$g.Id;Qty=$cap;Market=$market;Utc=$s.CompletedUtc;Reason='REGIME_BUDGET_LIMIT'};$changed=$true}

 }

 if($changed){At58T-Save $ctx $book};return $changed

}



# Local simulator controller and read-only readiness reporting.

# This module never creates an OrderPermit and cannot invoke the broker transport.

function At58C-Isolated($ctx){

 if((At58-Value $ctx 'OrderMode') -cne 'SIMULATED' -or (At58-Value $ctx 'ControllerSandbox') -ne $true){At58-Fail 'CONTROL_SIMULATION_ONLY' 'CONTROLLER'}

}

function At58C-Limits($limits){
 if((At58-Value $limits 'Mode') -ceq 'DAILY_STAGES'){if((At58S-Num (At58-Value $limits 'MaxBuyStages') 3 3 $true) -ne 3){At58-Fail 'CONTROL_LIMITS' 'CONTROLLER'};return (At58D-Limits)}

 if(!$limits){At58-Fail 'CONTROL_LIMITS' 'CONTROLLER'}

 try{

  return [pscustomobject]@{MaxOrderQty=(At58S-Num (At58-Value $limits 'MaxOrderQty') 1 100000000 $true);MaxOrderAmount=(At58S-Num (At58-Value $limits 'MaxOrderAmount') 5 1000000000000 $true);DailyBuyAmount=(At58S-Num (At58-Value $limits 'DailyBuyAmount') 5 1000000000000 $true);DailySubmissions=(At58S-Num (At58-Value $limits 'DailySubmissions') 1 10000 $true)}

 }catch{At58-Fail 'CONTROL_LIMITS' 'CONTROLLER'}

}

function At58C-NewSession($ctx,[string]$sourceHash,$limits){

 At58C-Isolated $ctx

 if($sourceHash -cnotmatch '^[a-f0-9]{64}$'){At58-Fail 'CONTROL_SOURCE' 'CONTROLLER'}

 $settings=At58C-Limits $limits

 return [pscustomobject]@{Schema='AT-CONTROLLER-TEST-1';Scope=$ctx.Scope;Symbol=$ctx.Symbol;RunId=$ctx.RunId;Day=(At58-Kst (At58-Now $ctx)).ToString('yyyyMMdd');SourceHash=$sourceHash;Limits=$settings;LimitsHash=(At58-Hash ($settings|ConvertTo-Json -Compress));State='STOPPED';Reason='NOT_STARTED';StartedUtc='';LastUtc='';ExecutionEnabled=$false}

}

function At58C-Identity($ctx,$session,[string]$sourceHash){

 At58C-Isolated $ctx

 if(!$session -or $session.Schema -cne 'AT-CONTROLLER-TEST-1' -or $session.ExecutionEnabled -ne $false -or $session.Scope -cne $ctx.Scope -or $session.Symbol -cne $ctx.Symbol){At58-Fail 'CONTROL_IDENTITY' 'CONTROLLER'}

 if($session.RunId -cne $ctx.RunId -or $session.Day -cne (At58-Kst (At58-Now $ctx)).ToString('yyyyMMdd')){$session.State='STOPPED';$session.Reason='RESTART_OR_NEW_DAY';At58-Fail 'CONTROL_RESTART' 'CONTROLLER'}

 if($sourceHash -cne $session.SourceHash -or $sourceHash -cnotmatch '^[a-f0-9]{64}$'){$session.State='STOPPED';$session.Reason='SOURCE_CHANGED';At58-Fail 'CONTROL_SOURCE_CHANGED' 'CONTROLLER'}

 $limits=At58C-Limits $session.Limits

 if((At58-Hash ($limits|ConvertTo-Json -Compress)) -cne $session.LimitsHash){$session.State='STOPPED';$session.Reason='LIMITS_CHANGED';At58-Fail 'CONTROL_LIMITS_CHANGED' 'CONTROLLER'}

 if($session.State -cnotin @('STOPPED','RUNNING','REVIEW')){At58-Fail 'CONTROL_STATE' 'CONTROLLER'}

}

function At58C-Start($ctx,$session,[string]$sourceHash){

 At58C-Identity $ctx $session $sourceHash

 $book=At58T-Load $ctx

 if($session.State -ceq 'REVIEW' -or @($book.Orders|Where-Object {$_.State -cin @('UNKNOWN','SUBMITTING','WARNING_REVIEW','REVIEW')}).Count){$session.State='REVIEW';At58-Fail 'CONTROL_REVIEW' 'CONTROLLER'}

 $session.State='RUNNING';$session.Reason='';$session.StartedUtc=(At58-Now $ctx).ToString('o')

}

function At58C-Stop($session){

 if(!$session -or $session.Schema -cne 'AT-CONTROLLER-TEST-1'){At58-Fail 'CONTROL_IDENTITY' 'CONTROLLER'}

 if($session.State -cne 'REVIEW'){$session.State='STOPPED';$session.Reason='OPERATOR_STOP'}

}

function At58C-Quota($session,$book,$intent,[string]$action,[string]$day,$source=$null){

 if($action -ceq 'CANCEL'){return}

 $l=At58C-Limits $session.Limits;$qty=At58S-Num $intent.Qty 1 100000000 $true;$price=At58S-Num $intent.Price 5 10000000 $true
 if((At58-Value $l 'Mode') -ceq 'DAILY_STAGES'){
  if($intent.Side -cnotin @('매수','매도')){At58-Fail 'CONTROL_SIDE' 'CONTROLLER'}
  if($intent.Side -ceq '매수' -and !(At58D-Allow (At58D-Usage $book $day $source) $intent.Stage)){At58-Fail 'CONTROL_DAILY_STAGES' 'CONTROLLER'}
  return
 }

 if($qty -gt $l.MaxOrderQty){At58-Fail 'CONTROL_ORDER_QTY' 'CONTROLLER'}

 if($qty*$price -gt $l.MaxOrderAmount){At58-Fail 'CONTROL_ORDER_AMOUNT' 'CONTROLLER'}

 # Count attempted new/amend submissions, even rejected or cancelled ones.

 # A timeout never frees a reservation. Cancel requests do not consume this quota.

 $used=@($book.Orders|Where-Object {$_.Day -ceq $day -and $_.Action -cne 'CANCEL'})

 if($used.Count -ge $l.DailySubmissions){At58-Fail 'CONTROL_DAILY_COUNT' 'CONTROLLER'}

 if($intent.Side -ceq '매수'){

  $amount=0D;foreach($o in $used){if($o.Intent.Side -ceq '매수'){$amount+=[decimal]$o.Intent.Qty*[decimal]$o.Intent.Price}}

  if($amount+$qty*$price -gt $l.DailyBuyAmount){At58-Fail 'CONTROL_DAILY_BUY' 'CONTROLLER'}

 }

}

function At58C-Dispatch($ctx,$session,[string]$sourceHash,$snapshot,$intent,[string]$action,[string]$decision,[string]$parentKey='', [scriptblock]$simulationTransport=$null){

 At58C-Identity $ctx $session $sourceHash

 if(!$simulationTransport){At58-Fail 'CONTROL_TRANSPORT_REQUIRED' 'CONTROLLER'}

 if($session.State -ceq 'REVIEW'){At58-Fail 'CONTROL_REVIEW' 'CONTROLLER'}

 if($action -cne 'CANCEL' -and $session.State -cne 'RUNNING'){At58-Fail 'CONTROL_STOPPED' 'CONTROLLER'}

 $mutex=[Threading.Mutex]::new($false,('Local\AT58Controller_'+(At58-Hash ([IO.Path]::GetFullPath($ctx.Root).ToLowerInvariant()))));$held=$false

 try{

  try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true};if(!$held){At58-Fail 'CONTROL_BUSY' 'CONTROLLER'}

  # Recheck after taking the lock, so a stop or changed session is not bypassed.

  At58C-Identity $ctx $session $sourceHash

  if($session.State -ceq 'REVIEW'){At58-Fail 'CONTROL_REVIEW' 'CONTROLLER'}

  if($action -cne 'CANCEL' -and $session.State -cne 'RUNNING'){At58-Fail 'CONTROL_STOPPED' 'CONTROLLER'}

  $book=At58T-Load $ctx

  if(@($book.Orders|Where-Object {$_.State -cin @('UNKNOWN','SUBMITTING','WARNING_REVIEW','REVIEW')}).Count){$session.State='REVIEW';$session.Reason='ORDER_UNCERTAIN';At58-Fail 'CONTROL_REVIEW' 'CONTROLLER'}

  At58C-Quota $session $book $intent $action $snapshot.Day

  $node=At58T-Submit $ctx $snapshot $intent $action $decision $parentKey $simulationTransport

  $session.LastUtc=(At58-Now $ctx).ToString('o')

  if($node.State -cin @('UNKNOWN','SUBMITTING','WARNING_REVIEW','REVIEW')){$session.State='REVIEW';$session.Reason='ORDER_UNCERTAIN'}

  return $node

 }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}

}

function At58C-Readiness($ctx,$s){

 $now=At58-Now $ctx;$rows=New-Object 'Collections.Generic.List[object]';$modes=New-Object 'Collections.Generic.List[object]'

 function ReadinessRow([string]$id,[string]$label,[bool]$ok,[string]$detail){$rows.Add([pscustomobject]@{Id=$id;Label=$label;State=$(if($ok){'PASS'}else{'BLOCKED'});Detail=$detail})}

 ReadinessRow 'CONTROLLER' '실주문 자동 실행 연결' $false '미연결 · 현재 제어부는 가상 거래소 시험 전용'

 ReadinessRow 'SETTLEMENT' '실계좌 원장·비용 대조' $false '미완료 · 실제 체결 원장의 수수료·세금은 미확정'

 $sourceOk=$false;$inputFresh=$false

 try{

  $raw=(At58-Unprotect ([IO.File]::ReadAllText((Join-Path $ctx.Root 'strategy-input.dpapi'))) 'AT58-STRATEGY-INPUT-1')|ConvertFrom-Json

  $null=At58S-Import $raw

  if($raw.Scope -cne $ctx.Scope -or $raw.Symbol -cne $ctx.Symbol){At58-Fail 'CONTROL_IDENTITY' 'CONTROLLER'}

  $age=($now-(At58S-Utc $raw.Utc)).TotalSeconds;$inputFresh=($age -ge -5 -and $age -le 120)

  foreach($i in 17..21){$name=At58S-Cell $raw.Settings $i 0;$value=At58S-Cell $raw.Settings $i 1;if($name -cin @('급등','상승','하락','급락','보합')){$modes.Add([pscustomobject]@{Market=$name;Setting=$value})}}

  $sourceOk=($modes.Count -eq 5 -and !@($modes|Where-Object {$_.Setting -cnotin @('허용','모의','중단')}).Count)

 }catch{}

 $modeText=if($sourceOk){(@($modes|ForEach-Object {$_.Market+' '+$_.Setting}) -join ' / ')+' · 실주문 전환 설정 아님'}else{'5개 장세 설정 확인 대기'}

 ReadinessRow 'SETTINGS' '시트 장세 설정 수신' ($sourceOk -and $inputFresh) $modeText

 $fresh=$false;try{$age=($now-(At58S-Utc $s.CompletedUtc)).TotalSeconds;$fresh=($age -ge -2 -and $age -le 60)}catch{}

 ReadinessRow 'SNAPSHOT' '계좌 조회 최신성' $fresh $(if($fresh){'최근 60초 내 조회'}else{'새 조회 결과 필요'})

 $live=[bool]$s.Session.Live

 ReadinessRow 'MARKET' '장중 시세' ($live -and $s.Quote.Mode -ceq 'LIVE_REST') $(if($live -and $s.Quote.Mode -ceq 'LIVE_REST'){'장중 REST 조회 중'}else{'장외 또는 시세 대기'})

 $strategy=At58-Value $s 'Strategy';$confirmed=$strategy -and $strategy.Reconciled -and $strategy.Confirmations -ge 2

 ReadinessRow 'ACCOUNT' '실계좌·기존 기록 대조' $confirmed $(if($confirmed){'연속 2회 대조 완료'}else{'연속 대조 대기'})

 $feed=At58-Value $s 'Execution';$feedOk=$feed -and $feed.Connected -and $feed.ReceiptAck -and $feed.FillAck -and !$feed.Pending -and !$feed.Gaps

 ReadinessRow 'FEED' '주문·체결 통보 연결' $feedOk $(if($feedOk){'접수·체결 구독 확인'}else{'연결 또는 통보 대조 확인 필요'})

 $trading=At58-Value $s 'Trading';$orders=At58-Value $trading 'Orders';$uncertain=@($orders|Where-Object {$null -ne $_ -and $_.State -cin @('UNKNOWN','SUBMITTING','WARNING_REVIEW','ACKNOWLEDGED','REVIEW')})

 $orderOk=$trading -and !$uncertain.Count -and $trading.Code -cin @('ORDER_PREVIEW_WAIT','ORDER_PREVIEW_READY','MARKET_CLOSED')

 ReadinessRow 'ORDERS' '주문 이력 확인' $orderOk $(if($orderOk){'확인되지 않은 AT 주문 없음'}else{'주문 이력 또는 준비 상태 확인 필요'})

 $sim=At58-Value $s 'Simulation';$placed=0;$filled=0;if($sim){$placed=[int]$sim.PaperOrderCount;$filled=[int]$sim.PaperFillCount}

 ReadinessRow 'PAPER' '현재 모의 원장 주문·체결' ($placed -gt 0 -and $filled -gt 0) ('모의 주문 '+$placed+'건 / 체결 '+$filled+'건 · 수익성·실전 검증 완료를 의미하지 않음')

 return [pscustomobject]@{Schema='AT-READINESS-1';Utc=$now.ToString('o');RunId=$ctx.RunId;Mode='SIMULATION_ONLY';ReadyForLive=$false;ExecutionEnabled=$false;OrdersSent=0;Code='LIVE_NOT_CONNECTED';Text='실주문 실행 미연결 · 가상 거래소 제어 시험 단계';Rows=$rows.ToArray();Regimes=$modes.ToArray();Blockers=@($rows|Where-Object {$_.State -ceq 'BLOCKED'}).Count}

}

function At58C-Run($ctx,$s){

 try{return (At58C-Readiness $ctx $s)}catch{return [pscustomobject]@{Schema='AT-READINESS-1';Utc=(At58-Now $ctx).ToString('o');RunId=$ctx.RunId;Mode='SIMULATION_ONLY';ReadyForLive=$false;ExecutionEnabled=$false;OrdersSent=0;Code='READINESS_ERROR';Text='실전 준비 점검 실패 · 실주문 꺼짐';Rows=@();Regimes=@();Blockers=1}}

}



function At58X-Replay($source,$book,[string]$day){

 if($book.Mode -cnotin @('LIVE','LIVE_TEST') -or $book.Symbol -cne $source.Symbol -or $book.Scope -cne $source.Scope){At58-Fail 'SIM_LEDGER_IDENTITY' 'SIMULATION'}

 $p=[pscustomobject]@{Qty=[decimal]$source.Ledger.Qty;Average=[decimal]$source.Ledger.Average;Cash=[decimal]$source.Ledger.Cash;Realized=[decimal]$source.Ledger.Realized;Held=@($source.Ledger.Held);Cycle=(At58S-Clone $source.Cycle);Anchors=(At58R-SeedAnchors $source);BuyCount=0;Orders=@();Goals=@();FeeEstimate=0D;Code='OK'}

 $groups=@{};$keys=@{};$ordered=New-Object 'Collections.Generic.List[object]'

 foreach($o in $book.Orders){$keys[$o.Key]=$o;if($o.Action -cne 'NEW'){continue}

  $i=$o.Intent;$id=[string](At58-Value $i 'GoalId')

  if($id -cnotmatch '^[a-f0-9]{64}$'){At58-Fail 'SIM_GOAL_IDENTITY' 'SIMULATION'}

  $null=At58S-Num $i.Stage 1 30 $true;$null=At58S-Num $i.GoalQty 1 100000000 $true;$null=At58S-Num $i.CycleId 1 100000 $true;$null=At58S-Num $i.Target 5 10000000

  if(!$groups.ContainsKey($id)){

   $g=[pscustomobject]@{Id=$id;CycleId=$i.CycleId;Stage=$i.Stage;Side=$i.Side;Target=$i.Target;GoalQty=$i.GoalQty;Entry=[bool]$i.Entry;EntryMode=(At58-Value $i 'EntryMode');ExitGap=(At58-Value $i 'ExitGap');RootKeys=@();Nodes=@();Filled=0D;Amount=0D;FeeEstimate=0D;Remaining=$i.GoalQty;State='';Day=$o.Day;Price=$i.Price}

   $groups[$id]=$g;$ordered.Add($g)

  };$g=$groups[$id]

  if($g.CycleId -ne $i.CycleId -or $g.Stage -ne $i.Stage -or $g.Side -cne $i.Side -or $g.Target -ne $i.Target -or $g.GoalQty -ne $i.GoalQty -or $g.Entry -ne $i.Entry -or $g.EntryMode -cne (At58-Value $i 'EntryMode') -or $g.ExitGap -ne (At58-Value $i 'ExitGap')){At58-Fail 'SIM_GOAL_CONFLICT' 'SIMULATION'}

  $g.RootKeys+=,$o.Key

 }

 foreach($o in $book.Orders){

  if(!$keys.ContainsKey($o.RootKey)){At58-Fail 'SIM_GOAL_ROOT' 'SIMULATION'}

  $g=$groups[$keys[$o.RootKey].Intent.GoalId];$g.Nodes+=,$o

 }

 foreach($f in $book.Fills){

  $o=$keys[$f.OrderKey];$g=$groups[$keys[$o.RootKey].Intent.GoalId];$g.Filled+=$f.Qty;$g.Amount+=$f.Amount

 }

 $capRows=At58-Value $book 'GoalCaps';$caps=@($capRows|Where-Object {$null -ne $_});if($caps.Count -gt 5000){At58-Fail 'SIM_GOAL_CAP' 'SIMULATION'}

 foreach($cap in $caps){if(!$groups.ContainsKey([string]$cap.GoalId) -or $groups[[string]$cap.GoalId].Side -cne '매수'){At58-Fail 'SIM_GOAL_CAP' 'SIMULATION'}}

 $today=@{}

 foreach($g in $ordered){

  if($g.Filled -gt $g.GoalQty){At58-Fail 'SIM_GOAL_OVERFILL' 'SIMULATION'}

  $limit=$g.GoalQty

  foreach($cap in $caps){if($cap.GoalId -ceq $g.Id){$n=At58S-Num $cap.Qty 0 $limit $true;if($g.Side -cne '매수' -or $n -lt $g.Filled){At58-Fail 'SIM_GOAL_CAP' 'SIMULATION'};$limit=$n}}

  $g.Remaining=$limit-$g.Filled

  $uncertain=@($g.Nodes|Where-Object {$_.State -cin @('SUBMITTING','UNKNOWN','WARNING_REVIEW','REVIEW')})

  $active=@($g.Nodes|Where-Object {$_.State -cin @('ACKNOWLEDGED','OPEN','PARTIAL')})

  if($limit -lt $g.GoalQty){$openRoots=@{};foreach($o in $active){if($o.Action -ceq 'CANCEL'){continue};if(!$openRoots.ContainsKey($o.RootKey)){$openRoots[$o.RootKey]=0D};$openRoots[$o.RootKey]=[math]::Max($openRoots[$o.RootKey],$o.Remaining)};$openQty=0D;foreach($n in $openRoots.Values){$openQty+=$n};if($g.Filled+$openQty -gt $limit){At58-Fail 'SIM_GOAL_CAP' 'SIMULATION'}}

  $g.State=if($uncertain.Count){'REVIEW'}elseif($active.Count){'ACTIVE'}elseif($g.Remaining -eq 0){'FILLED'}elseif($g.Filled -gt 0){'PARTIAL_CLOSED'}else{'CANCELLED'}

  if($g.Side -ceq '매수' -and @($g.Nodes|Where-Object {$_.Day -ceq $day -and $_.Action -cne 'CANCEL' -and $_.State -cne 'REJECTED'}).Count){$today[$g.Id]=$true}

  if($g.Filled -gt 0){

   if($g.Side -ceq '매수'){

    if($g.Stage -in $p.Held){At58-Fail 'SIM_STAGE_OCCUPIED' 'SIMULATION'}

    $entry=($g.Stage -eq 1 -and $p.Cycle.Phase -ceq '다음 사이클 대기')

    if($g.CycleId -ne ($p.Cycle.Id+$(if($entry){1}else{0})) -or $g.Entry -ne $entry){At58-Fail 'SIM_CYCLE_IDENTITY' 'SIMULATION'}

    if($entry){if($p.Qty -ne 0){At58-Fail 'SIM_CYCLE_BALANCE' 'SIMULATION'};$p.Cycle.Id++;$p.Cycle.Basis=$g.Amount/$g.Filled;$p.Cycle.Phase='운영중'}

    $g.FeeEstimate=0D

    $exitGap=if($null -ne $g.ExitGap){$g.ExitGap}else{$source.Policy.SellGap};At58R-Anchor $p.Anchors $g.Stage ($g.Amount/$g.Filled) $exitGap $source.Policy

    $p.Average=($p.Qty*$p.Average+$g.Amount)/($p.Qty+$g.Filled);$p.Qty+=$g.Filled;$p.Cash-=$g.Amount+$g.FeeEstimate;$p.Realized-=$g.FeeEstimate;$p.Held+=,[int]$g.Stage

   }else{

    if($g.Stage -notin $p.Held -or $g.Filled -gt $p.Qty -or $g.CycleId -ne $p.Cycle.Id){At58-Fail 'SIM_STAGE_POSITION' 'SIMULATION'}

    if($g.Stage -eq 1 -and $g.GoalQty -ne $p.Qty){At58-Fail 'SIM_CYCLE_BALANCE' 'SIMULATION'}

    $g.FeeEstimate=0D

    $p.Realized+=$g.Amount-$g.Filled*$p.Average-$g.FeeEstimate;$p.Qty-=$g.Filled;$p.Cash+=$g.Amount-$g.FeeEstimate

    if($g.Remaining -eq 0){$p.Held=@($p.Held|Where-Object {$_ -ne $g.Stage});$p.Anchors.PSObject.Properties.Remove([string]$g.Stage)}

    if($p.Qty -eq 0){$p.Average=0D;if($g.Stage -ne 1 -or $g.Remaining -ne 0){At58-Fail 'SIM_CYCLE_BALANCE' 'SIMULATION'};$p.Cycle.Phase='다음 사이클 대기';$p.Cycle.Basis=$g.Amount/$g.Filled;if(At58R-Enabled $source.Policy){$p.Held=@()}}

   }

   $p.FeeEstimate+=$g.FeeEstimate;if($p.Cash -lt 0){At58-Fail 'SIM_LEDGER_CASH' 'SIMULATION'}

  }

  if($g.State -ceq 'REVIEW'){$p.Code='SIM_ORDER_REVIEW'}

  if($g.Nodes[-1].Action -ceq 'NEW' -and $g.Nodes[-1].State -ceq 'REJECTED'){$g.State='REVIEW';$p.Code='SIM_ORDER_REJECTED'}

  $p.Orders+=,[pscustomobject]@{Id=('LIVE-'+$g.Id.Substring(0,24));Day=$g.Day;Stage=$g.Stage;Side=$g.Side;Price=$g.Price;Qty=$limit;OriginalQty=$g.GoalQty;Filled=$g.Filled;Amount=$g.Amount;Fee=$g.FeeEstimate;State=$(if($g.State -cin @('ACTIVE','REVIEW')){if($g.State -ceq 'REVIEW'){'UNKNOWN'}elseif($g.Filled -gt 0){'PARTIAL'}else{'ACKNOWLEDGED'}}elseif($g.State -ceq 'PARTIAL_CLOSED'){'CANCEL_PENDING'}else{$g.State});GoalId=$g.Id;CycleId=$g.CycleId}

 }

 $p.BuyCount=@($source.Ledger.Rows|Where-Object {$_.Day -ceq $day -and $_.Side -ceq '매수'}).Count+$today.Count

 $p.Goals=$ordered.ToArray();return $p

}



# Development module. Load after At58.Core.ps1 and Replay.ps1. Import sends no requests.

# The installed READ_ONLY host must never load or authorize this module for live execution.

function At58-Route($method,$path,$query){

 if($method -ceq 'GET' -and $path -ceq '/accounts/v1/me/profit-loss'){

  foreach($key in $query.Keys){if($key -cnotin @('iqry_sta_date','iqry_fin_date','crdt_expn_incu_yn','tr_cont','tr_cont_key') -or ([string]$query[$key]).Length -gt 4096){At58-Fail 'QUERY_BLOCKED' 'TRANSPORT'}}

  if($query.ContainsKey('crdt_expn_incu_yn') -and $query.crdt_expn_incu_yn -cne 'N'){At58-Fail 'QUERY_BLOCKED' 'TRANSPORT'}

  $null=At58-Day $query.iqry_sta_date;$null=At58-Day $query.iqry_fin_date

  if($query.iqry_sta_date -gt $query.iqry_fin_date){At58-Fail 'QUERY_BLOCKED' 'TRANSPORT'};return

 }

 At58-ReadRoute $method $path $query

}

function At58X-CostRows($rows,[string]$from,[string]$to){

 $result=New-Object 'Collections.Generic.List[object]';$seen=@{}

 foreach($row in $rows){

  $day=[string](At58-Value $row 'deal_date');$null=At58-Day $day

  if($day -lt $from -or $day -gt $to -or $seen.ContainsKey($day)){At58-Fail 'LIVE_COST_DATES' 'LIVE_LEDGER'};$seen[$day]=$true

  $buy=At58S-Num (At58-Value $row 'byov_amt');$sell=At58S-Num (At58-Value $row 'seln_amt')

  $buyFee=At58S-Num (At58-Value $row 'byov_deal_fee');$sellFee=At58S-Num (At58-Value $row 'seln_deal_fee');$totalFee=At58S-Num (At58-Value $row 'deal_fee');$tax=At58S-Num (At58-Value $row 'wtax_amt')

  if($buyFee+$sellFee -ne $totalFee -or ($buy -eq 0 -and $buyFee -ne 0) -or ($sell -eq 0 -and ($sellFee+$tax) -ne 0)){At58-Fail 'LIVE_COST_TOTAL' 'LIVE_LEDGER'}

  if((At58-Value $row 'deal_trtx') -ne $null -and (At58S-Num $row.deal_trtx) -ne $tax){At58-Fail 'LIVE_COST_TAX' 'LIVE_LEDGER'}

  if((At58S-Num (At58-Value $row 'loan_int')) -ne 0){At58-Fail 'LIVE_CREDIT_UNSUPPORTED' 'LIVE_LEDGER'}

  $result.Add([pscustomobject]@{Day=$day;Buy=$buy;Sell=$sell;BuyFee=$buyFee;SellFee=$sellFee;Tax=$tax})

 };return ,$result.ToArray()

}

function At58X-Costs($ctx,[string]$from,[string]$to){

 # Whole domestic account totals. Any post-baseline external domestic order blocks the ledger.

 $rows=At58-List $ctx '/accounts/v1/me/profit-loss' @{iqry_sta_date=$from;iqry_fin_date=$to;crdt_expn_incu_yn='N'}

 return ,(At58X-CostRows $rows $from $to)

}

function At58X-Context($owner){

 $ctx=@{};foreach($k in $owner.Keys){$ctx[$k]=$owner[$k]}

 $ctx.Root=Join-Path $owner.Root 'real-orders-v1'

 $ctx.OrderMode=if((At58-Value $owner 'LiveTestMode') -eq $true){'SIMULATED'}else{'LIVE'}

 return $ctx

}

function At58X-Path($owner){return (Join-Path (At58X-Context $owner).Root 'state.dpapi')}

function At58X-Load($owner){

 $path=At58X-Path $owner;if(![IO.File]::Exists($path)){return $null}

 if(([IO.FileInfo]$path).Length -gt 25000000){At58-Fail 'LIVE_STATE_STORAGE' 'LIVE_LEDGER'}

 try{$state=(At58-Unprotect ([IO.File]::ReadAllText($path)) 'AT-LIVE-STATE-1')|ConvertFrom-Json}catch{At58-Fail 'LIVE_STATE_STORAGE' 'LIVE_LEDGER'}

 $test=(At58-Value $owner 'LiveTestMode') -eq $true

 if($state.Schema -cne 'AT-LIVE-STATE-1' -or $state.Scope -cne $owner.Scope -or $state.Symbol -cne $owner.Symbol -or $state.TestOnly -ne $test -or $state.Seed.Scope -cne $owner.Scope -or $state.Seed.Hash -cne $state.SourceHash){At58-Fail 'LIVE_STATE_IDENTITY' 'LIVE_LEDGER'}

 $null=At58-Day $state.StartDay;return $state

}

function At58X-Save($owner,$state){

 $path=At58X-Path $owner;$tmp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp';$stream=$null

 try{

  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))

  $bytes=[Text.Encoding]::UTF8.GetBytes((At58-Protect ($state|ConvertTo-Json -Depth 40 -Compress) 'AT-LIVE-STATE-1'))

  $stream=[IO.FileStream]::new($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true);$stream.Dispose();$stream=$null

  if([IO.File]::Exists($path)){[IO.File]::Replace($tmp,$path,[Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($tmp,$path)}

 }finally{if($stream){$stream.Dispose()};if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}}

}

function At58X-HistorySignature($row){return (At58-Hash (@($row.Day,(At58E-Id $row.Id),$row.Symbol,$row.Side,$row.Qty,$row.Price,$row.Filled,$row.Remaining,$row.Kind,$row.Original,$row.Status,$row.Reject) -join '|'))}

function At58X-Initialize($owner,$source,$s,$costRows){

 $ctx=At58X-Context $owner;$mutex=[Threading.Mutex]::new($false,('Local\AT58Live_'+(At58-Hash $ctx.Root)));$held=$false

 try{

 try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true};if(!$held){At58-Fail 'LIVE_BUSY' 'LIVE_CONTROL'}

 if(At58X-Load $owner){At58-Fail 'LIVE_ALREADY_INITIALIZED' 'LIVE_LEDGER'}

 if($source.Hash -cnotmatch '^[a-f0-9]{64}$' -or $source.Scope -cne $owner.Scope -or $source.Symbol -cne $owner.Symbol){At58-Fail 'LIVE_SOURCE_IDENTITY' 'LIVE_LEDGER'}

 $null=At58S-Reconcile $source $s

 if(@($s.OpenOrdersToday).Count -or @($s.PriorUnresolved).Count){At58-Fail 'LIVE_START_OPEN_ORDERS' 'LIVE_LEDGER'}

 $book=At58T-Load (At58X-Context $owner);if(@($book.Orders).Count -or @($book.Fills).Count){At58-Fail 'LIVE_ORPHAN_BOOK' 'LIVE_LEDGER'}

 $seen=@{};$baseline=New-Object 'Collections.Generic.List[object]'

 foreach($o in @($s.OrdersToday)){$key=$o.Day+'|'+(At58E-Id $o.Id);if($seen.ContainsKey($key)){At58-Fail 'LIVE_HISTORY_DUPLICATE' 'LIVE_LEDGER'};$seen[$key]=$true;$baseline.Add([pscustomobject]@{Key=$key;Hash=(At58X-HistorySignature $o)})}

 $state=[pscustomobject]@{Schema='AT-LIVE-STATE-1';Scope=$owner.Scope;Symbol=$owner.Symbol;TestOnly=((At58-Value $owner 'LiveTestMode') -eq $true);SourceHash=$source.Hash;Seed=(At58S-Clone $source);StartDay=$s.Day;BaselineD2=[decimal]$s.Cash.D2;BaselineCosts=@($costRows);BaselineOrders=$baseline.ToArray();LastUtc='';LastRunId='';LastDay='';Proof='';Confirmations=0;Market='';MarketCandidate='';MarketCandidateUtc='';CrashPauseUntil='';LastCosts=@();LastBookRevision=0}

 $interest=At58-Value $s 'CashInterestEvidence'
 if($interest){$state|Add-Member InterestBaseline @($interest.Rows) -Force}
 $null=At58X-Reconcile $owner $state $book $s $costRows

 At58X-Save $owner $state;return $state

 }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}

}

function At58X-Reconcile($owner,$state,$book,$s,$costRows){

 $ctx=At58X-Context $owner;At58T-Validate $ctx $book

 if($s.Scope -cne $owner.Scope -or $s.Symbol -cne $owner.Symbol -or $s.Day -lt $state.StartDay){At58-Fail 'LIVE_SNAPSHOT_IDENTITY' 'LIVE_LEDGER'}

 $ids=@{};foreach($o in $book.Orders){if($o.BrokerId){$ids[$o.Day+'|'+$o.BrokerId]=$true}}

 $baseline=@{};foreach($item in $state.BaselineOrders){$baseline[$item.Key]=$item.Hash}

 $found=@{};foreach($r in @($s.OrdersToday)+@($s.PriorOrders)){

  $key=$r.Day+'|'+(At58E-Id $r.Id);if($found.ContainsKey($key)){At58-Fail 'LIVE_HISTORY_DUPLICATE' 'LIVE_LEDGER'};$found[$key]=$true

  if($baseline.ContainsKey($key)){if((At58X-HistorySignature $r) -cne $baseline[$key]){At58-Fail 'LIVE_BASELINE_ORDER_CHANGED' 'LIVE_LEDGER'}}

  elseif(!$ids.ContainsKey($key) -and $r.Day -ge $state.StartDay){At58-Fail 'LIVE_EXTERNAL_ORDER' 'LIVE_LEDGER'}

 }

 if($s.Day -ceq $state.StartDay){foreach($item in $state.BaselineOrders){if(!$found.ContainsKey($item.Key)){At58-Fail 'LIVE_BASELINE_ORDER_MISSING' 'LIVE_LEDGER'}}}

 $view=At58S-Clone $book;if($state.TestOnly){$view.Mode='LIVE_TEST'}

 $p=At58X-Replay $state.Seed $view $s.Day

 if($p.Code -cne 'OK'){At58-Fail 'LIVE_ORDER_REVIEW' 'LIVE_LEDGER'}

 $byDay=@{};$nodes=@{};foreach($o in $book.Orders){$nodes[$o.Key]=$o}

 foreach($f in $book.Fills){

  if(!$byDay.ContainsKey($f.Day)){$byDay[$f.Day]=@{Buy=0D;Sell=0D}}

  $side=$nodes[$f.OrderKey].Intent.Side;$field=if($side -ceq '매수'){'Buy'}else{'Sell'};$byDay[$f.Day][$field]+=$f.Amount

 }

 $base=@{};foreach($r in $state.BaselineCosts){if($base.ContainsKey($r.Day)){At58-Fail 'LIVE_COST_DATES' 'LIVE_LEDGER'};$base[$r.Day]=$r}

 $cost=0D;$seen=@{};$deltas=New-Object 'Collections.Generic.List[object]'

 foreach($r in $costRows){

  if($r.Day -lt $state.StartDay -or $r.Day -gt $s.Day -or $seen.ContainsKey($r.Day)){At58-Fail 'LIVE_COST_DATES' 'LIVE_LEDGER'};$seen[$r.Day]=$true

  $delta=@{};foreach($field in @('Buy','Sell','BuyFee','SellFee','Tax')){$v=At58S-Num $r.$field;$delta[$field]=$v-$(if($base.ContainsKey($r.Day)){$base[$r.Day].$field}else{0D});if($delta[$field] -lt 0){At58-Fail 'LIVE_COST_REGRESSION' 'LIVE_LEDGER'}}

  $owned=if($byDay.ContainsKey($r.Day)){$byDay[$r.Day]}else{@{Buy=0D;Sell=0D}}

  if($delta.Buy -ne $owned.Buy -or $delta.Sell -ne $owned.Sell){At58-Fail 'LIVE_COST_WAIT' 'LIVE_LEDGER'}

  if(($delta.Buy -eq 0 -and $delta.BuyFee -ne 0) -or ($delta.Sell -eq 0 -and $delta.SellFee+$delta.Tax -ne 0)){At58-Fail 'LIVE_COST_UNATTRIBUTED' 'LIVE_LEDGER'}

  $cost+=$delta.BuyFee+$delta.SellFee+$delta.Tax;$delta.Day=$r.Day;$deltas.Add([pscustomobject]$delta)

 }

 foreach($day in @($base.Keys)+@($byDay.Keys)){if(!$seen.ContainsKey($day)){At58-Fail 'LIVE_COST_WAIT' 'LIVE_LEDGER'}}

 $p.Cash-=$cost;$p.Realized-=$cost;$p.PSObject.Properties.Remove('FeeEstimate');foreach($o in $p.Orders){$o.Fee=$null};$p|Add-Member ActualCosts $cost;$p|Add-Member CostDays $deltas.ToArray();$p|Add-Member FeeStatus 'BROKER_DAILY_RECONCILED'

 if($p.Qty -ne $s.TargetQty -or [math]::Abs($p.Average-$s.TargetAverage) -gt 1){At58-Fail 'LIVE_POSITION_WAIT' 'LIVE_LEDGER'}

 # Recompute verified net interest from the frozen basis on every read. Never accumulate it.
 $interest=At58I-Evaluate $owner $state $s
 $p.Cash+=$interest.Net
 $p|Add-Member InterestNet $interest.Net -Force
 $p|Add-Member InterestAccepted @($interest.Rows) -Force
 $p|Add-Member InterestProof $interest.Proof -Force
 $net=$p.Cash-$state.Seed.Ledger.Cash

 if([math]::Abs(($state.BaselineD2+$net)-[decimal]$s.Cash.D2) -gt 1){At58-Fail 'LIVE_CASH_WAIT' 'LIVE_LEDGER'}

 if($p.Cash -lt 0){At58-Fail 'LIVE_NEGATIVE_CASH' 'LIVE_LEDGER'}
 $p|Add-Member DailyStages (At58D-Usage $book $s.Day $state.Seed @($p.Held)) -Force
 $p.BuyCount=$p.DailyStages.FilledCount

 return $p

}

function At58X-NewSession($owner,[string]$sourceHash,$limits){

 $limits=At58C-Limits $limits

 return [pscustomobject]@{Schema='AT-OPERATOR-SESSION-1';Scope=$owner.Scope;Symbol=$owner.Symbol;RunId=$owner.RunId;Day=(At58-Kst (At58-Now $owner)).ToString('yyyyMMdd');SourceHash=$sourceHash;Limits=$limits;LimitsHash=(At58-Hash ($limits|ConvertTo-Json -Compress));State='DISARMED';StopReason='';HostProtocol=2;TestOnly=((At58-Value $owner 'LiveTestMode') -eq $true)}

}

function At58X-Authorize($owner,$session,[string]$sourceHash){

 # Invoked by a local start, an owner-verified one-time Telegram decision, or the local auto-start opt-in.

 # A sheet, Telegram command, or update alone cannot create auto-start consent.

 At58X-Session $owner $session $sourceHash

 if($session.State -ceq 'REVIEW'){At58-Fail 'LIVE_REVIEW' 'LIVE_CONTROL'}

 if((At58-Value $owner 'LiveHostProtocol') -ne 2){At58-Fail 'LIVE_HOST_INCOMPATIBLE' 'LIVE_CONTROL'}

 $state=At58X-Load $owner;if(!$state -or $state.SourceHash -cne $sourceHash){At58-Fail 'LIVE_NOT_INITIALIZED' 'LIVE_CONTROL'}

 $book=At58T-Load (At58X-Context $owner)

 if(@($book.Orders|Where-Object {$_.State -cin @('UNKNOWN','SUBMITTING','WARNING_REVIEW','REVIEW')}).Count){$session.State='REVIEW';At58-Fail 'LIVE_ORDER_REVIEW' 'LIVE_CONTROL'}

 $session.State='ARMED';$owner.LiveSession=$session

}

function At58X-Session($owner,$session,[string]$sourceHash){

 if(!$session -or $session.Schema -cne 'AT-OPERATOR-SESSION-1' -or $session.Scope -cne $owner.Scope -or $session.Symbol -cne $owner.Symbol -or $session.TestOnly -ne ((At58-Value $owner 'LiveTestMode') -eq $true)){At58-Fail 'LIVE_SESSION_IDENTITY' 'LIVE_CONTROL'}

  if($session.RunId -cne $owner.RunId){$session.State='DISARMED';At58-Fail 'LIVE_SESSION_EXPIRED' 'LIVE_CONTROL'}
  $today=(At58-Kst (At58-Now $owner)).ToString('yyyyMMdd')
  $null=At58-Day $session.Day
  if($today -clt $session.Day){$session.State='DISARMED';At58-Fail 'LIVE_CLOCK_REVERSED' 'LIVE_CONTROL'}

 if($sourceHash -cnotmatch '^[a-f0-9]{64}$' -or $session.SourceHash -cne $sourceHash){$session.State='DISARMED';At58-Fail 'LIVE_SOURCE_CHANGED' 'LIVE_CONTROL'}

 $limits=At58C-Limits $session.Limits;if((At58-Hash ($limits|ConvertTo-Json -Compress)) -cne $session.LimitsHash){$session.State='DISARMED';At58-Fail 'LIVE_LIMITS_CHANGED' 'LIVE_CONTROL'}

 if($session.State -cnotin @('DISARMED','ARMED','STOPPING','REVIEW')){At58-Fail 'LIVE_SESSION_STATE' 'LIVE_CONTROL'}

  # Authorization belongs to this process, account, strategy and limits. A calendar
  # rollover refreshes its day, not the operator's start decision. Snapshot and
  # ledger quorum are rebuilt independently before a new trading day can submit.
  $session.Day=$today

}

function At58X-Stop($owner){$session=At58-Value $owner 'LiveSession';if($session -and $session.State -cne 'REVIEW'){$session.State='STOPPING';$session.StopReason='OPERATOR_STOP'}}

function At58X-Dispatch($owner,$state,$s,$intent,[string]$action,[string]$decision,[string]$parent=''){

 $lockCtx=At58X-Context $owner;$mutex=[Threading.Mutex]::new($false,('Local\AT58Live_'+(At58-Hash $lockCtx.Root)));$held=$false

 try{

 try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true};if(!$held){At58-Fail 'LIVE_BUSY' 'LIVE_CONTROL'}

 $session=At58-Value $owner 'LiveSession';At58X-Session $owner $session $state.SourceHash

 At58X-ManagedGate $owner $action

 if($session.State -ceq 'REVIEW' -or ($action -cne 'CANCEL' -and $session.State -cne 'ARMED') -or ($action -ceq 'CANCEL' -and $session.State -cnotin @('ARMED','STOPPING'))){At58-Fail 'LIVE_DISARMED' 'LIVE_CONTROL'}

 if((At58-Value $owner 'LiveHostProtocol') -ne 2){At58-Fail 'LIVE_HOST_INCOMPATIBLE' 'LIVE_CONTROL'}

 $ctx=At58X-Context $owner;$book=At58T-Load $ctx

 At58C-Quota $session $book $intent $action $s.Day $state.Seed

 $transport=At58-Value $owner 'LiveTestTransport'

 if($state.TestOnly){if(!$transport -or $ctx.OrderMode -cne 'SIMULATED'){At58-Fail 'LIVE_TEST_ISOLATION' 'LIVE_CONTROL'}}

 elseif($transport -or $ctx.Transport -or $ctx.OrderMode -cne 'LIVE'){At58-Fail 'LIVE_TEST_ISOLATION' 'LIVE_CONTROL'}

 if(!$state.TestOnly){

  # Refresh credentials before granting the short-lived, one-use packet permit.

  At58-Token $ctx;$owner.Token=$ctx.Token;$owner.TokenUntil=$ctx.TokenUntil;$owner.Mac=$ctx.Mac

  $parentId='';if($parent){$matches=@($book.Orders|Where-Object Key -ceq $parent);if($matches.Count -ne 1){At58-Fail 'TRADE_PARENT' 'TRADING'};$parentId=$matches[0].BrokerId}

  $packet=At58T-Packet $intent $action $parentId

  $ctx.OrderPermit=[pscustomobject]@{Scope=$owner.Scope;RunId=$owner.RunId;PacketHash=(At58-Hash ($packet|ConvertTo-Json -Depth 8 -Compress));ExpiresUtc=(At58-Now $owner).AddSeconds(10).ToString('o')}

 }

 try{

  $node=At58T-Submit $ctx $s $intent $action $decision $parent $transport

  if($node.State -cin @('UNKNOWN','SUBMITTING','WARNING_REVIEW','REVIEW')){$session.State='REVIEW';$session.StopReason='ORDER_UNCERTAIN'}

  return $node

 }finally{$ctx.OrderPermit=$null}

 }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}

}

function At58X-Step($owner,$source,$snapshot,$costRows,$receiptBook,[string]$regime,[string]$regimePermission='모의'){

 $state=At58X-Load $owner;if(!$state){At58-Fail 'LIVE_NOT_INITIALIZED' 'LIVE_LEDGER'}

 $ctx=At58X-Context $owner;$mutex=[Threading.Mutex]::new($false,('Local\AT58Live_'+(At58-Hash $ctx.Root)));$held=$false

 try{

  try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true};if(!$held){At58-Fail 'LIVE_BUSY' 'LIVE_CONTROL'}

  $state=At58X-Load $owner;$now=At58-Now $owner;$session=At58-Value $owner 'LiveSession'

  if($source.Hash -cne $state.SourceHash){if($session){$session.State='DISARMED'};At58-Fail 'LIVE_SOURCE_CHANGED' 'LIVE_LEDGER'}

  if($regime -cnotin @('급등','상승','보합','하락','급락') -or $regimePermission -cnotin @('모의','허용','중단')){At58-Fail 'LIVE_REGIME' 'LIVE_CONTROL'}

  $s=At58S-Clone $snapshot;$stamp=At58S-Utc $s.CompletedUtc

  if(($now-$stamp).TotalSeconds -lt -2 -or ($now-$stamp).TotalSeconds -gt 15){At58-Fail 'LIVE_SNAPSHOT_STALE' 'LIVE_CONTROL'}

  $book=At58T-Load $ctx;$days=@($s.Day);if($s.PriorDay){$days+=,$s.PriorDay};$extraDays=At58-Value $s 'HistoryDays';if($extraDays){$days+=@($extraDays)}

  foreach($o in $book.Orders){if($o.State -cin @('OPEN','PARTIAL','ACKNOWLEDGED') -and $o.Day -cnotin $days){At58-Fail 'LIVE_HISTORY_WAIT' 'LIVE_CONTROL'}}

  if($book.Orders.Count){$book=At58T-Reconcile $ctx $book (@($s.OrdersToday)+@($s.PriorOrders)) $receiptBook $days $now;At58T-Save $ctx $book}

  $pending=@($book.Orders|Where-Object {$_.State -cin @('UNKNOWN','SUBMITTING','WARNING_REVIEW','REVIEW')})

  if($pending.Count){if($session){$session.State='REVIEW'};At58-Fail 'LIVE_ORDER_REVIEW' 'LIVE_CONTROL'}

  $active=@($book.Orders|Where-Object {$_.State -cin @('OPEN','PARTIAL')});$acked=@($book.Orders|Where-Object State -ceq 'ACKNOWLEDGED')

  $changed=$state.LastRunId -cne $owner.RunId -or $state.LastDay -cne $s.Day

  if($changed){$state.Confirmations=0;$state.Proof='';if($session -and $session.RunId -cne $owner.RunId){$session.State='DISARMED'}}
  if($session -and $session.RunId -ceq $owner.RunId){At58X-Session $owner $session $source.Hash;if($session.Day -cne $s.Day){At58-Fail 'DATE_CHANGE' 'LIVE_CONTROL'}}

  $fresh=(!$state.LastUtc -or $stamp -gt (At58S-Utc $state.LastUtc))

  if(!$state.Market){$state.Market=$regime};$stable=$true

  if($state.Market -cne $regime){$stable=$false;if($state.MarketCandidate -cne $regime){$state.MarketCandidate=$regime;$state.MarketCandidateUtc=$s.CompletedUtc}elseif(($stamp-(At58S-Utc $state.MarketCandidateUtc)).TotalSeconds -ge 30){$state.Market=$regime;$state.MarketCandidate='';$stable=$true}}else{$state.MarketCandidate=''}

  $s=At58R-Pause $state $state.Seed $s $regime

  $p=$null;$plan=$null;$ledgerCode='OK'

  try{$p=At58X-Reconcile $owner $state $book $s $costRows;if(At58R-LimitGoals $ctx $state.Seed $p $s $state.Market $book){$p=At58X-Reconcile $owner $state $book $s $costRows}}catch{$ledgerCode=(At58-Error $_).Code;$p=$null;$state.Confirmations=0;$state.Proof='';if($ledgerCode -ceq 'LIVE_ORDER_REVIEW' -and $session){$session.State='REVIEW'}}

  if($p){
   $state|Add-Member InterestAccepted @($p.InterestAccepted) -Force

   # Revision may rise on an identical REST reconciliation; economic evidence determines the quorum.

   $proof=At58-Hash (@($source.Hash,$s.Day,$p.Qty,$p.Average,$p.Cash,$p.ActualCosts,$p.InterestProof,($book.Fills|ConvertTo-Json -Depth 10 -Compress)) -join '|')

   if($fresh){if($state.Proof -ceq $proof){$state.Confirmations=[math]::Min(2,$state.Confirmations+1)}else{$state.Proof=$proof;$state.Confirmations=1}}

   $s|Add-Member Strategy ([pscustomobject]@{Reconciled=($state.Confirmations -ge 2);Confirmations=$state.Confirmations}) -Force

   $plan=At58L-Candidate $state.Seed $p $s $state.Market $book

  }

  $state.LastRunId=$owner.RunId;$state.LastDay=$s.Day;if($fresh){$state.LastUtc=$s.CompletedUtc};$state.LastCosts=@($costRows);$state.LastBookRevision=$book.Revision;At58X-Save $owner $state

  $code=if($ledgerCode -cne 'OK'){$ledgerCode}elseif(!$session -or $session.State -ceq 'DISARMED'){'LIVE_DISARMED'}else{'LIVE_WAIT'}

  $live=$s.Session.Live -and $s.Quote.Mode -ceq 'LIVE_REST';$closing=$live -and (At58-Kst $now) -ge (At58S-SessionTime $s.Session.Close).AddMinutes(-3)

  $stop=$session -and $session.State -ceq 'STOPPING'

  $riskCancel=$plan -and $active.Count -eq 1 -and $active[0].Intent.Side -ceq '매수' -and ($plan.BuyStopped -or !$state.Seed.Policy.Regimes.($state.Market).BuyEnabled)

  $canAct=$session -and $session.State -cin @('ARMED','STOPPING')

  if($canAct -and $fresh -and $live -and $active.Count -eq 1 -and !$acked.Count -and ($stop -or $closing -or !$stable -or $riskCancel -or $regimePermission -cne '허용' -or $ledgerCode -cne 'OK')){

   $o=$active[0];$i=At58S-Clone $o.Intent;$i.Qty=$o.Remaining;$decision=At58-Hash ($source.Hash+'|CANCEL|'+$o.Key)

   $null=At58X-Dispatch $owner $state $s $i 'CANCEL' $decision $o.Key;$code='LIVE_CANCEL_SENT'

  }elseif($stop -and !$active.Count -and !$acked.Count){$session.State='DISARMED';$code='LIVE_STOPPED'}

  elseif($canAct -and $session.State -ceq 'ARMED' -and $fresh -and $live -and !$closing -and $stable -and $ledgerCode -ceq 'OK' -and $state.Confirmations -ge 2 -and !$active.Count -and !$acked.Count -and $regimePermission -ceq '허용' -and $plan.Intent){

   $decision=At58-Hash ($source.Hash+'|'+$plan.Intent.GoalId+'|'+$book.Orders.Count)

   $null=At58X-Dispatch $owner $state $s $plan.Intent 'NEW' $decision;$code='LIVE_ORDER_SENT'

  }

  if(!$fresh){$code='LIVE_DUPLICATE_SNAPSHOT'}
  elseif($session -and $session.State -ceq 'ARMED' -and $ledgerCode -ceq 'OK'){
   if(!$live){$code='LIVE_MARKET_WAIT'}elseif($closing -and $code -cne 'LIVE_CANCEL_SENT'){$code='LIVE_CLOSE_WAIT'}elseif($state.Confirmations -lt 2){$code='LIVE_RECONCILE_WAIT'}
  }

  $book=At58T-Load $ctx

  return [pscustomobject]@{DailyStages=(At58D-Usage $book $s.Day $state.Seed $(if($p){@($p.Held)}else{@()}));Mode=$(if($state.TestOnly){'LIVE_TEST'}else{'LIVE_CONTROL'});Code=$code;ExecutionEnabled=($session -and $session.State -cin @('ARMED','STOPPING') -and !$state.TestOnly -and $live);State=$(if($session){$session.State}else{'DISARMED'});OrdersSent=$(if($state.TestOnly){0}else{@($book.Orders|Where-Object Day -ceq $s.Day).Count});SimulatedSubmissions=$(if($state.TestOnly){$book.Orders.Count}else{0});Market=$state.Market;RegimePermission=$regimePermission;Reconciled=($ledgerCode -ceq 'OK' -and $state.Confirmations -ge 2);Confirmations=$state.Confirmations;Portfolio=$p;Plan=$plan;Orders=@($book.Orders);Fills=@($book.Fills);TestOnly=$state.TestOnly}

 }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}

}



# Explicit application adapter; importing it neither starts a loop nor arms execution.

# Input diagnostics are observational: no retries, input substitutions or control changes.
function At58ID-Error($record){
 $type='';$hr=0;$network='';$http=0
 try{
  $e=$record.Exception
  for($i=0;$e -and $i -lt 8;$i++){
   $n=$e.GetType().Name
   $type=if($n -cin @('IOException','FileNotFoundException','DirectoryNotFoundException','UnauthorizedAccessException','CryptographicException','FormatException','ArgumentException','InvalidOperationException','WebException','TimeoutException','RuntimeException','JsonReaderException','PSArgumentException','InvalidDataException')){$n}else{'Other'}
   $hr=[int]$e.HResult
   if($e -is [Net.WebException]){$network=[string]$e.Status}
   try{if($e.Response -and [int]$e.Response.StatusCode -ge 100 -and [int]$e.Response.StatusCode -le 599){$http=[int]$e.Response.StatusCode}}catch{}
   $e=$e.InnerException
  }
 }catch{}
 if($network -cnotin @('Timeout','NameResolutionFailure','ConnectFailure','ConnectionClosed','ReceiveFailure','SendFailure','ProtocolError','TrustFailure','SecureChannelFailure','RequestCanceled','ProxyNameResolutionFailure','KeepAliveFailure','UnknownError')){$network=''}
 return [pscustomobject]@{ErrorType=$type;HResult=$hr;Win32=($hr -band 65535);Network=$network;Http=$http}
}
function At58ID-File([string]$root){
 try{$f=[IO.FileInfo]::new((Join-Path $root 'strategy-input.dpapi'));$f.Refresh();return [pscustomobject]@{Exists=$f.Exists;Bytes=$(if($f.Exists){$f.Length}else{0});LastWriteUtc=$(if($f.Exists){$f.LastWriteTimeUtc.ToString('o')}else{''})}}catch{return $null}
}
function At58ID-Write([string]$root,[string]$channel,$entry,[datetime]$now){
 # Each writer owns its channel. Bound disk usage to two 2-MiB files/day, seven days.
 $stream=$null
 try{
  if($channel -cnotin @('read','refresh')){return}
  $dir=Join-Path $root 'input-diagnostics';[void][IO.Directory]::CreateDirectory($dir)
  $day=(At58-Kst $now).ToString('yyyyMMdd');$path=Join-Path $dir ($channel+'-'+$day+'.jsonl')
  $json=$entry|ConvertTo-Json -Depth 8 -Compress
  $bytes=[Text.UTF8Encoding]::new($false).GetBytes($json+[Environment]::NewLine)
  if($bytes.Length -gt 16384){return}
  if([IO.File]::Exists($path) -and ([IO.FileInfo]::new($path)).Length+$bytes.Length -gt 2097152){
   $old=$path+'.1';if([IO.File]::Exists($old)){[IO.File]::Delete($old)};[IO.File]::Move($path,$old)
  }
  $stream=[IO.File]::Open($path,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  $stream.Write($bytes,0,$bytes.Length);$stream.Dispose();$stream=$null
  $cutoff=(At58-Kst $now).AddDays(-6).ToString('yyyyMMdd')
  foreach($file in [IO.Directory]::EnumerateFiles($dir,$channel+'-*.jsonl*')){
   $name=[IO.Path]::GetFileName($file)
   if($name -cmatch ('^'+$channel+'-([0-9]{8})\.jsonl(?:\.1)?$') -and $Matches[1] -clt $cutoff){[IO.File]::Delete($file)}
  }
 }catch{}finally{if($stream){$stream.Dispose()}}
}
function At58ID-ReadState([string]$root,[string]$name){
 $stream=$null;$reader=$null
 try{
  if($name -cnotin @('input-refresh-status.json','input-refresh-success.json')){return $null}
  $stream=[IO.File]::Open((Join-Path $root $name),[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  if($stream.Length -gt 4096){return $null};$reader=[IO.StreamReader]::new($stream);$r=$reader.ReadToEnd()|ConvertFrom-Json
  # Re-project only our bounded identifiers; never forward arbitrary file contents.
  if($r.Schema -cne 'AT-INPUT-REFRESH-1' -or $r.AttemptId -cnotmatch '^[a-f0-9]{32}$' -or $r.Stage -cnotmatch '^[A-Z_]{1,32}$' -or $r.Outcome -cnotin @('RUNNING','INPUT_DONE','DONE','FAILED')){return $null}
  return [pscustomobject]@{AttemptId=$r.AttemptId;Utc=(At58S-Utc $r.Utc).ToString('o');StartedUtc=(At58S-Utc $r.StartedUtc).ToString('o');Stage=$r.Stage;StageUtc=(At58S-Utc $r.StageUtc).ToString('o');Outcome=$r.Outcome;ElapsedMs=[math]::Min(86400000,[math]::Max(0,[long]$r.ElapsedMs));InputSaved=($r.InputSaved -eq $true)}
 }catch{return $null}finally{if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
}
function At58ID-StartRefresh([string]$root){
 try{
  $ctx=@{Root=$root;Id=[guid]::NewGuid().ToString('N');Started=[datetime]::UtcNow;Watch=[Diagnostics.Stopwatch]::StartNew();Stage='START';StageUtc=[datetime]::UtcNow;InputSaved=$false;Failed=$false}
  At58ID-Refresh $ctx 'START'
  return $ctx
 }catch{return $null}
}
function At58ID-Refresh($ctx,[string]$stage,$failure=$null){
 try{
  if(!$ctx){return};$now=[datetime]::UtcNow
  if($stage -cnotin @('START','CONFIG','SNAPSHOT','KEY','AUTH','STRUCTURE','JOURNAL_CONTEXT','INPUT_STRUCTURE','FETCH_ROWS','FETCH_SETTINGS','IMPORT_SETTINGS','VALIDATE','PROTECT','WRITE_INPUT','INPUT_DONE','PRESENTATION','JOURNAL','PUBLISH','ASSET_REPORT','DONE','FAILED')){return}
  if($ctx.Failed){return}
  $outcome='RUNNING'
  if($stage -ceq 'FAILED'){$ctx.Failed=$true;$outcome='FAILED'}else{$ctx.Stage=$stage;$ctx.StageUtc=$now}
  if($stage -ceq 'INPUT_DONE'){$ctx.InputSaved=$true;$outcome='INPUT_DONE'}
  if($stage -ceq 'DONE'){$outcome='DONE'}
  $entry=[pscustomobject]@{Schema='AT-INPUT-REFRESH-1';AttemptId=$ctx.Id;Utc=$now.ToString('o');StartedUtc=$ctx.Started.ToString('o');Stage=$ctx.Stage;StageUtc=$ctx.StageUtc.ToString('o');Outcome=$outcome;ElapsedMs=$ctx.Watch.ElapsedMilliseconds;InputSaved=$ctx.InputSaved}
  if($failure){$entry|Add-Member Error (At58ID-Error $failure)}
  At58-Atomic (Join-Path $ctx.Root 'input-refresh-status.json') ($entry|ConvertTo-Json -Depth 4 -Compress)
  if($stage -ceq 'INPUT_DONE'){At58-Atomic (Join-Path $ctx.Root 'input-refresh-success.json') ($entry|ConvertTo-Json -Depth 4 -Compress)}
  if($stage -cin @('START','INPUT_DONE','DONE','FAILED')){At58ID-Write $ctx.Root 'refresh' $entry $now}
 }catch{}
}
function At58ID-Input($owner,[string]$step,$failure=$null,$raw=$null,$age=$null){
 try{
  $now=At58-Now $owner;$previous=At58-Value $owner 'InputDiagnostic'
  if(!$failure){
   if(!$previous){return}
   $entry=[pscustomobject]@{Schema='AT-INPUT-DIAGNOSTIC-1';Utc=$now.ToString('o');RunId=$owner.RunId;Outcome='INPUT_RECOVERED';Step='COMPLETE';PreviousReason=$previous.Reason}
   At58ID-Write $owner.Root 'read' $entry $now
   $owner.InputDiagnostic=$null
   return
  }
  $errorInfo=At58ID-Error $failure;$reason=$step
  if($step -ceq 'READ'){
   $reason=if($errorInfo.ErrorType -cin @('FileNotFoundException','DirectoryNotFoundException')){'FILE_MISSING'}elseif($errorInfo.ErrorType -ceq 'UnauthorizedAccessException'){'ACCESS_DENIED'}elseif($errorInfo.ErrorType -ceq 'IOException' -and $errorInfo.Win32 -in @(32,33)){'FILE_SHARING'}else{'READ_FAILED'}
  }
  if($step -ceq 'AGE'){$reason=if($age -lt -5){'INPUT_FUTURE'}else{'INPUT_EXPIRED'}}
  if($step -ceq 'ROLLOVER'){$reason=if((At58-Error $failure).Code -ceq 'LIVE_ROLLOVER_WAIT'){'ROLLOVER_WAIT'}else{'INPUT_DAY'}}
  $inputUtc='';try{if($raw){$inputUtc=(At58S-Utc (At58-Value $raw 'Utc')).ToString('o')}}catch{}
  $entry=[pscustomobject]@{Schema='AT-INPUT-DIAGNOSTIC-1';Utc=$now.ToString('o');RunId=$owner.RunId;Outcome='FAILED';Step=$step;Reason=$reason;Error=$errorInfo;InputUtc=$inputUtc;InputAgeSeconds=$(if($null -ne $age){[math]::Round([double]$age,3)}else{$null});File=(At58ID-File $owner.Root);Refresh=(At58ID-ReadState $owner.Root 'input-refresh-status.json');LastSuccessfulRefresh=(At58ID-ReadState $owner.Root 'input-refresh-success.json')}
  $owner.InputDiagnostic=$entry
  At58ID-Write $owner.Root 'read' $entry $now
 }catch{}
}

function At58X-RolloverInput($owner,$source,[datetime]$inputUtc,[datetime]$now){
 # Only verified, fresh input from the immediately preceding date can establish
 # an expected transition. Missing/corrupt input and changed identity still fail.
 $kst=At58-Kst $now;$today=$kst.ToString('yyyyMMdd');$prior=$kst.AddDays(-1).ToString('yyyyMMdd')
 $roll=At58-Value $owner 'LiveRollover'
 if($roll -and ($roll.RunId -cne $owner.RunId -or $roll.Day -cne $today)){$owner.LiveRollover=$null;$roll=$null}
 if($source.Day -cne $today){
  $saved=At58X-Load $owner
  $sameBaseline=$saved -and $saved.SourceHash -ceq $source.Hash
  if($source.Day -ceq $prior -and (At58-Kst $inputUtc).ToString('yyyyMMdd') -ceq $prior -and $sameBaseline){
   if(!$roll){
    $roll=[pscustomobject]@{Schema='AT-LIVE-ROLLOVER-1';RunId=$owner.RunId;Day=$today;PreviousDay=$prior;StartedUtc=$now.ToString('o');Phase='INPUT';InputUtc=$inputUtc.ToString('o')}
    $owner.LiveRollover=$roll
   }
   # A watchdog bounds an incomplete transition; it is never a scheduled delay.
   if($kst.TimeOfDay.TotalSeconds -lt 120){At58-Fail 'LIVE_ROLLOVER_WAIT' 'LIVE_CONTROL'}
  }
  At58-Fail 'LIVE_INPUT_WAIT' 'LIVE_CONTROL'
 }
 if(!$roll -and $kst.TimeOfDay.TotalSeconds -lt 120){
  $saved=At58X-Load $owner
  if($saved -and (At58-Value $saved 'LastDay') -ceq $prior -and $saved.SourceHash -ceq $source.Hash){
   $roll=[pscustomobject]@{Schema='AT-LIVE-ROLLOVER-1';RunId=$owner.RunId;Day=$today;PreviousDay=$prior;StartedUtc=$now.ToString('o');Phase='RECONCILE';InputUtc=$inputUtc.ToString('o')}
   $owner.LiveRollover=$roll
  }
 }
 if($roll -and $roll.Phase -cne 'COMPLETE'){$roll.Phase='RECONCILE';$roll.InputUtc=$inputUtc.ToString('o')}
}

function At58X-RolloverResult($owner,$result,$snapshot){
 $roll=At58-Value $owner 'LiveRollover';if(!$roll -or $roll.RunId -cne $owner.RunId){return $null}
 if($snapshot -and $snapshot.Day -ceq $roll.Day -and $result.Reconciled -and $result.Confirmations -ge 2 -and $result.State -cne 'REVIEW'){$roll.Phase='COMPLETE'}
 return (At58S-Clone $roll)
}

function At58X-Input($owner){

 $step='READ';$diagnosticFailure=$null;$raw=$null;$age=$null
 try{
  try{
   $cipher=[IO.File]::ReadAllText((Join-Path $owner.Root 'strategy-input.dpapi'))
   $step='DECRYPT';$plain=At58-Unprotect $cipher 'AT58-STRATEGY-INPUT-1'
   $step='JSON';$raw=$plain|ConvertFrom-Json
  }catch{$diagnosticFailure=$_;At58-Fail 'LIVE_INPUT_WAIT' 'LIVE_CONTROL'}finally{$cipher=$null;$plain=$null}
 $step='TIMESTAMP'

 $age=((At58-Now $owner)-(At58S-Utc $raw.Utc)).TotalSeconds

 $step='AGE'
 if($age -lt -5 -or $age -gt 120){At58-Fail 'LIVE_INPUT_WAIT' 'LIVE_CONTROL'}

 $step='IMPORT';$source=At58S-Import $raw

 $step='IDENTITY'
  if($source.Scope -cne $owner.Scope -or $source.Symbol -cne $owner.Symbol){At58-Fail 'LIVE_SOURCE_IDENTITY' 'LIVE_CONTROL'}


 $step='REGIME';$modes=@{}

 foreach($i in 17..21){$name=At58S-Cell $raw.Settings $i 0;$mode=At58S-Cell $raw.Settings $i 1

  if($name -cnotin @('급등','상승','보합','하락','급락') -or $modes.ContainsKey($name) -or $mode -cnotin @('허용','모의','중단')){At58-Fail 'LIVE_REGIME' 'LIVE_CONTROL'}

  $modes[$name]=$mode

 }

 if($modes.Count -ne 5){At58-Fail 'LIVE_REGIME' 'LIVE_CONTROL'}

 $step='ROLLOVER'
 At58X-RolloverInput $owner $source (At58S-Utc $raw.Utc) (At58-Now $owner)

 At58ID-Input $owner 'COMPLETE'
 return [pscustomobject]@{Source=$source;Modes=$modes;Utc=$raw.Utc}

 }catch{At58ID-Input $owner $step $(if($diagnosticFailure){$diagnosticFailure}else{$_}) $raw $age;throw}
}

function At58X-Cycle($owner){

 # A host must keep the runtime heartbeat and input cache alive during STOPPING.

 $result=$null;$snapshot=$null;$input=$null;$failure=$null;$now=At58-Now $owner

 try{

  if((At58-Value $owner 'LiveHostProtocol') -ne 2){At58-Fail 'LIVE_HOST_INCOMPATIBLE' 'LIVE_CONTROL'}

  $input=At58X-Input $owner;$state=At58X-Load $owner

  $today=(At58-Kst $now).ToString('yyyyMMdd');$from=if($state){$state.StartDay}else{$today}

  $interest=At58I-Read $owner $from $today
  $costs=At58X-Costs $owner $from $today

  $candles=At58-List $owner '/market/v1/candles/days' @{mrkt_div_code='J';iscd=$owner.Symbol;mod_stpr_cls_code='0'}

  $book=At58T-Load (At58X-Context $owner)

  $older=@($book.Orders|Where-Object {$_.Day -cne $today -and $_.State -cin @('ACKNOWLEDGED','OPEN','PARTIAL','REVIEW')}|Select-Object -ExpandProperty Day -Unique)

  if($older.Count -gt 5){At58-Fail 'LIVE_HISTORY_LIMIT' 'LIVE_CONTROL'}

  $past=@{};foreach($day in $older){$null=At58-Day $day;$past[$day]=@(At58-Orders (At58-List $owner '/trading/v1/orders/history' @{oder_date=$day;deal_cls_code='0';cntg_cls_code='0';sort_stnd_code='2'}) $day)}

  $snapshot=At58-ReadSnapshot $owner
  $snapshot|Add-Member CashInterestEvidence $interest -Force

  if($snapshot.Day -cne $today){At58-Fail 'DATE_CHANGE' 'LIVE_CONTROL'}

  $historyDays=@($snapshot.Day);if($snapshot.PriorDay){$historyDays+=,$snapshot.PriorDay}

  foreach($day in $past.Keys){if($day -ceq $snapshot.PriorDay){$snapshot.PriorOrders=@($past[$day])}else{$snapshot.PriorOrders+=@($past[$day]);$historyDays+=,$day}}

  $snapshot.PriorUnresolved=@($snapshot.PriorOrders|Where-Object {$_.Remaining -gt 0})

  $snapshot|Add-Member HistoryDays $historyDays

  $snapshot|Add-Member Execution (At58E-Run $owner $snapshot)

  $receiptPath=Join-Path $owner.Root 'receipt-book.dpapi';$receipts=$null

  if([IO.File]::Exists($receiptPath)){try{$receipts=(At58-Unprotect ([IO.File]::ReadAllText($receiptPath)) 'AT58-RECEIPTS-1')|ConvertFrom-Json}catch{At58-Fail 'LIVE_RECEIPT_STORAGE' 'LIVE_CONTROL'}}

  $market=At58S-Market $candles $snapshot $input.Source.Policy

  # Initialization creates only a frozen baseline. It never creates/authorizes a session.

  if(!$state){$state=At58X-Initialize $owner $input.Source $snapshot $costs}

  $result=At58X-Step $owner $input.Source $snapshot $costs $receipts $market.Name $input.Modes[$market.Name]

  $snapshot.ExecutionEnabled=$result.ExecutionEnabled;$snapshot|Add-Member Live $result

 }catch{

  $failure=At58-Error $_;$code=$failure.Code;$session=At58-Value $owner 'LiveSession'
  # A broker read can straddle midnight after its input was validated. Route that
  # verified date transition through the same input-refresh gate, never publish
  # the mixed-date snapshot as a successful new-day result.
  if($code -ceq 'DATE_CHANGE'){
   $snapshot=$null
   if($input){try{At58X-RolloverInput $owner $input.Source (At58S-Utc $input.Utc) (At58-Now $owner)}catch{if((At58-Error $_).Code -ceq 'LIVE_ROLLOVER_WAIT'){$code='LIVE_ROLLOVER_WAIT'}}}
  }


   # A failed read still submits nothing. Expected session/date transitions and
   # recoverable read delays retain only the existing in-memory operator intent.
   # Recovery must rebuild two fresh ledger confirmations before any new order.
   $recoverable=$code -cin @('SESSION_CHANGE','DATE_CHANGE','LIVE_INPUT_WAIT','LIVE_ROLLOVER_WAIT','TOKEN_EXPIRED','TIMEOUT','NETWORK','DNS','RATE_LIMIT','LIVE_SNAPSHOT_STALE','LIVE_HISTORY_WAIT')
   if($session -and $session.State -cne 'REVIEW'){
    if($recoverable -and $session.RunId -ceq $owner.RunId -and $session.State -cin @('ARMED','STOPPING')){
     $saved=At58X-Load $owner;if($saved){$saved.Confirmations=0;$saved.Proof='';At58X-Save $owner $saved}
    }else{$session.State='DISARMED';$session.StopReason=$code}
   }

  $result=[pscustomobject]@{Mode='LIVE_CONTROL';Code=$code;ExecutionEnabled=$false;State=$(if($session){$session.State}else{'DISARMED'});Reconciled=$false;Confirmations=0;Portfolio=$null;Plan=$null;Orders=@();Fills=@();OrdersSent=0;TestOnly=((At58-Value $owner 'LiveTestMode') -eq $true)}

  try{$b=At58T-Load (At58X-Context $owner);$result.Orders=@($b.Orders);$result.Fills=@($b.Fills);if(!$result.TestOnly){$result.OrdersSent=@($b.Orders|Where-Object Day -ceq (At58-Kst (At58-Now $owner)).ToString('yyyyMMdd')).Count}}catch{$result.Code='LIVE_BOOK_UNREADABLE';$result.State='REVIEW';if($session){$session.State='REVIEW'}}

 }

 $now=At58-Now $owner

 $summary=[pscustomobject]@{Schema='AT-LIVE-STATUS-1';HostProtocol=2;RunId=$owner.RunId;Utc=$now.ToString('o');Mode=$result.Mode;Code=$result.Code;State=$result.State;ExecutionEnabled=$result.ExecutionEnabled;OrdersSent=$result.OrdersSent;Reconciled=$result.Reconciled;Confirmations=$result.Confirmations;OpenOrders=@($result.Orders|Where-Object {$_.State -cin @('ACKNOWLEDGED','OPEN','PARTIAL')}).Count;UncertainOrders=@($result.Orders|Where-Object {$_.State -cin @('SUBMITTING','UNKNOWN','WARNING_REVIEW','REVIEW')}).Count;TestOnly=$result.TestOnly}

 # Only bounded machine identifiers are persisted; never the response body or message.
 if($failure){
  $api=[string]$failure.Api;if($api -cnotmatch '^(?:(?:EGW|IGW)[0-9]{5}|[0-9]{4,5})?$'){$api=''}
  $stage=[string]$failure.Stage;if($stage -cnotmatch '^[A-Za-z0-9_/-]{1,100}$'){$stage='UNKNOWN'}
  $summary|Add-Member ApiCode $api;$summary|Add-Member Stage $stage
 }

 $rollover=At58X-RolloverResult $owner $result $snapshot
 if($rollover){$summary|Add-Member Rollover $rollover}

 $dir=(At58X-Context $owner).Root

 try{

  if($snapshot){At58-Atomic (Join-Path $dir 'snapshot.dpapi') (At58-Protect ($snapshot|ConvertTo-Json -Depth 45 -Compress) 'AT-LIVE-SNAPSHOT-1')}

  At58-Atomic (Join-Path $dir 'status.json') ($summary|ConvertTo-Json -Depth 6 -Compress)

  [IO.File]::AppendAllText((Join-Path $dir ('live-'+(At58-Kst $now).ToString('yyyyMMdd')+'.jsonl')),($summary|ConvertTo-Json -Depth 6 -Compress)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))

 }catch{if(At58-Value $owner 'LiveSession'){$owner.LiveSession.State='REVIEW'};At58-Fail 'LIVE_STATUS_STORAGE' 'LIVE_CONTROL'}

 return [pscustomobject]@{Snapshot=$snapshot;Result=$result;Status=$summary}

}

function At58X-MaintenanceDecision($status,[string]$runId,[datetime]$now){

 # Pure host-v2 contract. The existing readonly host does NOT call this function.

 try{

  foreach($field in @('Schema','HostProtocol','RunId','Utc','TestOnly','State','ExecutionEnabled','OpenOrders','UncertainOrders','Reconciled','Confirmations')){if($null -eq (At58-Value $status $field)){return 'DEFER_IDENTITY'}}

  foreach($field in @('TestOnly','ExecutionEnabled','Reconciled')){if($status.$field -isnot [bool]){return 'DEFER_IDENTITY'}}

  foreach($field in @('OpenOrders','UncertainOrders','Confirmations')){$null=At58S-Num $status.$field 0 1000000 $true}

 if(!$status -or $status.Schema -cne 'AT-LIVE-STATUS-1' -or $status.HostProtocol -ne 2 -or $status.RunId -cne $runId){return 'DEFER_IDENTITY'}

 $age=($now-(At58S-Utc $status.Utc)).TotalSeconds;if($age -lt -2 -or $age -gt 20){return 'DEFER_STALE'}

 if($status.TestOnly){return 'DEFER_TEST_STATUS'}

 if($status.State -ceq 'REVIEW' -or $status.UncertainOrders -gt 0){return 'DEFER_REVIEW'}

 if($status.ExecutionEnabled -or $status.State -cne 'DISARMED' -or $status.OpenOrders -gt 0){return 'DEFER_ACTIVE'}

 if(!$status.Reconciled -or $status.Confirmations -lt 2){return 'DEFER_RECONCILE'}

 return 'QUIESCENT'

 }catch{return 'DEFER_IDENTITY'}

}



function At58X-Mailbox([string]$runId){

 return [hashtable]::Synchronized(@{RunId=$runId;Mode='PAPER';State='DISARMED';StopRequested=$false;Command=$null;LastCommand='';CommandError='';Last=$null;LastUtc='';SourceHash='';UiUtc=[datetime]::UtcNow.ToString('o');Busy=$false;TelegramPermit=$null;TelegramConsumed=''})

}

function At58X-Queue($box,[string]$action,[string]$hash='',$limits=$null,[datetime]$now=[datetime]::UtcNow,[string]$consentId=''){

 if($action -cnotin @('PREPARE','ARM','ARM_AUTO','ARM_TELEGRAM','STOP')){At58-Fail 'LIVE_COMMAND' 'LIVE_CONTROL'}

 [Threading.Monitor]::Enter($box.SyncRoot)

 try{

  if($action -ceq 'STOP'){$box.StopRequested=$true;$box.TelegramPermit=$null}

  elseif($box.Command){At58-Fail 'LIVE_COMMAND_PENDING' 'LIVE_CONTROL'}

  if($action -cin @('ARM','ARM_AUTO','ARM_TELEGRAM')){$limits=At58C-Limits $limits;if($hash -cnotmatch '^[a-f0-9]{64}$'){At58-Fail 'LIVE_SOURCE_CHANGED' 'LIVE_CONTROL'}}

  $box.Command=[pscustomobject]@{Id=[guid]::NewGuid().ToString();RunId=$box.RunId;Action=$action;SourceHash=$hash;Limits=$limits;Utc=$now.ToString('o');ConsentId=$consentId}

 }finally{[Threading.Monitor]::Exit($box.SyncRoot)}

}

function At58X-ManagedGate($owner,[string]$action){

 if(!(At58-Value $owner 'LiveManaged')){return}

 $box=At58-Value $owner 'LiveMailbox';$now=At58-Now $owner

 if(!$box -or $box.RunId -cne $owner.RunId -or $box.Mode -cne 'LIVE'){At58-Fail 'LIVE_UI_IDENTITY' 'LIVE_CONTROL'}

 $age=($now-(At58S-Utc $box.UiUtc)).TotalSeconds

 if($age -lt -2 -or $age -gt 15){At58-Fail 'LIVE_UI_STALE' 'LIVE_CONTROL'}

 if($box.StopRequested -and $action -cne 'CANCEL'){At58-Fail 'LIVE_STOP_REQUESTED' 'LIVE_CONTROL'}

}

function At58X-Commands($owner,$box){

 if($box.RunId -cne $owner.RunId){At58-Fail 'LIVE_UI_IDENTITY' 'LIVE_CONTROL'}

 $owner.LiveMailbox=$box;$owner.LiveManaged=$true

 if($box.StopRequested){At58X-Stop $owner}

 [Threading.Monitor]::Enter($box.SyncRoot)

 try{$command=$box.Command;$box.Command=$null}finally{[Threading.Monitor]::Exit($box.SyncRoot)}

 if(!$command){return}

 if($command.Id -ceq $box.LastCommand){return};$box.LastCommand=$command.Id;$box.CommandError=''

 try{

  if($command.RunId -cne $owner.RunId){At58-Fail 'LIVE_UI_IDENTITY' 'LIVE_CONTROL'}

  $age=((At58-Now $owner)-(At58S-Utc $command.Utc)).TotalSeconds

  if($age -lt -2 -or $age -gt 60){At58-Fail 'LIVE_COMMAND_EXPIRED' 'LIVE_CONTROL'}

  $action=$command.Action
  if($action -ceq 'ARM_AUTO'){At58AS-Guard $owner $box $command;$action='ARM'}
  elseif($action -ceq 'ARM_TELEGRAM'){At58TG-Guard $owner $box $command;$action='ARM'}

  switch -Exact ($action){

   'PREPARE' {if($owner.LiveHostProtocol -ne 2){At58-Fail 'LIVE_HOST_INCOMPATIBLE' 'LIVE_CONTROL'};$box.Mode='LIVE';$box.StopRequested=$false}

   'ARM' {

    if($owner.LiveHostProtocol -ne 2 -or $box.Mode -cne 'LIVE'){At58-Fail 'LIVE_HOST_INCOMPATIBLE' 'LIVE_CONTROL'}

    if($box.StopRequested){At58-Fail 'LIVE_STOP_REQUESTED' 'LIVE_CONTROL'}

    if(!$box.Last -or !$box.Last.Reconciled -or $box.Last.State -ceq 'REVIEW'){At58-Fail 'LIVE_RECONCILE_WAIT' 'LIVE_CONTROL'}

    # A command cannot change strategy identity, limits, or process while waiting in the worker queue.

    $input=At58X-Input $owner

    if($command.SourceHash -cne $input.Source.Hash -or $box.SourceHash -cne $command.SourceHash){At58-Fail 'LIVE_SOURCE_CHANGED' 'LIVE_CONTROL'}

    $session=At58X-NewSession $owner $command.SourceHash $command.Limits

    At58X-Authorize $owner $session $command.SourceHash

   }

   'STOP' {

    if(!(At58-Value $owner 'LiveSession')){

     $state=At58X-Load $owner;if($state){$owner.LiveSession=At58X-NewSession $owner $state.SourceHash ([pscustomobject]@{MaxOrderQty=1;MaxOrderAmount=5;DailyBuyAmount=5;DailySubmissions=1})}

    }

    At58X-Stop $owner

   }

   default {At58-Fail 'LIVE_COMMAND' 'LIVE_CONTROL'}

  }

 }catch{$box.CommandError=(At58-Error $_).Code;if(At58-Value $owner 'LiveSession'){$owner.LiveSession.State='DISARMED'}}

}

function At58X-ManagedCycle($owner,$box){

 $box.Busy=$true

 try{

  # Recovery and command parsing must also revoke activation if storage fails.

  if((At58X-Load $owner) -and $box.Mode -ceq 'PAPER'){$box.Mode='LIVE'}

  At58X-Commands $owner $box

  if($box.Mode -cne 'LIVE'){return (At58-Cycle $owner)}

  $r=At58X-Cycle $owner;$now=At58-Now $owner;$owner.Sequence++

  $valid=$null -ne $r.Snapshot;$dayWait=!$valid -and $r.Result.Code -ceq 'LIVE_ROLLOVER_WAIT';$owner.Failures=if($valid){0}elseif($dayWait){$owner.Failures}else{[math]::Min(10,$owner.Failures+1)}

  if($valid){$owner.LastSuccess=$now.ToString('o');$owner.Snapshot=$r.Snapshot}

  $status=At58-Status $owner $(if($valid){'READ_OK'}elseif($dayWait){'RETRY'}else{'READ_ERROR'}) $(if($valid){'OK'}else{$r.Result.Code})

  $status.ExecutionEnabled=$r.Result.ExecutionEnabled;$status|Add-Member OrdersSent $r.Result.OrdersSent -Force

  $status|Add-Member HostProtocol 2;$status|Add-Member Live $r.Status
  if(At58-Value $r.Status 'Stage'){$status.Stage=$r.Status.Stage;$status.ApiCode=[string](At58-Value $r.Status 'ApiCode' '')}

  if($valid){

   $r.Snapshot|Add-Member Live $r.Result -Force;$r.Snapshot|Add-Member StrategyEnabled $true -Force

   At58-Atomic (Join-Path $owner.Root 'snapshot.dpapi') (At58-Protect ($r.Snapshot|ConvertTo-Json -Depth 45 -Compress))

  }

  At58-SaveStatus $owner $status

  $box.State=$r.Result.State;$box.Last=$r.Status;$box.LastUtc=$now.ToString('o')

  $state=At58X-Load $owner;$box.SourceHash=if($state){$state.SourceHash}else{''}

  if($box.StopRequested -and $r.Result.State -ceq 'DISARMED' -and !$r.Status.OpenOrders -and !$r.Status.UncertainOrders){$box.StopRequested=$false}

  return [pscustomobject]@{Ok=$valid;Status=$status;Snapshot=$r.Snapshot;RetrySeconds=$(if($dayWait -or $r.Result.State -cin @('ARMED','STOPPING')){5}else{15})}

 }catch{

  $box.State='REVIEW';$box.CommandError=(At58-Error $_).Code

  if(At58-Value $owner 'LiveSession'){$owner.LiveSession.State='REVIEW'}

  throw

 }finally{$box.Busy=$false}

}


function At58D-Limits {return [pscustomobject]@{Mode='DAILY_STAGES';MaxBuyStages=3}}
function At58D-Usage($book,[string]$day,$source=$null,[object[]]$held=@()){
 $null=At58-Day $day;$filled=@{};$reserved=@{};$nodes=@{}
 $ledger=At58-Value $source 'Ledger'
 if($ledger){foreach($row in $ledger.Rows){if($row.Day -ceq $day -and $row.Side -ceq '매수'){$stage=[int](At58S-Num $row.Stage 1 30 $true);$filled[[string]$stage]=$true}}}
 foreach($o in $book.Orders){
  if($nodes.ContainsKey([string]$o.Key)){At58-Fail 'DAILY_STAGE_IDENTITY' 'CONTROLLER'};$nodes[[string]$o.Key]=$o
  if($o.Intent.Side -ceq '매수' -and $o.Action -cne 'CANCEL' -and $o.State -cin @('ACKNOWLEDGED','OPEN','PARTIAL','SUBMITTING','UNKNOWN','WARNING_REVIEW','REVIEW')){
   $stage=[int](At58S-Num $o.Intent.Stage 1 30 $true);$reserved[[string]$stage]=$true
  }
 }
 foreach($f in $book.Fills){
  if(!$nodes.ContainsKey([string]$f.OrderKey)){At58-Fail 'DAILY_STAGE_IDENTITY' 'CONTROLLER'}
  if($f.Day -ceq $day -and $nodes[[string]$f.OrderKey].Intent.Side -ceq '매수'){
   $null=At58S-Num $f.Qty 1 100000000 $true;$stage=[int](At58S-Num $nodes[[string]$f.OrderKey].Intent.Stage 1 30 $true);$filled[[string]$stage]=$true
  }
 }
 $done=@($filled.Keys|ForEach-Object {[int]$_}|Sort-Object);$pending=@($reserved.Keys|ForEach-Object {[int]$_}|Sort-Object)
 $capacity=@(@($done)+@($pending)|Sort-Object -Unique);$occupied=@($done|Where-Object {$_ -in $held});$rebuy=@($done|Where-Object {$_ -notin $held -and $_ -notin $pending})
 $usage=[pscustomobject]@{Schema='AT-DAILY-STAGES-1';Day=$day;Limit=3;FilledStages=$done;ReservedStages=$pending;OccupiedStages=$occupied;RebuyStages=$rebuy;FilledCount=$done.Count;OccupiedCount=$occupied.Count;CapacityUsed=$capacity.Count;NewStageSlots=[math]::Max(0,3-$capacity.Count);Text=''}
 $usage.Text='오늘 매수 차수 '+$(if($done.Count){$done -join '·'}else{'없음'})+' ('+$done.Count+'/3) · 그중 보유 '+$occupied.Count+'개'
 if($rebuy.Count){$usage.Text+=' · 재매수 가능 '+($rebuy -join '·')+'차'}
 if($pending.Count){$usage.Text+=' · 체결 확인 중 '+($pending -join '·')+'차'}
 return $usage
}
function At58D-Allow($usage,[int]$stage){
 $null=At58S-Num $stage 1 30 $true
 if(!$usage -or $usage.Schema -cne 'AT-DAILY-STAGES-1' -or $usage.Limit -ne 3){At58-Fail 'DAILY_STAGE_IDENTITY' 'CONTROLLER'}
 return ($stage -in @($usage.FilledStages) -or $stage -in @($usage.ReservedStages) -or $usage.NewStageSlots -gt 0)
}

# Confirmed KRW deposit usage interest only. Transfers, dividends, RP principal,
# unknown descriptions and balance differences are never synthesized as income.
function At58I-Amount($row,[string]$name){
 $v=At58-Value $row $name
 if($null -eq $v -or [string]$v -cnotmatch '^\d+(?:\.0+)?$'){At58-Fail 'LIVE_INTEREST_SCHEMA' 'LIVE_LEDGER'}
 try{$n=[decimal]::Parse([string]$v,[Globalization.CultureInfo]::InvariantCulture)}catch{At58-Fail 'LIVE_INTEREST_SCHEMA' 'LIVE_LEDGER'}
 return $n
}
function At58I-Rows($raw,[string]$from,[string]$to){
 $null=At58-Day $from;$null=At58-Day $to
 if($from -gt $to){At58-Fail 'LIVE_INTEREST_DATES' 'LIVE_LEDGER'}
 $items=New-Object 'Collections.Generic.List[object]';$seen=@{}
 foreach($r in $raw){
  $day=[string](At58-Value $r 'tr_date');$null=At58-Day $day
  if($day -lt $from -or $day -gt $to){At58-Fail 'LIVE_INTEREST_DATES' 'LIVE_LEDGER'}
  $name=[string](At58-Value $r 'smcd_name')
  if($name -cne '예탁금이용료'){continue}
  $id=[string](At58-Value $r 'tran_srno');$key=$day+'|'+$id
  if($id -cnotmatch '^\d{1,20}$' -or $seen.ContainsKey($key)){At58-Fail 'LIVE_INTEREST_DUPLICATE' 'LIVE_LEDGER'}
  $seen[$key]=$true;$cancel=[string](At58-Value $r 'cncl_yn')
  if($cancel -ceq 'Y'){continue}
  if($cancel -cne 'N' -or [string](At58-Value $r 'iscd') -cne ''){At58-Fail 'LIVE_INTEREST_SCHEMA' 'LIVE_LEDGER'}
  foreach($field in @('frcr_tr_amt','deal_fee','fee','trtx','srtx')){if((At58I-Amount $r $field) -ne 0){At58-Fail 'LIVE_INTEREST_UNSUPPORTED' 'LIVE_LEDGER'}}
  $gross=At58I-Amount $r 'tr_amt';$income=At58I-Amount $r 'intx';$local=At58I-Amount $r 'rstx'
  if($gross -le 0 -or $income+$local -gt $gross){At58-Fail 'LIVE_INTEREST_AMOUNT' 'LIVE_LEDGER'}
  $net=$gross-$income-$local
  $hash=At58-Hash (@($key,$name,$gross,$income,$local,$net) -join '|')
  $items.Add([pscustomobject]@{Key=$key;Day=$day;Gross=$gross;IncomeTax=$income;LocalTax=$local;Net=$net;Hash=$hash})
 }
 return ,@($items.ToArray()|Sort-Object Key)
}
function At58I-Read($owner,[string]$from,[string]$to){
 $raw=At58-List $owner '/accounts/v1/me/transactions' @{from=$from;to=$to;sort='ASC'}
 $rows=At58I-Rows $raw $from $to
 return [pscustomobject]@{Schema='AT-CASH-INTEREST-1';Scope=$owner.Scope;From=$from;To=$to;Utc=(At58-Now $owner).ToString('o');Rows=@($rows)}
}
function At58I-Evaluate($owner,$state,$snapshot){
 $e=At58-Value $snapshot 'CashInterestEvidence'
 $prior=At58-Value $state 'InterestAccepted';$baseline=At58-Value $state 'InterestBaseline'
 if(!$e){
  # Low-level callers with no evidence retain the original cash comparison.
  # The production cycle always reads evidence before taking its snapshot.
  if(@($prior).Count -and $null -ne $prior){At58-Fail 'LIVE_INTEREST_MISSING' 'LIVE_LEDGER'}
  return [pscustomobject]@{Net=0D;Rows=@();Proof=''}
 }
 if($e.Schema -cne 'AT-CASH-INTEREST-1' -or $e.Scope -cne $owner.Scope -or $e.From -cne $state.StartDay -or $e.To -cne $snapshot.Day -or $e.Rows -isnot [array]){At58-Fail 'LIVE_INTEREST_IDENTITY' 'LIVE_LEDGER'}
 $age=((At58-Now $owner)-(At58S-Utc $e.Utc)).TotalSeconds
 if($age -lt -2 -or $age -gt 60){At58-Fail 'LIVE_INTEREST_STALE' 'LIVE_LEDGER'}
 $seen=@{};foreach($r in $e.Rows){
  if($seen.ContainsKey($r.Key) -or $r.Key -cnotmatch '^\d{8}\|\d{1,20}$' -or $r.Day -lt $e.From -or $r.Day -gt $e.To -or $r.Key.Split('|')[0] -cne $r.Day){At58-Fail 'LIVE_INTEREST_DUPLICATE' 'LIVE_LEDGER'}
  $gross=At58I-Amount $r 'Gross';$income=At58I-Amount $r 'IncomeTax';$local=At58I-Amount $r 'LocalTax';$net=At58I-Amount $r 'Net'
  if($net -ne $gross-$income-$local -or $r.Hash -cne (At58-Hash (@($r.Key,'예탁금이용료',$gross,$income,$local,$net) -join '|'))){At58-Fail 'LIVE_INTEREST_CHANGED' 'LIVE_LEDGER'}
  $seen[$r.Key]=$r
 }
 foreach($old in @($prior)+@($baseline)){
  if($null -eq $old){continue}
  if(!$seen.ContainsKey($old.Key) -or $seen[$old.Key].Hash -cne $old.Hash){At58-Fail 'LIVE_INTEREST_CHANGED' 'LIVE_LEDGER'}
 }
 $excluded=@{};foreach($r in @($baseline)){if($null -ne $r){$excluded[$r.Key]=$true}}
 $hasBaseline=$null -ne $state.PSObject.Properties['InterestBaseline']
 $net=0D;$accepted=New-Object 'Collections.Generic.List[object]'
 foreach($r in $e.Rows){
  # Old ledgers have no intra-day interest checkpoint. Only later dates can
  # be automatically attributed; a same-day discrepancy remains blocked.
  if((!$hasBaseline -and $r.Day -le $state.StartDay) -or $excluded.ContainsKey($r.Key)){continue}
  $net+=$r.Net;$accepted.Add($r)
 }
 $rows=@($accepted.ToArray()|Sort-Object Key)
 return [pscustomobject]@{Net=$net;Rows=$rows;Proof=(At58-Hash (($rows|ForEach-Object {$_.Hash}) -join '|'))}
}

# Local, account-bound opt-in. Publication and import alone never enable this option.
function At58AS-Path($owner){return (Join-Path $owner.Root 'auto-start.dpapi')}
function At58AS-LimitsHash {return (At58-Hash ((At58D-Limits)|ConvertTo-Json -Compress))}
function At58AS-Save($owner,[bool]$enabled){
 $p=[pscustomobject]@{Schema='AT-AUTO-START-1';Enabled=$enabled;ConsentId=[guid]::NewGuid().ToString('N');Scope=$owner.Scope;Symbol=$owner.Symbol;RootHash=(At58-Hash $owner.Root.ToLowerInvariant());LimitsHash=(At58AS-LimitsHash);TestOnly=((At58-Value $owner 'LiveTestMode') -eq $true);ApprovedUtc=(At58-Now $owner).ToString('o')}
 At58-Atomic (At58AS-Path $owner) (At58-Protect ($p|ConvertTo-Json -Compress) 'AT58-AUTO-START-1')
 return $p
}
function At58AS-Load($owner){
 $off=[pscustomobject]@{Enabled=$false;ConsentId='';Code='OFF'}
 if(![IO.File]::Exists((At58AS-Path $owner))){return $off}
 try{
  $p=(At58-Unprotect ([IO.File]::ReadAllText((At58AS-Path $owner))) 'AT58-AUTO-START-1')|ConvertFrom-Json
  if($p.Schema -cne 'AT-AUTO-START-1' -or $p.Enabled -isnot [bool] -or $p.ConsentId -cnotmatch '^[a-f0-9]{32}$' -or $p.Scope -cne $owner.Scope -or $p.Symbol -cne $owner.Symbol -or $p.RootHash -cne (At58-Hash $owner.Root.ToLowerInvariant()) -or $p.LimitsHash -cne (At58AS-LimitsHash) -or $p.TestOnly -isnot [bool] -or $p.TestOnly -ne ((At58-Value $owner 'LiveTestMode') -eq $true)){throw 'AUTO_PREFERENCE_IDENTITY'}
  if((At58S-Utc $p.ApprovedUtc) -gt (At58-Now $owner).AddSeconds(5)){throw 'AUTO_PREFERENCE_TIME'}
  $p|Add-Member Code $(if($p.Enabled){'WAITING'}else{'OFF'}) -Force
  return $p
 }catch{$off.Code='PREFERENCE_INVALID';return $off}
}
function At58AS-ReadJson([string]$path){try{return ([IO.File]::ReadAllText($path)|ConvertFrom-Json)}catch{return $null}}
function At58AS-NewRun($preference,[string]$runId){return @{Enabled=($preference.Enabled -eq $true);ConsentId=$preference.ConsentId;RunId=$runId;Attempted=$false;Suspended=$false;Code=$preference.Code}}
function At58AS-Ready($box,$bundle,$manager,[datetime]$now,[string]$version,[bool]$worker=$false){
 try{
  if(!$box -or $box.Mode -cne 'LIVE' -or $box.RunId -cnotmatch '^[a-fA-F0-9-]{36}$'){return 'WAIT_LEDGER'}
  if($box.StopRequested -or $box.State -cin @('STOPPING','REVIEW')){return 'STOPPED'}
  if($box.State -cne 'DISARMED'){return 'ALREADY_STARTED'}
  if($box.Command -or (!$worker -and $box.Busy)){return 'WAIT_COMMAND'}
  if($box.CommandError){return 'COMMAND_REVIEW'}
  $last=$box.Last
  if(!$last -or $last.Schema -cne 'AT-LIVE-STATUS-1' -or $last.HostProtocol -ne 2 -or $last.RunId -cne $box.RunId -or $last.State -cne 'DISARMED' -or $last.ExecutionEnabled -isnot [bool] -or $last.ExecutionEnabled){return 'WAIT_ACCOUNT'}
  foreach($stamp in @($last.Utc,$box.LastUtc)){$age=($now-(At58S-Utc $stamp)).TotalSeconds;if($age -lt -2 -or $age -gt 30){return 'WAIT_ACCOUNT'}}
  foreach($field in @('Confirmations','OpenOrders','UncertainOrders')){if($last.$field -isnot [int] -and $last.$field -isnot [long]){return 'WAIT_RECONCILE'}}
  if($last.TestOnly -isnot [bool] -or $last.Reconciled -isnot [bool] -or !$last.Reconciled -or $last.Confirmations -ne 2 -or $last.OpenOrders -ne 0 -or $last.UncertainOrders -ne 0 -or $box.SourceHash -cnotmatch '^[a-f0-9]{64}$'){return 'WAIT_RECONCILE'}
  if(!$bundle -or !$manager -or $bundle.Version -cne $version -or $manager.BundleVersion -cne $version -or $bundle.State -cnotin @('CURRENT','DISABLED') -or !$bundle.HostSession -or $bundle.HostSession -cne $manager.HostSession -or $manager.RunId -cne $box.RunId){return 'WAIT_INSTALL'}
  foreach($record in @($bundle,$manager)){$age=($now-(At58S-Utc $record.Utc)).TotalSeconds;if($age -lt -2 -or $age -gt 20){return 'WAIT_INSTALL'}}
  foreach($field in @('CircuitOpen','RepairRunning','RepairTransaction')){if($manager.$field -isnot [bool] -or $manager.$field){return 'WAIT_MANAGER'}}
  if($manager.State -cne 'HEALTHY'){return 'WAIT_MANAGER'}
  return 'READY'
 }catch{return 'WAIT_INVALID_STATUS'}
}
function At58AS-TryQueue($auto,$box,$bundle,$manager,[datetime]$now,[string]$version){
 if(!$auto.Enabled -or $auto.Suspended -or $auto.Attempted){return $false}
 if($auto.RunId -cne $box.RunId){$auto.Suspended=$true;$auto.Code='RUN_CHANGED';return $false}
 $auto.Code=At58AS-Ready $box $bundle $manager $now $version
 if($auto.Code -cin @('STOPPED','ALREADY_STARTED','COMMAND_REVIEW')){$auto.Suspended=$true;return $false}
 if($auto.Code -cne 'READY'){return $false}
 # Exactly one automatic attempt per process. The worker rechecks consent and readiness.
 $auto.Attempted=$true
 try{At58X-Queue $box 'ARM_AUTO' $box.SourceHash (At58D-Limits) $now $auto.ConsentId;$auto.Code='QUEUED';return $true}catch{$auto.Code='COMMAND_REVIEW';return $false}
}
function At58AS-Guard($owner,$box,$command){
 $p=At58AS-Load $owner
 if(!$p.Enabled -or $p.ConsentId -cne (At58-Value $command 'ConsentId') -or (At58-Hash ($command.Limits|ConvertTo-Json -Compress)) -cne $p.LimitsHash){At58-Fail 'LIVE_AUTO_CONSENT' 'LIVE_CONTROL'}
 if($box.Last.TestOnly -ne ((At58-Value $owner 'LiveTestMode') -eq $true)){At58-Fail 'LIVE_AUTO_IDENTITY' 'LIVE_CONTROL'}
 $b=At58AS-ReadJson (Join-Path $owner.ManagementRoot 'bundle-status.json')
 $m=At58AS-ReadJson (Join-Path $owner.ManagementRoot 'manager-status.json')
 $code=At58AS-Ready $box $b $m (At58-Now $owner) $owner.Version $true
 if($code -cne 'READY'){At58-Fail ('LIVE_AUTO_'+$code) 'LIVE_CONTROL'}
}

function At58Window-Options([string]$root){
 $fallback=[pscustomobject]@{UseTray=$true;StartInTray=$true}
 $path=Join-Path $root 'window-preferences.json'
 if(![IO.File]::Exists($path)){return $fallback}
 try{
  $p=[IO.File]::ReadAllText($path)|ConvertFrom-Json
  if($p.Schema -ceq 'AT-WINDOW-1' -and $p.StartInTray -is [bool]){return [pscustomobject]@{UseTray=$true;StartInTray=$p.StartInTray}}
  if($p.Schema -ceq 'AT-WINDOW-2' -and $p.UseTray -is [bool] -and $p.StartInTray -is [bool]){
   return [pscustomobject]@{UseTray=$p.UseTray;StartInTray=($p.UseTray -and $p.StartInTray)}
  }
 }catch{}
 return $fallback
}
function At58Window-UseTray([string]$root){return (At58Window-Options $root).UseTray}
function At58Window-LoadTray([string]$root){return (At58Window-Options $root).StartInTray}
function At58Window-SaveMode([string]$root,[bool]$useTray){
 At58-Atomic (Join-Path $root 'window-preferences.json') (@{Schema='AT-WINDOW-2';UseTray=$useTray;StartInTray=$useTray}|ConvertTo-Json -Compress)
}
function At58Window-SaveTray([string]$root){if(At58Window-UseTray $root){At58Window-SaveMode $root $true}}
function At58Window-Native {
 if('AvataTrayWindow' -as [type]){return}
 Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Windows.Forms;
public sealed class AvataTrayWindow : Form {
    public bool TrayHidden { get; set; }
    protected override bool ShowWithoutActivation { get { return TrayHidden; } }
    protected override CreateParams CreateParams {
        get { CreateParams p = base.CreateParams; if (TrayHidden) p.ExStyle |= 0x08000000; return p; }
    }
    protected override void SetVisibleCore(bool value) {
        if (TrayHidden && value) { if (!IsHandleCreated) CreateHandle(); value = false; }
        base.SetVisibleCore(value);
    }
    private bool restoringFromTray;
    public void EnterTray() {
        if (restoringFromTray) return;
        TrayHidden = true; UpdateStyles(); ShowInTaskbar = false; Hide();
    }
    public void RestoreFromTray() {
        if (IsDisposed || Disposing || restoringFromTray) return;
        restoringFromTray = true;
        try {
            TrayHidden = false; ShowInTaskbar = true; UpdateStyles();
            // Showing/recreating the HWND can reapply its cached minimized placement.
            // Normalize only after Show, and ignore resize-to-tray during this transition.
            Show(); WindowState = FormWindowState.Normal; Activate();
        } finally { restoringFromTray = false; }
    }
}
'@
}

function At58TG-ConfigHash([string]$management){
 try{return (Get-FileHash -LiteralPath (Join-Path $management 'telegram.dpapi') -Algorithm SHA256).Hash.ToLowerInvariant()}catch{return ''}
}
function At58TG-TryQueue($owner,$box,$decision,$bundle,$manager,[datetime]$now){
 if(!$decision){return $false}
 try{
  $pref=At58AS-Load $owner
  if($pref.Enabled -or $pref.Code -cne 'OFF'){return $false}
  if($decision.RunId -cne $owner.RunId -or $decision.Scope -cne $owner.Scope -or $decision.SourceHash -cne $box.SourceHash -or $decision.Nonce -cnotmatch '^[a-f0-9]{32}$'){return $false}
  $remaining=((At58S-Utc $decision.ExpiresUtc)-$now).TotalSeconds
  if($remaining -le 0 -or $remaining -gt 20 -or !$decision.ConfigHash -or $decision.ConfigHash -cne (At58TG-ConfigHash $owner.ManagementRoot)){return $false}
  if((At58AS-Ready $box $bundle $manager $now $owner.Version $true) -cne 'READY' -or $box.Last.TestOnly -ne ((At58-Value $owner 'LiveTestMode') -eq $true)){return $false}
  [Threading.Monitor]::Enter($box.SyncRoot)
  try{
   if($box.TelegramConsumed -ceq $decision.Nonce -or $box.TelegramPermit -or $box.Command -or $box.StopRequested){return $false}
   $box.TelegramConsumed=$decision.Nonce
   $box.TelegramPermit=[pscustomobject]@{Nonce=$decision.Nonce;RunId=$decision.RunId;Scope=$decision.Scope;SourceHash=$decision.SourceHash;ConfigHash=$decision.ConfigHash;ExpiresUtc=$decision.ExpiresUtc;LimitsHash=(At58AS-LimitsHash)}
   At58X-Queue $box 'ARM_TELEGRAM' $box.SourceHash (At58D-Limits) $now $decision.Nonce
   return $true
  }finally{[Threading.Monitor]::Exit($box.SyncRoot)}
 }catch{$box.TelegramPermit=$null;return $false}
}
function At58TG-Guard($owner,$box,$command){
 $permit=$box.TelegramPermit;$box.TelegramPermit=$null
 $now=At58-Now $owner;$pref=At58AS-Load $owner
 if(!$permit -or $pref.Enabled -or $pref.Code -cne 'OFF' -or $permit.Nonce -cne $command.ConsentId -or $permit.RunId -cne $owner.RunId -or $permit.Scope -cne $owner.Scope -or $permit.SourceHash -cne $command.SourceHash -or $permit.ConfigHash -cne (At58TG-ConfigHash $owner.ManagementRoot)){At58-Fail 'LIVE_TELEGRAM_APPROVAL' 'LIVE_CONTROL'}
 if($now -ge (At58S-Utc $permit.ExpiresUtc) -or (At58-Hash ($command.Limits|ConvertTo-Json -Compress)) -cne $permit.LimitsHash -or $permit.LimitsHash -cne (At58AS-LimitsHash)){At58-Fail 'LIVE_TELEGRAM_EXPIRED' 'LIVE_CONTROL'}
 if($box.Last.TestOnly -ne ((At58-Value $owner 'LiveTestMode') -eq $true)){At58-Fail 'LIVE_TELEGRAM_IDENTITY' 'LIVE_CONTROL'}
 $bundle=At58AS-ReadJson (Join-Path $owner.ManagementRoot 'bundle-status.json');$manager=At58AS-ReadJson (Join-Path $owner.ManagementRoot 'manager-status.json')
 $code=At58AS-Ready $box $bundle $manager $now $owner.Version $true
 if($code -cne 'READY'){At58-Fail ('LIVE_TELEGRAM_'+$code) 'LIVE_CONTROL'}
}
