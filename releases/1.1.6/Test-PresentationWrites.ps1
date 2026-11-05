#requires -Version 5.1
param([string]$Root=$PSScriptRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
. (Join-Path $Root 'bundle/At58.Ops.ps1')
. (Join-Path $Root 'bundle/At58.Sheets.ps1')
$script:checks=0;$script:network=0;$script:mode='OK';$script:lastBody=$null;$script:serverOrders=@()
function Check($ok,[string]$name){if(!$ok){throw ('FAILED: '+$name)};$script:checks++;Write-Output ('PASS '+$name)}
function Throws([scriptblock]$body,[string]$code,[string]$name){$found='';try{& $body|Out-Null}catch{$found=$_.Exception.Message};Check ($found -ceq $code) $name}
function Body([int]$orders=3,[string]$price='100'){
 $ranges=@("'메인'!A1:M28","'자동매매현황'!A2","'자동매매현황'!B3","'자동매매현황'!E3","'자동매매현황'!A7","'자동매매현황'!C7","'자동매매현황'!E7","'자동매매현황'!G7","'자동매매현황'!A10","'자동매매현황'!C10","'자동매매현황'!E10","'자동매매현황'!G10","'자동매매현황'!B13","'자동매매현황'!B14","'자동매매현황'!E14","'자동매매현황'!B17","'자동매매현황'!D17","'자동매매현황'!F17","'자동매매현황'!H17","'자동매매현황'!B21","'자동매매현황'!E21","'자동매매현황'!B22","'자동매매현황'!E22","'자동매매현황'!B23","'AT주문내역'!A3","'AT주문내역'!A6:L1005")
 $data=New-Object 'Collections.Generic.List[object]'
 foreach($range in $ranges){
  $rows=New-Object 'Collections.Generic.List[object]'
  if($range -like '*A6:L1005'){
   for($i=0;$i -lt 1000;$i++){$row=[object[]]@('','','','','','','','','','','','');if($i -lt $orders){$row[0]='synthetic';$row[1]='20261105';$row[2]='order'+$i;$row[8]=$price};$rows.Add($row)}
  }elseif($range -ceq "'메인'!A1:M28"){
   for($i=0;$i -lt 28;$i++){$rows.Add([object[]]@('synthetic','','','','','','','','','','','',''))}
  }else{$rows.Add([object[]]@('synthetic'))}
  $data.Add(@{range=$range;majorDimension='ROWS';values=$rows.ToArray()})
 }
 return @{valueInputOption='RAW';data=$data.ToArray()}
}
function Clone($o){return ($o|ConvertTo-Json -Depth 14 -Compress|ConvertFrom-Json)}
function OrderRange($body){return @($body.data|Where-Object {$_.range -like "'AT주문내역'!A6:L*"})[0]}
function Invoke-RestMethod {
 param($Method,$Uri,$Headers,$ContentType,$Body,$TimeoutSec,$MaximumRedirection,$ErrorAction)
 $script:network++;$script:lastBody=([Text.Encoding]::UTF8.GetString($Body)|ConvertFrom-Json)
 if($script:mode -ceq 'FAIL_BEFORE'){throw 'SYNTHETIC_SEND_FAILED'}
 foreach($item in $script:lastBody.data){
  if($item.range -match "^'AT주문내역'!A6:L([0-9]+)$"){
   for($i=0;$i -lt $item.values.Count;$i++){$script:serverOrders[$i]=[object[]]$item.values[$i]}
  }
 }
 if($script:mode -ceq 'APPLY_THEN_TIMEOUT'){throw 'SYNTHETIC_TIMEOUT'}
 $id=if($script:mode -ceq 'WRONG_ID'){'other-sheet'}else{$script:At58SheetId}
 $responses=New-Object 'Collections.Generic.List[object]';foreach($item in $script:lastBody.data){$responses.Add(@{})}
 if($script:mode -ceq 'SHORT_RESPONSE' -and $responses.Count){$responses.RemoveAt(0)}
 return [pscustomobject]@{spreadsheetId=$id;responses=$responses.ToArray()}
}
for($i=0;$i -lt 1000;$i++){$script:serverOrders+=,@('','','','','','','','','','','','')}
$script:At58SheetId='SYNTHETIC_SHEET_1234567890';$base='https://sheets.googleapis.com/v4/spreadsheets/'+$script:At58SheetId;$scope='synthetic-account-a';$now=([datetimeoffset]'2026-11-05T00:00:00Z').UtcDateTime
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('AvataPresentation-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($tmp);$path=Join-Path $tmp 'presentation-state.json'
try{
 $body=Body;$p=Sheet-PresentationPlan $body $null $script:At58SheetId $scope $now
 Check ($p.FullRefresh -and $p.WrittenRanges -eq 26 -and (OrderRange $p.Body).values.Count -eq 1000) 'cold cache preserves full validated repair scope'
 Check ($p.WrittenCells -eq 12388) 'baseline is 12388 cells per presentation'
 $before=ConvertTo-Json -InputObject $body -Depth 14 -Compress
 $r=Sheet-PublishPresentation @{} $base $body $tmp $scope $now;$cache=Ops-ReadJson $path
 Check ($r.FullRefresh -and $cache.Schema -ceq 'AT-SHEET-PRESENTATION-1' -and $cache.OrderRows -eq 3) 'successful first publication stores only confirmed extent'
 Check ((Ops-Utc $cache.FullUtc) -eq $now -and (Ops-Utc $cache.LastWriteUtc) -eq $now) 'first confirmed publication establishes full-refresh clock'
 $text=[IO.File]::ReadAllText($path)
 Check (!$text.Contains('order0') -and !$text.Contains($scope) -and !$text.Contains($script:At58SheetId)) 'cache contains hashes instead of account, sheet or order values'
 Check ((ConvertTo-Json -InputObject $body -Depth 14 -Compress) -ceq $before) 'planning and sending leave validated source body unchanged'
 $calls=$script:network;$r=Sheet-PublishPresentation @{} $base (Body) $tmp $scope $now.AddSeconds(15)
 Check ($script:network -eq $calls -and $r.WrittenRanges -eq 0 -and $r.SkippedRanges -eq 26) 'unchanged presentation makes no HTTP request'
 Check ([IO.File]::ReadAllText($path) -ceq $text) 'no-op publication does not manufacture a new success timestamp'
 $next=Body 3 '101';$p=Sheet-PresentationPlan $next $cache $script:At58SheetId $scope $now.AddSeconds(30)
 Check ($p.WrittenRanges -eq 1 -and (OrderRange $p.Body).range -ceq "'AT주문내역'!A6:L8" -and $p.WrittenCells -eq 36) 'order price change writes only three actual rows'
 $r=Sheet-PublishPresentation @{} $base $next $tmp $scope $now.AddSeconds(30)
 Check ($script:serverOrders[0][8] -ceq '101' -and $r.WrittenCells -eq 36) 'changed order values reach the simulated remote sheet'
 $r=Sheet-PublishPresentation @{} $base (Body 1 '102') $tmp $scope $now.AddSeconds(45)
 Check ($r.WrittenCells -eq 36 -and $script:lastBody.data[0].values.Count -eq 3) 'shrinking order set includes last confirmed tail'
 Check ($script:serverOrders[0][8] -ceq '102' -and $script:serverOrders[1][0] -ceq '' -and $script:serverOrders[2][0] -ceq '') 'removed order rows are explicitly cleared'
 Check ((Ops-ReadJson $path).OrderRows -eq 1) 'successful shrink stores new smaller extent'
 $r=Sheet-PublishPresentation @{} $base (Body 0) $tmp $scope $now.AddSeconds(60)
 Check ($r.WrittenCells -eq 12 -and $script:lastBody.data[0].values.Count -eq 1 -and $script:lastBody.data[0].values[0].Count -eq 12) 'one-row clear retains a two-dimensional matrix on JSON wire'
 Check ($script:serverOrders[0][0] -ceq '' -and (Ops-ReadJson $path).OrderRows -eq 0) 'empty order set clears final row and records zero'
 $r=Sheet-PublishPresentation @{} $base (Body 2) $tmp $scope $now.AddSeconds(75)
 Check ($r.WrittenCells -eq 24 -and $script:serverOrders[1][2] -ceq 'order1') 'new orders expand a previously empty confirmed region'
 $cache=Ops-ReadJson $path;$timed=Body 2;@($timed.data|Where-Object range -ceq "'자동매매현황'!E3")[0].values[0][0]='new timestamp'
 $p=Sheet-PresentationPlan $timed $cache $script:At58SheetId $scope $now.AddSeconds(100)
 Check ($p.WrittenRanges -eq 1 -and $p.WrittenCells -eq 1 -and $p.Body.data[0].range -ceq "'자동매매현황'!E3") 'single clock change writes one cell without order history'
 $null=Sheet-PublishPresentation @{} $base $timed $tmp $scope $now.AddSeconds(200);$cache=Ops-ReadJson $path
 Check ((Ops-Utc $cache.FullUtc) -eq $now -and (Ops-Utc $cache.LastWriteUtc) -eq $now.AddSeconds(200)) 'partial update does not postpone periodic full refresh'
 $p=Sheet-PresentationPlan $timed $cache $script:At58SheetId $scope $now.AddSeconds(300)
 Check ($p.FullRefresh -and $p.WrittenRanges -eq 26 -and (OrderRange $p.Body).values.Count -eq 1000) 'five-minute refresh repairs possible external edits and stale tails'
 $script:serverOrders[999][0]='external stray';$null=Sheet-PublishPresentation @{} $base $timed $tmp $scope $now.AddSeconds(300)
 Check ($script:serverOrders[999][0] -ceq '' -and (Ops-Utc (Ops-ReadJson $path).FullUtc) -eq $now.AddSeconds(300)) 'successful periodic repair removes external tail and advances full clock'
 $cache=Ops-ReadJson $path
 Check ((Sheet-PresentationPlan $timed $cache ('t'*30) $scope $now.AddSeconds(315)).FullRefresh) 'different sheet cannot reuse publication hashes'
 Check ((Sheet-PresentationPlan $timed $cache $script:At58SheetId 'synthetic-account-b' $now.AddSeconds(315)).FullRefresh) 'different account cannot reuse publication hashes'
 foreach($case in @('SCHEMA','RANGES','DUPLICATE','HASH','NEGATIVE','TOO_LARGE','FRACTION','FUTURE_FULL','FUTURE_WRITE','INVALID_TIME')){
  $bad=Clone $cache
  switch($case){
   'SCHEMA' {$bad.Schema='OTHER'}
   'RANGES' {$bad.Ranges=@($bad.Ranges|Select-Object -Skip 1)}
   'DUPLICATE' {$bad.Ranges[0].Range=$bad.Ranges[1].Range}
   'HASH' {$bad.Ranges[0].Hash='wrong'}
   'NEGATIVE' {$bad.OrderRows=-1}
   'TOO_LARGE' {$bad.OrderRows=1001}
   'FRACTION' {$bad.OrderRows=1.5}
   'FUTURE_FULL' {$bad.FullUtc=$now.AddDays(1).ToString('o')}
   'FUTURE_WRITE' {$bad.LastWriteUtc=$now.AddDays(1).ToString('o')}
   'INVALID_TIME' {$bad.FullUtc='invalid'}
  }
  Check ((Sheet-PresentationPlan $timed $bad $script:At58SheetId $scope $now.AddSeconds(315)).FullRefresh) ('invalid cache forces full repair: '+$case)
 }
 $special=Body 0;(OrderRange $special).values[5][0]=0;$p=Sheet-PresentationPlan $special $cache $script:At58SheetId $scope $now.AddSeconds(315)
 Check ($p.Cache.OrderRows -eq 6) 'numeric zero is a populated order cell'
 (OrderRange $special).values[7][0]=$false;$p=Sheet-PresentationPlan $special $cache $script:At58SheetId $scope $now.AddSeconds(315)
 Check ($p.Cache.OrderRows -eq 8) 'boolean false is a populated order cell'
 # Simulate the server applying a larger write before the client times out.
 $script:mode='APPLY_THEN_TIMEOUT'
 Throws {Sheet-PublishPresentation @{} $base (Body 10 '104') $tmp $scope $now.AddSeconds(330)} 'SYNTHETIC_TIMEOUT' 'ambiguous network timeout propagates rather than reporting success'
 Check ($script:serverOrders[9][2] -ceq 'order9' -and (Ops-ReadJson $path).Schema -ceq 'AT-SHEET-PRESENTATION-PENDING-1') 'in-flight marker survives ambiguous server application'
 $script:mode='OK';$r=Sheet-PublishPresentation @{} $base (Body 1 '105') $tmp $scope $now.AddSeconds(345)
 Check ($r.FullRefresh -and $r.WrittenCells -eq 12388 -and $script:serverOrders[9][0] -ceq '') 'retry after ambiguous grow then shrink clears entire unknown tail'
 Check ((Ops-ReadJson $path).OrderRows -eq 1) 'repair success commits latest extent rather than attempted old extent'
 foreach($mode in @('FAIL_BEFORE','WRONG_ID','SHORT_RESPONSE')){
  $script:mode=$mode;$expected=if($mode -ceq 'FAIL_BEFORE'){'SYNTHETIC_SEND_FAILED'}else{'SHEET_RESPONSE'}
  Throws {Sheet-PublishPresentation @{} $base (Body 4 '106') $tmp $scope $now.AddSeconds(360)} $expected ('failed or unconfirmed reply is rejected: '+$mode)
  Check ((Ops-ReadJson $path).Schema -ceq 'AT-SHEET-PRESENTATION-PENDING-1') ('unconfirmed write cannot commit cache: '+$mode)
 }
 $script:mode='OK';$null=Sheet-PublishPresentation @{} $base (Body 4 '106') $tmp $scope $now.AddSeconds(375)
 Check ((Ops-ReadJson $path).Schema -ceq 'AT-SHEET-PRESENTATION-1') 'later successful repair replaces pending marker'
 $bad=Body;$bad.data[0].range="'UserTab'!A1:M28";$calls=$script:network
 Throws {Sheet-PublishPresentation @{} $base $bad $tmp $scope $now.AddSeconds(390)} 'SHEET_WRITE_SCOPE' 'optimization cannot broaden original write allowlist'
 Check ($script:network -eq $calls) 'invalid scope performs no transport call'
 Throws {Sheet-PublishPresentation @{} ($base+'-other') (Body) $tmp $scope $now.AddSeconds(390)} 'SHEET_ID' 'destination must exactly match configured sheet'
 # Durable cache failures must not weaken ambiguity recovery.
 $script:originalWriter=${function:Ops-WriteJson};$script:failCacheSchema=''
 function Ops-WriteJson([string]$path,$value){
  if((Sheet-PresentationGet $value 'Schema' '') -ceq $script:failCacheSchema){throw 'SYNTHETIC_STORAGE_FAILED'}
  & $script:originalWriter $path $value
 }
 try{
  $script:failCacheSchema='AT-SHEET-PRESENTATION-PENDING-1';$calls=$script:network;$saved=[IO.File]::ReadAllText($path)
  Throws {Sheet-PublishPresentation @{} $base (Body 5 '107') $tmp $scope $now.AddSeconds(400)} 'SYNTHETIC_STORAGE_FAILED' 'pending-marker persistence failure propagates'
  Check ($script:network -eq $calls) 'no POST occurs without a durable in-flight marker'
  Check ([IO.File]::ReadAllText($path) -ceq $saved) 'failed pending-marker write preserves previous confirmed cache'
  $script:failCacheSchema='AT-SHEET-PRESENTATION-1'
  Throws {Sheet-PublishPresentation @{} $base (Body 8 '108') $tmp $scope $now.AddSeconds(415)} 'SYNTHETIC_STORAGE_FAILED' 'success-cache persistence failure propagates'
  Check ((Ops-ReadJson $path).Schema -ceq 'AT-SHEET-PRESENTATION-PENDING-1' -and $script:serverOrders[7][2] -ceq 'order7') 'failed final cache commit leaves durable pending marker after remote success'
  $script:failCacheSchema='';$r=Sheet-PublishPresentation @{} $base (Body 1 '109') $tmp $scope $now.AddSeconds(430)
  Check ($r.FullRefresh -and $script:serverOrders[7][0] -ceq '') 'next cycle repairs unknown extent after success-cache write failure'
 }finally{${function:Ops-WriteJson}=$script:originalWriter}
 $worker=[IO.File]::ReadAllText((Join-Path $Root 'bundle/At58.SheetWorker.ps1'))
 Check ($worker.Contains('Sheet-PublishPresentation $headers $base $body $OutputRoot $s.Scope') -and $worker.IndexOf('Sheet-JournalSync') -lt $worker.IndexOf('Sheet-PublishPresentation')) 'worker publishes optimized body only after input and journal validation'
 Check ($worker.Contains('WrittenCells=$presentation.WrittenCells') -and $worker.Contains('SnapshotUtc=$s.CompletedUtc')) 'status records transmitted size and current snapshot provenance'
 Write-Output ('PRESENTATION WRITE CHECKS PASSED: '+$script:checks+'; mocked transport only')
}finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Recurse -Force}}
