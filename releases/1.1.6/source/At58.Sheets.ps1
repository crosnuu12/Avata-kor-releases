# Reads strategy inputs and mirrors verified broker fills into the existing journal. No broker calls.

$script:At58SheetId=''

$script:At58SheetPump=$null

[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

function Sheet-Unprotect([string]$cipher,[string]$purpose){

 Add-Type -AssemblyName System.Security

 $b=$null;try{$b=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($cipher),[Text.Encoding]::UTF8.GetBytes($purpose),[Security.Cryptography.DataProtectionScope]::CurrentUser);return [Text.Encoding]::UTF8.GetString($b)}finally{if($b){[Array]::Clear($b,0,$b.Length)}}

}

function Sheet-Config([string]$root){

 $path=Join-Path $root 'sheets.json';$c=Ops-ReadJson $path

 if($c){return $c}

 if([IO.File]::Exists($path)){return [pscustomobject]@{Enabled=$false;KeyPath=''}}

 $keyPath='';try{$p=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'esbada\connection.dpapi';$v=(Sheet-Unprotect ([IO.File]::ReadAllText($p)) 'esbada-meritz-preferences-v1')|ConvertFrom-Json;$keyPath=[string]$v.JsonPath} catch{} finally{$v=$null}

 return [pscustomobject]@{Enabled=$false;KeyPath=$keyPath;SheetId=''}

}

function Sheet-Id([string]$value){
 $id=$value.Trim()
 if($id -cmatch '^https://docs\.google\.com/spreadsheets/d/([A-Za-z0-9_-]{20,100})(?:/[^\s]*)?$'){$id=$Matches[1]}
 if($id -cnotmatch '^[A-Za-z0-9_-]{20,100}$'){throw 'SHEET_ID'}
 return $id
}

function Sheet-Serial([datetime]$utc){return ([TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($utc,'Korea Standard Time')).ToOADate()}

function Sheet-Number($v){$n=0D;if($null -eq $v -or ![decimal]::TryParse([string]$v,[Globalization.NumberStyles]::Number,[Globalization.CultureInfo]::InvariantCulture,[ref]$n)){throw 'SHEET_DATA_INVALID'};return $n}

function Sheet-Build($snapshot,$status,$manager,[datetime]$now=(Ops-Now)){

 if(Ops-Get $snapshot 'Live'){return (Sheet-BuildLive $snapshot $status $manager $now)}

 if(!$snapshot -or $snapshot.Schema -cne 'AT-DIRECT-1' -or $snapshot.Source -cne 'MERITZ_DIRECT' -or $snapshot.ExecutionEnabled -ne $false){throw 'SHEET_SNAPSHOT_INVALID'}

 if($snapshot.Symbol -cnotmatch '^[A-Z0-9]{6}$' -or $snapshot.Day -cnotmatch '^\d{8}$'){throw 'SHEET_SNAPSHOT_INVALID'}

 $stamp=Ops-Utc $snapshot.CompletedUtc;if(($stamp-$now).TotalSeconds -gt 5){throw 'SHEET_FUTURE_DATA'}

 $p=Sheet-Number $snapshot.Quote.Price;$q=Sheet-Number $snapshot.TargetQty;$avg=Sheet-Number $snapshot.TargetAverage;$cash=Sheet-Number $snapshot.Cash.Orderable

 if($p -le 0 -or $q -lt 0 -or $q -ne [decimal]::Truncate($q) -or $avg -lt 0){throw 'SHEET_DATA_INVALID'}

 $today=@($snapshot.OrdersToday|Where-Object {$_.Symbol -ceq $snapshot.Symbol});$prior=@($snapshot.PriorUnresolved|Where-Object {$_.Symbol -ceq $snapshot.Symbol})

 $all=@($today)+@($prior);if($all.Count -gt 1000){throw 'SHEET_ORDER_LIMIT'}

 $orderRows=New-Object 'Collections.Generic.List[object]';$seen=@{}

 foreach($o in @($all|Sort-Object Day,Id -Descending)){

  if($o.Day -cnotmatch '^\d{8}$' -or $o.Id -cnotmatch '^\d{1,20}$' -or $o.Side -cnotin @('1','2')){throw 'SHEET_ORDER_INVALID'}

  $key=$o.Day+'|'+$o.Id;if($seen.ContainsKey($key)){throw 'SHEET_ORDER_DUPLICATE'};$seen[$key]=$true

  $range=if($o.Day -ceq $snapshot.Day){'당일'}else{'최근 영업일 잔량'}

  $orderRows.Add(@($range,$o.Day,$o.Id,$o.Symbol,$(if($o.Side -ceq '2'){'매수'}else{'매도'}),(Sheet-Number $o.Qty),(Sheet-Number $o.Filled),(Sheet-Number $o.Remaining),(Sheet-Number $o.Price),[string]$o.Status,[string]$o.Reject,[string]$o.Original))

 }

 $execution=Ops-Get $snapshot 'Execution'

 $strategy=Ops-Get $snapshot 'Simulation';if(!$strategy){$strategy=Ops-Get $snapshot 'Strategy'}

 if($strategy){

  foreach($o in @($strategy.Orders|Select-Object -Last ([math]::Max(0,1000-$orderRows.Count)))){

   if($o.Id -cnotmatch '^PAPER-[a-f0-9]{24}$' -or $o.Side -cnotin @('매수','매도')){throw 'SHEET_ORDER_INVALID'}

   $orderRows.Add(@(('모의 · '+$o.Stage+'차'),$o.Day,$o.Id,$snapshot.Symbol,$o.Side,(Sheet-Number $o.Qty),(Sheet-Number $o.Filled),([decimal]$o.Qty-[decimal]$o.Filled),(Sheet-Number $o.Price),$o.State,'실제 체결 아님',''))

  }

 }

 while($orderRows.Count -lt 1000){$orderRows.Add(@('','','','','','','','','','','',''))}

 $kind=[string](Ops-Get $manager 'State' 'UNKNOWN');$labels=@{HEALTHY='정상 조회';PAUSED='일시정지';STARTING='시작 중';USER_CLOSE='사용자 종료';RETRYING='재시도 중';PERSISTENT_ERROR='조회 오류 지속';PROCESS_EXIT='프로그램 종료';NO_HEARTBEAT='응답 지연';RESULT_STALE='조회 갱신 지연'}

 $stateText=if($labels.ContainsKey($kind)){$labels[$kind]}else{'상태 확인 필요'}

 if(!$manager -or ($now-(Ops-Utc $manager.Utc)).TotalSeconds -gt 30){$stateText='관리 기록 갱신 지연'}

 $code=[string](Ops-Get $status 'Code' 'UNKNOWN');if($code -cnotmatch '^[A-Z0-9_]{1,40}$'){$code='UNKNOWN'}

 $current=($status -and $manager -and (Ops-Get $status 'RunId') -ceq (Ops-Get $manager 'RunId') -and $code -ceq 'OK' -and (Ops-Get $status 'ExecutionEnabled' $true) -eq $false -and (Ops-Get $status 'OrdersSent' -1) -eq 0 -and ($now-$stamp).TotalSeconds -le 90)

 $basis=if($snapshot.Quote.Mode -ceq 'CLOSED_DAILY'){'장외 종가 · '+$snapshot.Quote.BasisDay}else{'장중 REST 조회'}

 if(!$current){$basis='이전 조회값 표시 · '+$basis}

 $data=New-Object 'Collections.Generic.List[object]'

 function Put([string]$range,$rows){$matrix=New-Object 'Collections.Generic.List[object]';if(($range -like '*A6:L1005' -or $range -ceq "'메인'!A1:M28")){foreach($r in $rows){$matrix.Add([object[]]$r)}}else{$matrix.Add([object[]]@($rows))};$data.Add(@{range=$range;majorDimension='ROWS';values=$matrix.ToArray()})}

 Put "'자동매매현황'!A2" @(@($(if($strategy){'전략 판단 · 모의 주문 · 실주문 꺼짐'}else{'조회 전용 · 실주문 꺼짐'})))

 Put "'자동매매현황'!B3" @(@((Sheet-Serial $stamp)))

 Put "'자동매매현황'!E3" @(@((Sheet-Serial $now)))

 Put "'자동매매현황'!A7" @(@($p));Put "'자동매매현황'!C7" @(@($q));Put "'자동매매현황'!E7" @(@($avg));Put "'자동매매현황'!G7" @(@($cash))

 Put "'자동매매현황'!A10" @(@(($p*$q)));Put "'자동매매현황'!C10" @(@((($p-$avg)*$q)))

 Put "'자동매매현황'!E10" @(@($(if($q -gt 0 -and $avg -gt 0){($p/$avg)-1}else{'—'})))

 Put "'자동매매현황'!G10" @(@($(if($strategy){'모의 운용'}else{'조회 전용'})))

 Put "'자동매매현황'!B13" @(@($(if($strategy){$strategy.Text+' / '+$strategy.Market}else{'전략 입력 대기'})))

 Put "'자동매매현황'!B14" @(@($(if($strategy){[string]$strategy.PaperOrderCount+'건 · 모의 주문'}else{'0건 · 모의 대기'})));Put "'자동매매현황'!E14" @(@($(if($strategy){if($null -ne $strategy.PaperRealized){'모의 '+([decimal]$strategy.PaperRealized).ToString('N0')+'원 · 실제 손익 아님'}else{'모의 손익 계산 대기'}}else{'체결원장 연결 전'})))

 Put "'자동매매현황'!B17" @(@($today.Count));Put "'자동매매현황'!D17" @(@(@($today|Where-Object {$_.Remaining -gt 0}).Count));Put "'자동매매현황'!F17" @(@($prior.Count));Put "'자동매매현황'!H17" @(@($snapshot.Day))

 Put "'자동매매현황'!B21" @(@($stateText));Put "'자동매매현황'!E21" @(@($(if($code -ceq 'OK'){'없음'}else{$code})))

 Put "'자동매매현황'!B22" @(@($(if(Ops-Get $manager 'TelegramReady' $false){'연결 설정됨'}else{'미연결'})))

 Put "'자동매매현황'!E22" @(@($(if(Ops-Get $manager 'CircuitOpen' $false){'중단 · 확인 필요'}elseif(Ops-Get $manager 'AutoRepair' $false){'설정됨 · 실동작 별도 검증'}else{'꺼짐'})))

 Put "'자동매매현황'!B23" @(@($(if($execution){$basis+' / '+$execution.Text}else{$basis})))

 Put "'메인'!A1:M28" (Sheet-Main $snapshot $strategy $stateText $code $current $stamp)

 Put "'AT주문내역'!A3" @(@(('조회일 '+$snapshot.Day+' · '+$snapshot.Symbol+' · 당일 '+$today.Count+'건 / 이전 영업일 잔량 '+$prior.Count+'건')))

 Put "'AT주문내역'!A6:L1005" $orderRows.ToArray()

 return @{valueInputOption='RAW';data=$data.ToArray()}

}

function Sheet-ValidatePayload($body){

 if($body.valueInputOption -cne 'RAW' -or $body.data.Count -ne 26){throw 'SHEET_WRITE_SCOPE'}

 $ranges=@("'메인'!A1:M28","'자동매매현황'!A2","'자동매매현황'!B3","'자동매매현황'!E3","'자동매매현황'!A7","'자동매매현황'!C7","'자동매매현황'!E7","'자동매매현황'!G7","'자동매매현황'!A10","'자동매매현황'!C10","'자동매매현황'!E10","'자동매매현황'!G10","'자동매매현황'!B13","'자동매매현황'!B14","'자동매매현황'!E14","'자동매매현황'!B17","'자동매매현황'!D17","'자동매매현황'!F17","'자동매매현황'!H17","'자동매매현황'!B21","'자동매매현황'!E21","'자동매매현황'!B22","'자동매매현황'!E22","'자동매매현황'!B23","'AT주문내역'!A3","'AT주문내역'!A6:L1005")

 if((@($body.data|ForEach-Object {$_.range}|Sort-Object) -join '|') -cne (($ranges|Sort-Object) -join '|')){throw 'SHEET_WRITE_SCOPE'}

 foreach($d in $body.data){$height=if($d.range -like '*A6:L1005'){1000}elseif($d.range -ceq "'메인'!A1:M28"){28}else{1};$width=if($height -eq 1000){12}elseif($height -eq 28){13}else{1};if($d.values.Count -ne $height){throw 'SHEET_WRITE_SHAPE'};foreach($row in $d.values){if($row -isnot [array] -or @($row).Count -ne $width){throw 'SHEET_WRITE_SHAPE'}}}

}

function Sheet-PresentationGet($value,[string]$name,$default=$null){
 if($null -eq $value){return $default}
 if($value -is [Collections.IDictionary]){if($value.Contains($name)){return $value[$name]}}
 elseif($value.PSObject.Properties[$name]){return $value.$name}
 return $default
}
function Sheet-PresentationPlan($body,$cache,[string]$sheetId,[string]$scope,[datetime]$now=(Ops-Now)){
 # The original full payload remains the authoritative write allowlist/shape.
 Sheet-ValidatePayload $body
 $sheetId=Sheet-Id $sheetId
 if([string]::IsNullOrWhiteSpace($scope) -or $scope.Length -gt 256){throw 'SHEET_SNAPSHOT_INVALID'}
 $key=Ops-Key ('AT-SHEET-PRESENTATION-1|'+$sheetId+'|'+$scope)
 $ranges=@($body.data|ForEach-Object {[string]$_.range})
 $known=$false;$old=@{};$oldRows=0;$fullUtc=''
 try{
  if((Sheet-PresentationGet $cache 'Schema' '') -ceq 'AT-SHEET-PRESENTATION-1' -and (Sheet-PresentationGet $cache 'Key' '') -ceq $key){
   $entries=@(Sheet-PresentationGet $cache 'Ranges' @())
   if($entries.Count -ne $ranges.Count){throw 'CACHE_SHAPE'}
   foreach($entry in $entries){
    $range=[string](Sheet-PresentationGet $entry 'Range' '');$hash=[string](Sheet-PresentationGet $entry 'Hash' '')
    if($range -cnotin $ranges -or $old.ContainsKey($range) -or $hash -cnotmatch '^[a-f0-9]{64}$'){throw 'CACHE_SHAPE'}
    $old[$range]=$hash
   }
   $count=Sheet-PresentationGet $cache 'OrderRows' -1;$n=0
   if(![int]::TryParse([string]$count,[ref]$n) -or $n -lt 0 -or $n -gt 1000){throw 'CACHE_SHAPE'};$oldRows=$n
   $full=Ops-Utc (Sheet-PresentationGet $cache 'FullUtc' '');$fullUtc=$full.ToString('o')
   $written=Ops-Utc (Sheet-PresentationGet $cache 'LastWriteUtc' '')
   if($full -gt $now.AddSeconds(2) -or $written -gt $now.AddSeconds(2) -or $written -lt $full){throw 'CACHE_TIME'}
   $known=$true
  }
 }catch{$known=$false;$old=@{};$oldRows=0;$fullUtc=''}
 $refresh=!$known -or ($now-(Ops-Utc $fullUtc)).TotalSeconds -ge 300
 $next=New-Object 'Collections.Generic.List[object]';$changed=New-Object 'Collections.Generic.List[object]';$cells=0;$used=0
 foreach($d in $body.data){
  $range=[string]$d.range;$hash=Ops-Key (ConvertTo-Json -InputObject $d.values -Depth 8 -Compress)
  $next.Add([pscustomobject]@{Range=$range;Hash=$hash})
  if($range -ceq "'AT주문내역'!A6:L1005"){
   for($i=999;$i -ge 0;$i--){
    $populated=$false
    foreach($v in $d.values[$i]){if($null -ne $v -and !($v -is [string] -and $v.Length -eq 0)){$populated=$true;break}}
    if($populated){$used=$i+1;break}
   }
  }
  if(!$refresh -and $old[$range] -ceq $hash){continue}
  if($range -ceq "'AT주문내역'!A6:L1005"){
   $height=if($refresh){1000}else{[math]::Max(1,[math]::Max($used,$oldRows))}
   $matrix=New-Object 'Collections.Generic.List[object]'
   for($i=0;$i -lt $height;$i++){$matrix.Add([object[]]$d.values[$i])}
   $changed.Add(@{range=("'AT주문내역'!A6:L"+(5+$height));majorDimension='ROWS';values=$matrix.ToArray()});$cells+=$height*12
  }else{
   $changed.Add($d);foreach($row in $d.values){$cells+=@($row).Count}
  }
 }
 $lastWrite=if($known){(Ops-Utc (Sheet-PresentationGet $cache 'LastWriteUtc' '')).ToString('o')}else{''}
 $nextCache=[pscustomobject]@{Schema='AT-SHEET-PRESENTATION-1';Key=$key;FullUtc=$fullUtc;LastWriteUtc=$lastWrite;OrderRows=$used;Ranges=$next.ToArray()}
 return [pscustomobject]@{Body=@{valueInputOption='RAW';data=$changed.ToArray()};Cache=$nextCache;FullRefresh=$refresh;WrittenRanges=$changed.Count;SkippedRanges=($ranges.Count-$changed.Count);WrittenCells=$cells}
}
function Sheet-PublishPresentation($headers,[string]$base,$body,[string]$outputRoot,[string]$scope,[datetime]$now=(Ops-Now)){
 $id=Sheet-Id $script:At58SheetId
 if($base -cne ('https://sheets.googleapis.com/v4/spreadsheets/'+$id)){throw 'SHEET_ID'}
 $path=Join-Path $outputRoot 'presentation-state.json';$cache=Ops-ReadJson $path
 $plan=Sheet-PresentationPlan $body $cache $id $scope $now
 if($plan.WrittenRanges -gt 0){
  # A timeout may follow successful server application. Invalidate the old
  # extent BEFORE sending so a retry/crash cannot leave an unseen larger tail.
  Ops-WriteJson $path @{Schema='AT-SHEET-PRESENTATION-PENDING-1';Key=$plan.Cache.Key;Utc=$now.ToString('o')}
  $reply=Invoke-RestMethod -Method Post -Uri ($base+'/values:batchUpdate') -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes(($plan.Body|ConvertTo-Json -Depth 14 -Compress))) -TimeoutSec 10 -MaximumRedirection 0 -ErrorAction Stop
  if((Sheet-PresentationGet $reply 'spreadsheetId' '') -cne $id -or @(Sheet-PresentationGet $reply 'responses' @()).Count -ne $plan.WrittenRanges){throw 'SHEET_RESPONSE'}
  $plan.Cache.LastWriteUtc=$now.ToString('o');if($plan.FullRefresh){$plan.Cache.FullUtc=$now.ToString('o')}
  Ops-WriteJson $path $plan.Cache
 }
 return [pscustomobject]@{WrittenRanges=$plan.WrittenRanges;SkippedRanges=$plan.SkippedRanges;WrittenCells=$plan.WrittenCells;FullRefresh=$plan.FullRefresh}
}

function Sheet-Pump([string]$bundle,[string]$dataRoot,[string]$managementRoot,$status=$null,[string]$runId=''){

 if(!$script:At58SheetPump){$script:At58SheetPump=@{Job=$null;Next=[datetime]::MinValue;Failures=0}}

 $p=$script:At58SheetPump;$now=Ops-Now

 if($p.Job){

  if(!$p.Job.Process.HasExited){if(($now-$p.Job.Started).TotalSeconds -gt 60){$p.Job.Process.Kill()}else{return}}

  $result=Ops-ReadJson (Join-Path $managementRoot 'sheets-status.json');$ok=$p.Job.Process.HasExited -and $p.Job.Process.ExitCode -eq 0 -and $result -and $result.Code -ceq 'OK'

  $p.Job.Process.Dispose();$p.Job=$null;$p.Failures=if($ok){0}else{[math]::Min(6,$p.Failures+1)};$p.Next=$now.AddSeconds($(if($ok){10}else{[math]::Min(300,30*[math]::Pow(2,$p.Failures))}))

 }

 # A verified new-day request gets one immediate input refresh, without a
 # second worker or an unbounded retry loop. Subsequent failures keep backoff.
 $live=Ops-Get $status 'Live';$roll=Ops-Get $live 'Rollover'
 if($runId -and (Ops-Get $status 'RunId') -ceq $runId -and (Ops-Get $live 'RunId') -ceq $runId -and (Ops-Get $live 'Code') -ceq 'LIVE_ROLLOVER_WAIT' -and (Ops-RolloverState $live $runId $now) -ceq 'WAIT' -and $roll.Phase -ceq 'INPUT'){
  $request=$runId+'|'+$roll.Day
  if(!$p.ContainsKey('RolloverRequest') -or $p.RolloverRequest -cne $request){$p.RolloverRequest=$request;$p.Next=$now}
 }
 if($now -lt $p.Next){return};$c=Sheet-Config $managementRoot

 if(!$c.Enabled){$p.Next=$now.AddSeconds(30);return}

 $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

 $p.Job=Ops-StartProcess $exe @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $bundle 'At58.SheetWorker.ps1'),'-DataRoot',$dataRoot,'-ManagementRoot',$managementRoot) $bundle

}

function Sheet-StopPump {if($script:At58SheetPump -and $script:At58SheetPump.Job){$p=$script:At58SheetPump.Job.Process;try{if(!$p.HasExited){$p.Kill()};$p.Dispose()}catch{};$script:At58SheetPump.Job=$null}}

function Sheet-ShowSettings($owner,[string]$root){

 $d=[Windows.Forms.Form]::new();$d.Text='자동매매 현황 시트';$d.Size=[Drawing.Size]::new(670,400);$d.StartPosition='CenterParent';$d.Font=$owner.Font

 $c=Sheet-Config $root;$label=[Windows.Forms.Label]::new();$label.Location=[Drawing.Point]::new(18,18);$label.Size=[Drawing.Size]::new(610,58);$label.Text='AT 전용 시트의 메인·자동매매현황·AT주문내역 탭에 표시합니다.'+[Environment]::NewLine+'본인의 전용 시트 주소와 Google 서비스 계정 키를 설정하세요.'

 $enabled=[Windows.Forms.CheckBox]::new();$enabled.Text='계좌 현황·매매일지 자동 반영';$enabled.Checked=[bool]$c.Enabled;$enabled.Location=[Drawing.Point]::new(18,85);$enabled.Width=520

 $path=[Windows.Forms.TextBox]::new();$path.Location=[Drawing.Point]::new(18,125);$path.Width=475;$path.ReadOnly=$true;$path.Text=[string]$c.KeyPath

 $browse=[Windows.Forms.Button]::new();$browse.Text='JSON 키 선택';$browse.Location=[Drawing.Point]::new(505,122);$browse.Width=125;$browse.Tag=$path;$browse.Add_Click({$f=[Windows.Forms.OpenFileDialog]::new();$f.Filter='JSON key (*.json)|*.json';try{if($f.ShowDialog() -eq 'OK'){$this.Tag.Text=$f.FileName}}finally{$f.Dispose()}})

 $sheetLabel=[Windows.Forms.Label]::new();$sheetLabel.Text='전용 Google 시트 주소 또는 ID';$sheetLabel.Location=[Drawing.Point]::new(18,165);$sheetLabel.Width=600
 $sheetInput=[Windows.Forms.TextBox]::new();$sheetInput.Location=[Drawing.Point]::new(18,192);$sheetInput.Width=610;$sheetInput.Text=[string](Ops-Get $c 'SheetId' '')
 $info=[Windows.Forms.Label]::new();$info.Location=[Drawing.Point]::new(18,230);$info.Size=[Drawing.Size]::new(610,42);$last=Ops-ReadJson (Join-Path $root 'sheets-status.json');$info.Text=if($last){'최근 전송: '+$last.Code+' / '+$last.At}else{'첫 반영 대기 · 기존 연결이 없으면 MT에서 사용하던 JSON 키를 선택하세요.'}

 $save=[Windows.Forms.Button]::new();$save.Text='설정 저장';$save.Location=[Drawing.Point]::new(505,300);$save.Width=125;$save.Tag=@{Enabled=$enabled;Path=$path;Root=$root;Info=$info;Sheet=$sheetInput}

 $save.Add_Click({$s=$this.Tag;try{if($s.Enabled.Checked -and ![IO.File]::Exists($s.Path.Text)){throw 'KEY_MISSING'};$id=if($s.Sheet.Text -or $s.Enabled.Checked){Sheet-Id $s.Sheet.Text}else{''};Ops-WriteJson (Join-Path $s.Root 'sheets.json') @{Enabled=$s.Enabled.Checked;KeyPath=$s.Path.Text;SheetId=$id};$s.Info.Text='저장 완료 · 다음 전송 주기부터 적용합니다.'}catch{$s.Info.Text='저장 실패 · 시트 주소와 JSON 키 파일을 확인하세요.'}})

 $d.Controls.AddRange(@($label,$enabled,$path,$browse,$sheetLabel,$sheetInput,$info,$save));try{[void]$d.ShowDialog($owner)}finally{$d.Dispose()}

}



function Sheet-StrategyInput($headers,$base,$meta,$snapshot,[string]$dataRoot,$journal=$null,$diagnostics=$null){
 if(!$diagnostics){$diagnostics=At58ID-StartRefresh $dataRoot}
 try{
 At58ID-Refresh $diagnostics 'INPUT_STRUCTURE'

 foreach($item in @(@('매매기준',2026102807),@('사이클관리',2026102806),@('매매일지',1136811970),@('운영설정',2026110202))){

  $found=@($meta.sheets|Where-Object {$_.properties.title -ceq $item[0] -and $_.properties.sheetId -eq $item[1]});if($found.Count -ne 1){throw 'STRATEGY_SHEET_STRUCTURE'}

 }

 $layout=Sheet-JournalLayout $meta
 $ranges=@("'매매기준'!A1:E28","'사이클관리'!A1:E100",$layout.Range)

 $query='?valueRenderOption=UNFORMATTED_VALUE&dateTimeRenderOption=SERIAL_NUMBER';foreach($range in $ranges){$query+='&ranges='+[uri]::EscapeDataString($range)}

 At58ID-Refresh $diagnostics 'FETCH_ROWS'
 $r=Invoke-RestMethod -Method Get -Uri ($base+'/values:batchGet'+$query) -Headers $headers -TimeoutSec 10 -MaximumRedirection 0 -ErrorAction Stop

 if($r.valueRanges.Count -ne 3){throw 'STRATEGY_SHEET_STRUCTURE'}

 $settingsUri=$base+'/values/'+[uri]::EscapeDataString("'운영설정'!A1:C27")+'?valueRenderOption=UNFORMATTED_VALUE'

 At58ID-Refresh $diagnostics 'FETCH_SETTINGS'
 $settings=Invoke-RestMethod -Method Get -Uri $settingsUri -Headers $headers -TimeoutSec 10 -MaximumRedirection 0 -ErrorAction Stop

 At58ID-Refresh $diagnostics 'IMPORT_SETTINGS'
 $legacySettings=Sheet-ImportSettings $settings.values

 # Strategy input belongs to today's read, not to the last successful account snapshot.
 $inputNow=Ops-Now;$inputDay=[TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($inputNow,'Korea Standard Time').ToString('yyyyMMdd')
 $raw=[pscustomobject]@{Schema='AT-STRATEGY-INPUT-1';Utc=$inputNow.ToString('o');Scope=$snapshot.Scope;Day=$inputDay;Symbol=$snapshot.Symbol;Params=$r.valueRanges[0].values;Cycles=$r.valueRanges[1].values;Ledger=$r.valueRanges[2].values;Settings=$legacySettings}

 $journalRows=$raw.Ledger
 $raw.Ledger=(Sheet-JournalFilter $raw.Ledger $journal).Rows
 At58ID-Refresh $diagnostics 'VALIDATE'
 $validated=At58S-Import $raw

 if($inputDay -cne [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Ops-Now),'Korea Standard Time').ToString('yyyyMMdd')){throw 'STRATEGY_DAY_CHANGED'}
 At58ID-Refresh $diagnostics 'PROTECT'
 $encryptedInput=At58-Protect ($raw|ConvertTo-Json -Depth 15 -Compress) 'AT58-STRATEGY-INPUT-1'
 At58ID-Refresh $diagnostics 'WRITE_INPUT'
 try{At58-Atomic (Join-Path $dataRoot 'strategy-input.dpapi') $encryptedInput}finally{$encryptedInput=$null}
 At58ID-Refresh $diagnostics 'INPUT_DONE'

 Ops-WriteJson (Join-Path $dataRoot 'strategy-input-status.json') @{Utc=(Ops-Now).ToString('o');Code='OK';Rows=$validated.Ledger.Rows.Count;Hash=$validated.Hash}
 if($journal){return [pscustomobject]@{Source=$validated;Raw=$raw;Ledger=$journalRows}}

 }catch{At58ID-Refresh $diagnostics 'FAILED' $_;throw}
}



function Sheet-ImportSettings($rows){

 $headers=@(@(0,0,'설정 항목'),@(1,0,'종목코드'),@(2,0,'수익 재투자'),@(3,0,'단기 이동평균 기간'),@(4,0,'중기 이동평균 기간'),@(5,0,'급등·급락 기준 배수'),@(6,0,'변동성 계산 기간'),@(8,0,'시장 상태'),@(9,0,'급등'),@(10,0,'상승'),@(11,0,'하락'),@(12,0,'급락'))

 foreach($h in $headers){if((At58S-Cell $rows $h[0] $h[1]) -cne $h[2]){throw 'STRATEGY_SETTINGS_STRUCTURE'}}

 $legacy=New-Object 'Collections.Generic.List[object]';for($i=0;$i -lt 54;$i++){$legacy.Add([object[]]@('','','','','','',''))}

 $legacy[0][0]='설정 항목'

 foreach($map in @(@(1,1),@(2,3),@(3,6),@(4,7),@(5,23),@(6,24),@(9,17),@(10,18),@(11,19),@(12,20))){$legacy[$map[1]][0]=At58S-Cell $rows $map[0] 0;$legacy[$map[1]][1]=At58S-Cell $rows $map[0] 1}

 foreach($i in 17..20){if($legacy[$i][1] -cnotin @('모의','허용','중단')){throw 'STRATEGY_SETTINGS_STRUCTURE'}}

 if((At58S-Cell $rows 13 0) -ceq '보합'){

  $legacy[21][0]='보합';$legacy[21][1]=At58S-Cell $rows 13 1;$legacy[25][0]='AT-NEUTRAL-1'

  for($i=0;$i -lt 9;$i++){$legacy[26+$i][0]=At58S-Cell $rows (18+$i) 0;$legacy[26+$i][1]=At58S-Cell $rows (18+$i) 1}

 }

 return ,$legacy.ToArray()

}

function Sheet-OptionalNumber($object,[string]$name){$value=Ops-Get $object $name;if($null -eq $value){return '조회 대기'};return (Sheet-Number $value)}

function Sheet-Main($snapshot,$strategy,[string]$stateText,[string]$code,[bool]$current,[datetime]$stamp){

 $main=New-Object 'Collections.Generic.List[object]';for($i=0;$i -lt 28;$i++){$main.Add([object[]]@('','','','','','','','','','','','',''))}

 function MainPut([int]$row,[int]$col,$value){$main[$row-1][$col-1]=$value}

 MainPut 1 1 'ACE K반도체TOP2+ 자동매매'

 MainPut 2 1 $(if($strategy){'모의 운용 · 실주문 꺼짐'}else{'조회 전용 · 전략 입력 대기'})

 $kst=[TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($stamp,'Korea Standard Time')

 MainPut 2 8 ($(if($current){'계좌 조회 '}else{'이전 조회값 '})+$kst.ToString('MM/dd HH:mm:ss'))

 MainPut 3 1 '실계좌 총자산';MainPut 3 4 '잔여예수금 · D+2';MainPut 3 8 '주식 보유수량 · 실계좌';MainPut 3 11 '현재 차수 · 모의'

 MainPut 4 1 (Sheet-OptionalNumber (Ops-Get $snapshot 'Valuation') 'Total');MainPut 4 4 (Sheet-OptionalNumber $snapshot.Cash 'D2');MainPut 4 8 $snapshot.TargetQty

 MainPut 5 1 '주문가능현금 · 실계좌';MainPut 5 4 '현재 예수금';MainPut 5 8 '현재가';MainPut 5 11 '장상황 · 전략 판단'

 MainPut 6 1 $snapshot.Cash.Orderable;MainPut 6 4 (Sheet-OptionalNumber $snapshot.Cash 'Deposit');MainPut 6 8 $snapshot.Quote.Price

 $names=@{급등='급등장';상승='상승장';보합='보합장';하락='하락장';급락='급락장'};$market=[string](Ops-Get $strategy 'Market' '')

 MainPut 6 11 $(if($names.ContainsKey($market)){$names[$market]}else{'판단 대기'})

 $plan=@(Ops-Get $strategy 'Plan' @()|Where-Object {$null -ne $_});$valid=($plan.Count -eq 30);$seen=@{}

 foreach($p in $plan){$stage=Ops-Get $p 'Stage' 0;if($stage -lt 1 -or $stage -gt 30 -or $seen.ContainsKey([string]$stage)){$valid=$false};$seen[[string]$stage]=$true}

 $orders=@(Ops-Get $strategy 'Orders' @()|Where-Object {$null -ne $_ -and $_.State -cin @('ACKNOWLEDGED','PARTIAL','SUBMITTING','UNKNOWN','CANCEL_PENDING')})

 $held=@();if($valid){$held=@($plan|Where-Object {$_.Held}|Sort-Object Stage)};$nextBuy=Ops-Get $strategy 'NextBuy';$nextSell=Ops-Get $strategy 'NextSell';$cycle=Ops-Get $strategy 'Cycle'

 $stageText=if(!$valid){'계획 대기'}elseif($orders.Count){[string]$orders[-1].Stage+'차 '+$orders[-1].Side+' 진행'}elseif($held.Count){[string]$held[-1].Stage+'차 보유'}else{'보유 차수 없음'}

 MainPut 4 11 $stageText

 $paperQty=Ops-Get $strategy 'PaperQty';$paperCash=Ops-Get $strategy 'PaperCash'

 $simText=if($null -ne $paperQty -and $null -ne $paperCash){'모의 보유 '+([decimal]$paperQty).ToString('N0')+'주 / 현금 '+([decimal]$paperCash).ToString('N0')+'원'}else{'모의 잔고 계산 대기'}

 MainPut 7 1 $simText

 MainPut 7 8 $(if($valid){'다음 매수 '+$(if($nextBuy){[string]$nextBuy.Stage+'차'}else{'없음'})+' / 다음 매도 '+$(if($nextSell){[string]$nextSell.Stage+'차'}else{'없음'})+$(if($cycle){' / 사이클 '+$cycle.Id}else{''})}else{'30분할 계획 수신 대기'})

 MainPut 8 1 '급등장 · 상승장 · 보합장 · 하락장 · 급락장'

 $e=Ops-Get $snapshot 'MarketContext'

 if($market -ceq '보합' -and $e){MainPut 8 1 ('보합장 · 박스 '+([decimal]$e.Lower).ToString('N0')+'~'+([decimal]$e.Upper).ToString('N0')+'원 · 하단 매수 / 상단 매도 · 모의 검증 중')}

 MainPut 9 1 '30분할 기준표 · 1~15차';MainPut 9 8 '30분할 기준표 · 16~30차'

 $header=@('차수','상태','매수가','매수량','매도가','매도량')

 for($j=0;$j -lt 6;$j++){MainPut 10 ($j+1) $header[$j];MainPut 10 ($j+8) $header[$j]}

 if($valid){

  foreach($p in @($plan|Sort-Object Stage)){

   $stage=[int]$p.Stage;$row=11+(($stage-1)%15);$col=if($stage -le 15){1}else{8}

   $pending=@($orders|Where-Object {$_.Stage -eq $stage})

   $label=if($pending.Count){$pending[-1].Side+' 진행'}elseif($nextSell -and $nextSell.Stage -eq $stage){'다음 매도'}elseif($p.Held){'보유'}elseif($nextBuy -and $nextBuy.Stage -eq $stage){'다음 매수'}else{'대기'}

   $values=@($stage,$label,(Sheet-Number $p.BuyPrice),(Sheet-Number $p.BuyQty),(Sheet-Number $p.SellPrice),(Sheet-Number $p.SellQty))

   for($j=0;$j -lt 6;$j++){MainPut $row ($col+$j) $values[$j]}

  }

 }

 MainPut 26 1 '기준표는 현재 모의 전략의 가격·수량이며 주문 실행 또는 체결을 의미하지 않습니다.'

 $risk=Ops-Get $strategy 'RiskSummary' '';if($risk){MainPut 26 1 ('모의 보호: '+$risk)}

 MainPut 27 1 ($stateText+' / '+$(if($code -ceq 'OK'){'조회 오류 없음'}else{$code}));MainPut 27 8 $(if(Ops-Get $strategy 'Reconciled' $false){'계좌 대조 완료'}else{'계좌 대조 대기'})

 MainPut 28 1 '총자산·예수금은 계좌 전체, 보유수량·현재가는 이 종목 기준입니다. 장외에는 확인된 종가를 표시합니다.'

  if(Ops-Get $snapshot 'Readiness'){MainPut 28 1 '총자산·예수금: 계좌 전체 / 보유·현재가: 종목 기준 / 실주문 실행 미연결 · 허용 설정과 별도'}

 return ,$main.ToArray()

}



function Sheet-BuildLive($snapshot,$status,$manager,[datetime]$now){

 $l=Ops-Get $snapshot 'Live'

 if(!$l -or $l.Mode -cne 'LIVE_CONTROL' -or $l.TestOnly -ne $false -or $snapshot.ExecutionEnabled -ne $l.ExecutionEnabled -or $l.OrdersSent -lt 0){throw 'SHEET_LIVE_IDENTITY'}

 if(!$status -or !$manager -or $manager.RunId -cne $status.RunId -or (Ops-Get $manager 'HostProtocol' 0) -ne 2){throw 'SHEET_LIVE_IDENTITY'}

 $runtime=[pscustomobject]@{RunId=$status.RunId;HostProtocol=2}

 try{$valid=Ops-LiveStatus $runtime $status $status.RunId $now}catch{throw 'SHEET_LIVE_STATUS'}

 if(!$valid -or $valid.State -cne $l.State -or $valid.OrdersSent -ne $l.OrdersSent){throw 'SHEET_LIVE_STATUS'}

 # Reuse only account-value formatting and the existing 26-range write scope.

 # This clone is never saved as runtime evidence and never goes to an order gate.

 $clean=($snapshot|ConvertTo-Json -Depth 45 -Compress)|ConvertFrom-Json

 foreach($name in @('Live','Simulation','Strategy','Readiness')){$clean.PSObject.Properties.Remove($name)}

 $clean.ExecutionEnabled=$false

 $displayStatus=($status|ConvertTo-Json -Depth 15 -Compress)|ConvertFrom-Json;$displayStatus.ExecutionEnabled=$false;$displayStatus.OrdersSent=0;$displayStatus.PSObject.Properties.Remove('Live')

 $body=Sheet-Build $clean $displayStatus $manager $now

 function LiveCell([string]$range,$value){$target=@($body.data|Where-Object range -ceq $range);if($target.Count -ne 1){throw 'SHEET_WRITE_SCOPE'};$target[0].values=@(,[object[]]@($value))}

 $labels=@{DISARMED='실주문 꺼짐 · 실계좌 원장 조회';ARMED='실주문 실행 중';STOPPING='신규 중지 · AT 잔량취소 중';REVIEW='주문 확인 필요 · 신규 중지'}

 if(!$labels.ContainsKey([string]$l.State)){throw 'SHEET_LIVE_STATUS'}

 $mode=$labels[$l.State];$p=Ops-Get $l 'Portfolio';$plan=Ops-Get $l 'Plan';$stamp=Ops-Utc $snapshot.CompletedUtc

 $current=($status.Code -ceq 'OK' -and ($now-$stamp).TotalSeconds -le 90 -and ($now-(Ops-Utc $manager.Utc)).TotalSeconds -le 30)

 LiveCell "'자동매매현황'!A2" $mode

 LiveCell "'자동매매현황'!G10" '실계좌 원장'

 LiveCell "'자동매매현황'!B13" ($l.Code+' / '+[string](Ops-Get $l 'Market' ''))

 LiveCell "'자동매매현황'!B14" ($l.OrdersSent.ToString()+'건 · 실제 주문 전송(접수·체결과 별도)')

 LiveCell "'자동매매현황'!E14" $(if($p){'전략 누적손익 '+([decimal]$p.Realized).ToString('N0')+'원 / 신규 비용 '+$p.ActualCosts+'원'}else{'체결·비용 대조 대기'})

 LiveCell "'자동매매현황'!B21" $mode

 LiveCell "'자동매매현황'!E21" $l.Code

 LiveCell "'자동매매현황'!B23" '비용은 증권사 일별 합계로 대조하며 주문별 비용은 미확정입니다.'
 $daily=Ops-Get $l 'DailyStages';if($daily){LiveCell "'자동매매현황'!B23" $daily.Text}

 LiveCell "'AT주문내역'!A3" ('실제 계좌 주문 / '+$mode+' / '+$l.Code)

 $adapted=$null

 if($p -and $plan){$adapted=[pscustomobject]@{Market=$l.Market;Plan=@($plan.Rows);Orders=@($p.Orders);NextBuy=$plan.NextBuy;NextSell=$plan.NextSell;Cycle=$p.Cycle;PaperQty=$p.Qty;PaperCash=$p.Cash;Reconciled=$l.Reconciled}}

 $main=Sheet-Main $clean $adapted $mode $l.Code $current $stamp

 $main[1][0]=$mode;$main[2][10]='현재 차수 · 실제 원장'

 $main[6][0]=if($p){'전략 원장 '+$p.Qty+'주 / 현금 '+([decimal]$p.Cash).ToString('N0')+'원 / 신규 체결 비용 '+$p.ActualCosts+'원'}else{'실계좌 원장·비용 대조 대기'}

 if($main[7][0] -is [string]){$main[7][0]=$main[7][0].Replace('모의 검증 중','실계좌 원장 적용')}

 $main[25][0]='하루 신규 매수 차수 최대 3개 · 같은 차수의 매도 후 재매수 허용'
 if($daily){$main[7][0]=$daily.Text}

 $main[26][0]=$mode+' / '+$l.Code

 $main[27][0]='총자산·예수금: 계좌 전체 / 보유·현재가: 종목 기준 / 비용: 조회 시점의 일별 합계 대조'
 $main[27][0]+=' / '+$main[6][0]
 $main[6][0]=Sheet-LiveAttempt $l '매수' $current
 $main[6][7]=Sheet-LiveAttempt $l '매도' $current

 (@($body.data|Where-Object range -ceq "'메인'!A1:M28"))[0].values=$main

 $orderRange=(@($body.data|Where-Object range -ceq "'AT주문내역'!A6:L1005"))[0];$rows=$orderRange.values

 $known=@{};foreach($o in $l.Orders){if($o.BrokerId){$known[$o.Day+'|'+$o.BrokerId]=$o}}

 $shown=@{};$next=0

 for($i=0;$i -lt $rows.Count;$i++){

  if(!$rows[$i][1]){$next=$i;break}

  $key=[string]$rows[$i][1]+'|'+([string]$rows[$i][2]).TrimStart('0');$shown[$key]=$true

  if($known.ContainsKey($key)){$o=$known[$key];$rows[$i][0]='실전 AT · '+$o.Intent.Stage+'차 '+$o.Action;$rows[$i][9]=$o.State;$rows[$i][10]=$o.Issue}else{$rows[$i][0]='계좌 주문 · AT 외부'}

  $next=$i+1

 }

 foreach($o in $l.Orders){

  if($next -ge 1000){throw 'SHEET_ORDER_LIMIT'}

  if($o.BrokerId -and $shown.ContainsKey($o.Day+'|'+$o.BrokerId)){continue}

  $rows[$next]=[object[]]@(('실전 AT · '+$o.Intent.Stage+'차 '+$o.Action),$o.Day,$o.BrokerId,$snapshot.Symbol,$o.Intent.Side,$o.Intent.Qty,$o.Filled,$o.Remaining,$o.Intent.Price,$o.State,$o.Issue,$o.ParentId);$next++

 }

 Sheet-ValidatePayload $body;return $body

}


# Confirmed broker fills are mirrored to the existing journal. This code never calls a broker.
function Sheet-JournalContext($snapshot,[string]$dataRoot){
 $live=Ops-Get $snapshot 'Live'
 if($live -and ($live.Mode -cne 'LIVE_CONTROL' -or $live.TestOnly -ne $false)){throw 'SHEET_JOURNAL_IDENTITY'}
 $owner=@{Root=$dataRoot;Scope=$snapshot.Scope;Symbol=$snapshot.Symbol}
 # An imported ledger may precede the first live snapshot. Verify that ledger directly.
 $state=At58X-Load $owner;if(!$state){if($live){throw 'SHEET_JOURNAL_IDENTITY'};return $null}
 $book=At58T-Load (At58X-Context $owner)
 return (Sheet-JournalCatalog $state $book)
}
# The broker ledger remains fill-level. Only the journal presentation is grouped.
function Sheet-JournalCatalog($state,$book){
 if($state.TestOnly -ne $false -or $book.Mode -cne 'LIVE' -or $state.Scope -cne $book.Scope -or $state.Symbol -cne $book.Symbol){throw 'SHEET_JOURNAL_IDENTITY'}
 $nodes=@{};foreach($o in $book.Orders){if($nodes.ContainsKey($o.Key)){throw 'SHEET_JOURNAL_FILL'};$nodes[$o.Key]=$o}
 $entries=New-Object 'Collections.Generic.List[object]';$keys=@{};$groups=@{}
 # Insertion order is immutable in the broker book. Every cumulative checkpoint
 # remains verifiable when a later notification is appended (even out of time order).
 foreach($f in $book.Fills){
  if($f.Key -cnotmatch '^[a-f0-9]{64}$' -or !$nodes.ContainsKey($f.OrderKey) -or $f.Account -cne $book.Account -or $f.Evidence -cne 'BROKER_NOTIFICATION_RECONCILED'){throw 'SHEET_JOURNAL_FILL'}
  $o=$nodes[$f.OrderKey];$stage=[int](At58S-Num $o.Intent.Stage 1 30 $true)
  if($o.Action -ceq 'CANCEL' -or $o.Intent.Side -cnotin @('매수','매도') -or $f.Day -cne $o.Day -or $f.Time -cnotmatch '^\d{6}(\d{3})?$'){throw 'SHEET_JOURNAL_FILL'}
  $id=At58E-Id $o.BrokerId
  $qty=At58S-Num $f.Qty 1 100000000 $true;$price=At58S-Num $f.Price 0.00001
  if($f.Amount -ne $qty*$price){throw 'SHEET_JOURNAL_FILL'}
  try{$stamp=[datetime]::ParseExact(($f.Day+([string]$f.Time).PadRight(9,'0')),'yyyyMMddHHmmssfff',[Globalization.CultureInfo]::InvariantCulture)}catch{throw 'SHEET_JOURNAL_FILL'}
  $groupId=At58-Hash (@($book.Scope,$book.Account,$book.Symbol,$f.Day,$id)-join '|')
  if(!$groups.ContainsKey($groupId)){$groups[$groupId]=[pscustomobject]@{Id=$groupId;OrderKey=$o.Key;BrokerId=$id;Stage=$stage;Side=$o.Intent.Side;Qty=0D;Amount=0D;Date=$stamp.ToOADate();Digest=$groupId;FillKeys=(New-Object 'Collections.Generic.List[string]');Current=$null}}
  $g=$groups[$groupId]
  if($g.OrderKey -cne $o.Key -or $g.Stage -ne $stage -or $g.Side -cne $o.Intent.Side){throw 'SHEET_JOURNAL_ORDER_CONFLICT'}
  $key='ATF1-'+$f.Key;if($keys.ContainsKey($key)){throw 'SHEET_JOURNAL_DUPLICATE'}
  $entry=[pscustomobject]@{Key=$key;GroupId=$groupId;Kind='FILL';Count=1;Values=[object[]]@($stamp.ToOADate(),$stage,$o.Intent.Side,$price,$qty,[decimal]$f.Amount)}
  $entries.Add($entry);$keys[$key]=$entry;$g.FillKeys.Add($key)
  $g.Qty+=$qty;$g.Amount+=[decimal]$f.Amount;$g.Date=[math]::Min($g.Date,$stamp.ToOADate());$g.Digest=At58-Hash ($g.Digest+'|'+$f.Key)
  $groupKey='ATO1-'+$groupId+'-'+$g.Digest
  $checkpoint=[pscustomobject]@{Key=$groupKey;GroupId=$groupId;Kind='ORDER';Count=$g.FillKeys.Count;Values=[object[]]@($g.Date,$stage,$o.Intent.Side,($g.Amount/$g.Qty),$g.Qty,$g.Amount);BrokerId=$id}
  $keys[$groupKey]=$checkpoint;$g.Current=$checkpoint
 }
 $fills=@($entries.ToArray()|Sort-Object @{Expression={$_.Values[0]}},Key)
 $orders=@($groups.Values|ForEach-Object {$_.Current}|Sort-Object @{Expression={$_.Values[0]}},Key)
 return [pscustomobject]@{State=$state;Entries=$fills;Orders=$orders;Groups=$groups;Keys=$keys;Revision=$book.Revision}
}
function Sheet-JournalFilter($rows,$journal){
 $base=New-Object 'Collections.Generic.List[object]';$seen=@{};$covered=@{};$used=0
 $header=At58S-Cell $rows 0 6
 if($header -and $header -cne 'AT 체결키'){throw 'SHEET_JOURNAL_COLUMN'}
 foreach($col in @(7,8)){$h=[string](At58S-Cell $rows 0 $col);$want=if($col -eq 7){'주문번호'}else{'AT 체결금액'};if($h -and $h -cne $want){throw 'SHEET_JOURNAL_COLUMN'}}
 for($i=0;$i -lt $rows.Count;$i++){
  $row=$rows[$i];$key=[string](At58S-Cell $rows $i 6)
  if(@($row|Where-Object {$null -ne $_ -and [string]$_ -ne ''}).Count){$used=$i+1}
  if($i -eq 0 -or !$key){
   if($i -gt 0 -and (([string](At58S-Cell $rows $i 7)) -ne '' -or ([string](At58S-Cell $rows $i 8)) -ne '')){throw 'SHEET_JOURNAL_COLUMN'}
   $copy=@();for($j=0;$j -lt [math]::Min(6,$row.Count);$j++){$copy+=,$row[$j]};$base.Add([object[]]$copy);continue
  }
  if(!$journal -or !$journal.Keys.ContainsKey($key)){throw 'SHEET_JOURNAL_UNKNOWN'}
  if($seen.ContainsKey($key)){throw 'SHEET_JOURNAL_DUPLICATE'}
  $entry=$journal.Keys[$key];$want=$entry.Values
  if($row.Count -lt 7 -or [string]$row[2] -cne [string]$want[2]){throw 'SHEET_JOURNAL_CHANGED'}
  foreach($j in @(0,1,3,4)){if([math]::Abs((Sheet-Number $row[$j])-[decimal]$want[$j]) -gt .00000001){throw 'SHEET_JOURNAL_CHANGED'}}
  if([string]$row[5] -ne '' -and [math]::Abs((Sheet-Number $row[5])-[decimal]$want[5]) -gt .01){throw 'SHEET_JOURNAL_CHANGED'}
  if($entry.Kind -ceq 'ORDER'){
   if([string](At58S-Cell $rows $i 7) -cne $entry.BrokerId -or [string](At58S-Cell $rows $i 8) -eq '' -or (Sheet-Number (At58S-Cell $rows $i 8)) -ne [decimal]$want[5]){throw 'SHEET_JOURNAL_CHANGED'}
   $members=@($journal.Groups[$entry.GroupId].FillKeys|Select-Object -First $entry.Count)
  }else{
   if([string](At58S-Cell $rows $i 7) -ne '' -or [string](At58S-Cell $rows $i 8) -ne ''){throw 'SHEET_JOURNAL_CHANGED'}
   $members=@($key)
  }
  foreach($member in $members){if($covered.ContainsKey($member)){throw 'SHEET_JOURNAL_DUPLICATE'};$covered[$member]=$true}
  $seen[$key]=$i
 }
 return [pscustomobject]@{Rows=$base.ToArray();Seen=$seen;Covered=$covered;Used=$used}
}
function Sheet-JournalLayout($meta){
 $found=@($meta.sheets|Where-Object {$_.properties.title -ceq '매매일지' -and $_.properties.sheetId -eq 1136811970})
 if($found.Count -ne 1){throw 'SHEET_JOURNAL_STRUCTURE'}
 $grid=Ops-Get $found[0].properties 'gridProperties';$rows=[int](Ops-Get $grid 'rowCount' 1000);$cols=[int](Ops-Get $grid 'columnCount' 6)
 if($rows -lt 2 -or $rows -gt 60000 -or $cols -lt 6 -or $cols -gt 9){throw 'SHEET_JOURNAL_STRUCTURE'}
 $last=if($cols -ge 9){'I'}elseif($cols -eq 8){'H'}elseif($cols -eq 7){'G'}else{'F'}
 return [pscustomobject]@{Rows=$rows;Cols=$cols;Range=("'매매일지'!A1:"+$last+$rows)}
}
function Sheet-JournalRead($headers,[string]$base,$layout){
 $uri=$base+'/values/'+[uri]::EscapeDataString($layout.Range)+'?valueRenderOption=UNFORMATTED_VALUE&dateTimeRenderOption=SERIAL_NUMBER'
 $r=Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -TimeoutSec 10 -MaximumRedirection 0 -ErrorAction Stop
 return ,@($r.values)
}
function Sheet-JournalFormula([bool]$grouped=$true){
 if($grouped){return '=ARRAYFORMULA(IF(C2:C="","",IF(I2:I<>"",I2:I,IF((D2:D<>"")*(E2:E<>""),D2:D*E2:E,""))))'}
 return '=ARRAYFORMULA(IF(C2:C="","",IF((D2:D<>"")*(E2:E<>""),D2:D*E2:E,"")))'
}
function Sheet-JournalOrderRow($entry){return ,([object[]]@($entry.Values[0],$entry.Values[1],$entry.Values[2],$entry.Values[3],$entry.Values[4],$entry.Values[5],$entry.Key,$entry.BrokerId,$entry.Values[5]))}
function Sheet-JournalPlan($journal,$rows,$layout){
 $view=Sheet-JournalFilter $rows $journal;$requests=New-Object 'Collections.Generic.List[object]'
 $out=New-Object 'Collections.Generic.List[object]';$removed=New-Object 'Collections.Generic.List[int]';$updates=New-Object 'Collections.Generic.List[object]';$placed=@{}
 $schema=($layout.Cols -ge 9 -and (At58S-Cell $rows 0 7) -ceq '주문번호' -and (At58S-Cell $rows 0 8) -ceq 'AT 체결금액')
 for($i=0;$i -lt $view.Used;$i++){
  $key=[string](At58S-Cell $rows $i 6)
  if($i -eq 0 -or !$key){$out.Add([object[]]$rows[$i]);continue}
  $entry=$journal.Keys[$key];$g=$journal.Groups[$entry.GroupId]
  if($placed.ContainsKey($g.Id)){$removed.Add($i);continue}
  $target=$out.Count;$placed[$g.Id]=$true;$out.Add((Sheet-JournalOrderRow $g.Current))
  if($key -cne $g.Current.Key -or !$schema){$updates.Add([pscustomobject]@{Index=$target;Entry=$g.Current;New=$false})}
 }
 $missing=@($journal.Orders|Where-Object {!$placed.ContainsKey($_.GroupId)})
 foreach($entry in $missing){$updates.Add([pscustomobject]@{Index=$out.Count;Entry=$entry;New=$true});$out.Add((Sheet-JournalOrderRow $entry))}
 if($out.Count -gt 60000 -or !$out.Count){throw 'SHEET_JOURNAL_LIMIT'}
 if(!$schema -and !$journal.Orders.Count){return [pscustomobject]@{Requests=@();Missing=@();Seen=$view.Seen;Count=0;FirstRow=0;LastRow=$view.Used;Rows=$rows;Deleted=0;Updated=0;SchemaChange=$false}}
 if($layout.Cols -lt 9){$requests.Add(@{appendDimension=@{sheetId=1136811970;dimension='COLUMNS';length=(9-$layout.Cols)}})}
 # Delete only verified automatic duplicate rows, descending so indices stay valid.
 foreach($i in @($removed.ToArray()|Sort-Object -Descending)){$requests.Add(@{deleteDimension=@{range=@{sheetId=1136811970;dimension='ROWS';startIndex=$i;endIndex=($i+1)}}})}
 $gridRows=$layout.Rows-$removed.Count
 if($out.Count -gt $gridRows){$requests.Add(@{appendDimension=@{sheetId=1136811970;dimension='ROWS';length=($out.Count-$gridRows)}})}
 if(!$schema){
  $requests.Add(@{updateCells=@{start=@{sheetId=1136811970;rowIndex=0;columnIndex=6};rows=@(@{values=@(@{userEnteredValue=@{stringValue='AT 체결키'}},@{userEnteredValue=@{stringValue='주문번호'}},@{userEnteredValue=@{stringValue='AT 체결금액'}})});fields='userEnteredValue'}})
  $requests.Add(@{updateCells=@{start=@{sheetId=1136811970;rowIndex=1;columnIndex=5};rows=@(@{values=@(@{userEnteredValue=@{formulaValue=(Sheet-JournalFormula)}})});fields='userEnteredValue'}})
  foreach($col in @(6,8)){$requests.Add(@{updateDimensionProperties=@{range=@{sheetId=1136811970;dimension='COLUMNS';startIndex=$col;endIndex=($col+1)};properties=@{hiddenByUser=$true};fields='hiddenByUser'}})}
  $requests.Add(@{updateDimensionProperties=@{range=@{sheetId=1136811970;dimension='COLUMNS';startIndex=7;endIndex=8};properties=@{hiddenByUser=$false;pixelSize=105};fields='hiddenByUser,pixelSize'}})
  $requests.Add(@{repeatCell=@{range=@{sheetId=1136811970;startRowIndex=0;endRowIndex=1;startColumnIndex=7;endColumnIndex=8};cell=@{userEnteredFormat=@{textFormat=@{bold=$true};wrapStrategy='WRAP'}};fields='userEnteredFormat.textFormat.bold,userEnteredFormat.wrapStrategy'}})
  $requests.Add(@{updateCells=@{start=@{sheetId=1136811970;rowIndex=0;columnIndex=3};rows=@(@{values=@(@{note='같은 날짜·주문번호의 체결금액 합계 ÷ 체결수량 합계. 분할 체결은 수량가중 평균단가이며, 체결금액은 원본 합계를 사용합니다.'})});fields='note'}})
 }
 foreach($change in $updates){
  $i=$change.Index;$entry=$change.Entry
  if($change.New){$requests.Add(@{copyPaste=@{source=@{sheetId=1136811970;startRowIndex=1;endRowIndex=2;startColumnIndex=0;endColumnIndex=6};destination=@{sheetId=1136811970;startRowIndex=$i;endRowIndex=($i+1);startColumnIndex=0;endColumnIndex=6};pasteType='PASTE_FORMAT';pasteOrientation='NORMAL'}})}
  $cells=New-Object 'Collections.Generic.List[object]'
  for($j=0;$j -lt 5;$j++){$cells.Add(@{userEnteredValue=$(if($j -eq 2){@{stringValue=[string]$entry.Values[$j]}}else{@{numberValue=[double]$entry.Values[$j]}})})}
  $requests.Add(@{updateCells=@{start=@{sheetId=1136811970;rowIndex=$i;columnIndex=0};rows=@(@{values=$cells.ToArray()});fields='userEnteredValue'}})
  $requests.Add(@{updateCells=@{start=@{sheetId=1136811970;rowIndex=$i;columnIndex=6};rows=@(@{values=@(@{userEnteredValue=@{stringValue=$entry.Key}},@{userEnteredValue=@{stringValue=$entry.BrokerId}},@{userEnteredValue=@{numberValue=[double]$entry.Values[5]}})});fields='userEnteredValue'}})
  $requests.Add(@{repeatCell=@{range=@{sheetId=1136811970;startRowIndex=$i;endRowIndex=($i+1);startColumnIndex=3;endColumnIndex=4};cell=@{userEnteredFormat=@{numberFormat=@{type='NUMBER';pattern='#,##0.####'}}};fields='userEnteredFormat.numberFormat'}})
 }
 if($requests.Count){foreach($r in (Sheet-JournalDateFormats $out.ToArray() 1 $out.Count)){$requests.Add($r)}}
 return [pscustomobject]@{Requests=$requests.ToArray();Missing=$missing;Seen=$view.Seen;Count=$journal.Orders.Count;FirstRow=2;LastRow=$out.Count;Rows=$out.ToArray();Deleted=$removed.Count;Updated=$updates.Count;SchemaChange=(!$schema)}
}
function Sheet-JournalDetailedRows($rows,$journal){
 $view=Sheet-JournalFilter $rows $journal;$all=New-Object 'Collections.Generic.List[object]'
 for($i=1;$i -lt $view.Rows.Count;$i++){$r=$view.Rows[$i];if([string](At58S-Cell $view.Rows $i 0) -ne ''){$all.Add([pscustomobject]@{Date=(Sheet-Number $r[0]);Sequence=$i;Values=$r})}}
 $n=$view.Rows.Count;foreach($entry in $journal.Entries){$all.Add([pscustomobject]@{Date=[decimal]$entry.Values[0];Sequence=$n;Values=$entry.Values});$n++}
 $result=New-Object 'Collections.Generic.List[object]';$result.Add([object[]]$view.Rows[0]);foreach($v in @($all.ToArray()|Sort-Object Date,Sequence)){$result.Add([object[]]$v.Values)}
 return ,$result.ToArray()
}
function Sheet-JournalSync($headers,[string]$base,$meta,$journalInput,$journal,[string]$outputRoot){
 $mutex=[Threading.Mutex]::new($false,('Local\AT58Journal_'+(Ops-Key ($script:At58SheetId+'|'+$outputRoot))));$held=$false
 try{
  try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true};if(!$held){throw 'SHEET_JOURNAL_BUSY'}
  if($journalInput.Source.Hash -cne $journal.State.SourceHash){throw 'SHEET_JOURNAL_SOURCE_CHANGED'}
  $layout=Sheet-JournalLayout $meta;$plan=Sheet-JournalPlan $journal $journalInput.Ledger $layout;$lastRows=$journalInput.Ledger
  if($plan.Requests.Count){
   # A presentation schema must not change while an update is still being verified.
   $hostState=Ops-ReadJson (Join-Path $outputRoot 'bundle-status.json')
   if(!$hostState -or $hostState.Version -cne '58.17.12' -or $hostState.State -cnotin @('CURRENT','DISABLED','REJECTED','LIVE_HOLD','UPDATE_WAITING')){throw 'SHEET_JOURNAL_UPDATE_WAIT'}
   $rows=Sheet-JournalRead $headers $base $layout;$lastRows=$rows
   $raw=At58S-Clone $journalInput.Raw;$raw.Ledger=(Sheet-JournalFilter $rows $journal).Rows
   if((At58S-Import $raw).Hash -cne $journal.State.SourceHash){throw 'SHEET_JOURNAL_SOURCE_CHANGED'}
   $plan=Sheet-JournalPlan $journal $rows $layout
   if($plan.Requests.Count){
    $formula=Invoke-RestMethod -Method Get -Uri ($base+'/values/'+[uri]::EscapeDataString("'매매일지'!F2")+'?valueRenderOption=FORMULA') -Headers $headers -TimeoutSec 10 -MaximumRedirection 0 -ErrorAction Stop
    $wantFormula=Sheet-JournalFormula (!$plan.SchemaChange)
    if((At58S-Cell $formula.values 0 0) -cne $wantFormula){throw 'SHEET_JOURNAL_FORMULA'}
    # Keep the original first migration and the most recent pre-write snapshot encrypted.
    $backup=@{Schema='AT-JOURNAL-BACKUP-1';SheetId=$script:At58SheetId;Scope=$journal.State.Scope;SourceHash=$journal.State.SourceHash;Utc=(Ops-Now).ToString('o');Revision=$journal.Revision;Rows=$rows;Formula=$wantFormula}
    $first=Join-Path $outputRoot 'journal-before-grouping.dpapi'
    if($plan.SchemaChange -and !(Test-Path -LiteralPath $first)){Asset-ProtectedWrite $first 'AT58-JOURNAL-BACKUP-1' $backup}
    Asset-ProtectedWrite (Join-Path $outputRoot 'journal-before-write.dpapi') 'AT58-JOURNAL-BACKUP-1' $backup
    $reply=Invoke-RestMethod -Method Post -Uri ($base+':batchUpdate') -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes((@{requests=$plan.Requests}|ConvertTo-Json -Depth 18 -Compress))) -TimeoutSec 10 -MaximumRedirection 0 -ErrorAction Stop
    if($reply.spreadsheetId -cne $script:At58SheetId){throw 'SHEET_JOURNAL_RESPONSE'}
    $layout.Cols=[math]::Max(9,$layout.Cols);$layout.Rows=[math]::Max($layout.Rows-$plan.Deleted,$plan.LastRow);$layout.Range="'매매일지'!A1:I"+$layout.Rows
    $lastRows=Sheet-JournalRead $headers $base $layout
   }
  }
  $verified=Sheet-JournalFilter $lastRows $journal
  foreach($entry in $journal.Orders){
   if(!$verified.Seen.ContainsKey($entry.Key)){throw 'SHEET_JOURNAL_VERIFY'}
   $amount=At58S-Cell $lastRows $verified.Seen[$entry.Key] 5
   if([string]$amount -eq '' -or [math]::Abs((Sheet-Number $amount)-[decimal]$entry.Values[5]) -gt .01){throw 'SHEET_JOURNAL_RECALC'}
  }
  $raw=At58S-Clone $journalInput.Raw;$raw.Ledger=$verified.Rows
  if((At58S-Import $raw).Hash -cne $journal.State.SourceHash){throw 'SHEET_JOURNAL_SOURCE_CHANGED'}
  $journalInput.Ledger=Sheet-JournalDetailedRows $lastRows $journal
  $result=@{Code='OK';Utc=(Ops-Now).ToString('o');Total=$journal.Orders.Count;Written=$journal.Orders.Count;Pending=0;Added=$plan.Missing.Count;Updated=$plan.Updated;GroupedRowsRemoved=$plan.Deleted;FillCount=$journal.Entries.Count}
  Ops-WriteJson (Join-Path $outputRoot 'journal-status.json') $result
  return [pscustomobject]$result
 }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}

# Display helpers only. No order submission, cancellation, or strategy mutation.
function Sheet-JournalDate($value){
 $n=0D
 if([decimal]::TryParse([string]$value,[Globalization.NumberStyles]::Number,[Globalization.CultureInfo]::InvariantCulture,[ref]$n)){
  if($n -lt 1 -or $n -gt 2958465){throw 'SHEET_JOURNAL_DATE'}
  return ([datetime]::FromOADate([double]$n)).Date
 }
 $d=[datetime]::MinValue
 if([datetime]::TryParseExact([string]$value,[string[]]@('yyyy-MM-dd','yyyyMMdd'),[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$d)){return $d.Date}
 throw 'SHEET_JOURNAL_DATE'
}
function Sheet-JournalDatePattern($date,$previous){
 if($null -eq $previous -or $date.Year -ne $previous.Year){return 'yyyy"년" m"월" d"일"'}
 if($date.Month -ne $previous.Month){return 'm"월" d"일"'}
 return 'd"일"'
}
function Sheet-JournalDateFormats($rows,[int]$first,[int]$last){
 $requests=New-Object 'Collections.Generic.List[object]';$previous=$null
 for($i=1;$i -lt $last;$i++){
  $v=At58S-Cell $rows $i 0;if([string]$v -eq ''){continue}
  $date=Sheet-JournalDate $v;$pattern=Sheet-JournalDatePattern $date $previous;$previous=$date
  if($i -lt $first){continue}
  $requests.Add(@{repeatCell=@{range=@{sheetId=1136811970;startRowIndex=$i;endRowIndex=($i+1);startColumnIndex=0;endColumnIndex=1};cell=@{userEnteredFormat=@{numberFormat=@{type='DATE';pattern=$pattern}}};fields='userEnteredFormat.numberFormat'}})
 }
 return ,$requests.ToArray()
}
function Sheet-LiveAttempt($live,[string]$side,[bool]$current){
 if(!$current){return ($side+' · 조회 갱신 대기')}
 $state=[string](Ops-Get $live 'State' '');$plan=Ops-Get $live 'Plan'
 $pending=@(Ops-Get $live 'Orders' @()|Where-Object {$null -ne $_ -and $_.Action -cne 'CANCEL' -and $_.Intent.Side -ceq $side -and $_.State -cin @('SUBMITTING','UNKNOWN','WARNING_REVIEW','ACKNOWLEDGED','OPEN','PARTIAL','REVIEW')})
 if($pending.Count){
  $o=$pending[-1];$stage=$o.Intent.Stage;$price=$o.Intent.Price;$qty=$o.Intent.Qty
  $label=if($o.State -cin @('UNKNOWN','WARNING_REVIEW','REVIEW')){'확인 필요'}elseif($state -ceq 'STOPPING'){'취소 확인 중'}elseif($o.State -ceq 'SUBMITTING'){'전송 확인 중'}else{'주문 진행'}
  $detail=' · 잔량 '+([decimal]$o.Remaining).ToString('N0')+'주'+$(if($pending.Count -gt 1){' 외 '+($pending.Count-1)+'건'}else{''})
 }else{
  if($state -cne 'ARMED'){return ($side+' · '+$(if($state -ceq 'REVIEW'){'중지 · 주문 확인 필요'}else{'실주문 중지'}))}
  $candidate=@(Ops-Get $plan 'Candidate' @()|Where-Object {$null -ne $_ -and $_.Side -ceq $side})
  if($candidate.Count){$n=$candidate[0];$stage=$n.Stage;$price=$n.Price;$qty=$n.Qty;$label='주문 판단 중'}
  else{
   $n=Ops-Get $plan $(if($side -ceq '매수'){'NextBuy'}else{'NextSell'})
   if(!$n){return ($side+' · 대상 없음')}
   $stage=$n.Stage;$price=Ops-Get $n $(if($side -ceq '매수'){'BuyPrice'}else{'SellPrice'});$qty=Ops-Get $n $(if($side -ceq '매수'){'BuyQty'}else{'SellQty'})
   $blocked=($qty -le 0 -or ($side -ceq '매수' -and (Ops-Get $plan 'BuyStopped' $false)) -or ($side -ceq '매도' -and !(Ops-Get $plan 'NeutralSellAllowed' $true)))
   $label=if($blocked){'조건 제한'}else{'조건 대기'}
  }
  $detail=''
 }
 return ($side+' '+$label+' · '+$stage+'차 | '+([decimal]$price).ToString('N0')+'원 × '+([decimal]$qty).ToString('N0')+'주'+$detail)
}

# Asset reporting only. This module never invokes the live engine or sends broker orders.
function Asset-Number($o,[string]$key){
 $v=At58-Value $o $key;if($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v)){return $null}
 return (Sheet-Number $v)
}
function Asset-SumFields($o,$keys){$n=0D;foreach($k in $keys){$v=Asset-Number $o $k;if($null -eq $v){return $null};$n+=$v};return $n}
function Asset-Ledger($rows){
 $out=New-Object 'Collections.Generic.List[object]';$qty=0D;$avg=0D;$gross=0D;$last=0D
 for($i=1;$i -lt $rows.Count;$i++){
  $r=$rows[$i];if(@($r).Count -lt 5 -or $null -eq $r[0] -or [string]::IsNullOrWhiteSpace([string]$r[0])){continue}
  $date=Sheet-Number $r[0];$stage=Sheet-Number $r[1];$side=[string]$r[2];$price=Sheet-Number $r[3];$q=Sheet-Number $r[4]
  if($date -lt 40000 -or $date -lt $last -or $stage -lt 1 -or $stage -gt 30 -or $side -cnotin @('매수','매도') -or $q -le 0 -or $q -ne [math]::Truncate($q) -or $price -le 0){throw 'ASSET_LEDGER_INVALID'}
  $last=$date;$amount=$price*$q;$pnl=$null
  if($side -ceq '매수'){$avg=($qty*$avg+$amount)/($qty+$q);$qty+=$q}else{if($q -gt $qty){throw 'ASSET_LEDGER_SHORT'};$pnl=$amount-$avg*$q;$gross+=$pnl;$qty-=$q;if(!$qty){$avg=0D}}
  $out.Add([pscustomobject]@{Date=$date;Day=[datetime]::FromOADate([double]$date).ToString('yyyyMMdd');Stage=$stage;Side=$side;Price=$price;Qty=$q;Amount=$amount;Gross=$pnl;GrossTotal=$gross})
 }
 if(!$out.Count -or $out.Count -gt 58000){throw 'ASSET_LEDGER_LIMIT'}
 return [pscustomobject]@{Rows=$out.ToArray();Qty=$qty;Average=$avg;Gross=$gross;From=$out[0].Day;To=$out[-1].Day}
}
function Asset-CostRow($r,[string]$from,[string]$to){
 $day=[string](At58-Value $r 'deal_date');$null=At58-Day $day;if($day -lt $from -or $day -gt $to){throw 'ASSET_COST_DATE'}
 $v=[ordered]@{Day=$day};foreach($map in @(@('Buy','byov_amt'),@('Sell','seln_amt'),@('BuyFee','byov_deal_fee'),@('SellFee','seln_deal_fee'),@('Tax','wtax_amt'),@('Fee','deal_fee'))){$n=Asset-Number $r $map[1];if($null -eq $n -or $n -lt 0){throw 'ASSET_COST_SCHEMA'};$v[$map[0]]=$n}
 if($v.BuyFee+$v.SellFee -ne $v.Fee){throw 'ASSET_COST_TOTAL'}
 return [pscustomobject]$v
}
function Asset-Transaction($r,[string]$from,[string]$to){
 $day=[string](At58-Value $r 'tr_date');$null=At58-Day $day;if($day -lt $from -or $day -gt $to){throw 'ASSET_TRANSACTION_DATE'}
 $cancel=[string](At58-Value $r 'cncl_yn');if($cancel -cnotin @('Y','N')){throw 'ASSET_TRANSACTION_CANCEL'};if($cancel -ceq 'Y'){return $null}
 $id=[string](At58-Value $r 'tran_srno');if($id -cnotmatch '^\d{1,20}$'){throw 'ASSET_TRANSACTION_ID'}
 $name=At58-Text (At58-Value $r 'smcd_name');$symbol=[string](At58-Value $r 'iscd');$amount=Asset-Number $r 'tr_amt';$fx=Asset-Number $r 'frcr_tr_amt'
 $income=Asset-SumFields $r @('intx','rstx');$tax=Asset-SumFields $r @('trtx','srtx');$fee=Asset-SumFields $r @('deal_fee','fee')
 $kind='확인 필요'
 # Never infer undocumented direction codes. Classify explicit descriptions only.
 if($null -ne $fx -and $fx -ne 0){$kind='외화 · 별도 확인'}
 elseif($name -match '취소|정정|반환|환불|환급'){$kind='확인 필요'}
 elseif($name -match '배당|분배금'){$kind='배당·분배금'}
 elseif($name -match '예탁금이용료|예수금이용료|이자지급|이자입금|RP이자'){$kind='이자·이용료'}
 elseif($name -match '매수|매도'){$kind='매매·상품정산'}
 elseif(!$symbol -and $name -match '입금|입고' -and $name -notmatch '출금|출고'){$kind='입금'}
 elseif(!$symbol -and $name -match '출금|출고' -and $name -notmatch '입금|입고'){$kind='출금'}
 if($null -eq $amount -or $amount -lt 0 -or $null -eq $fx -or $null -eq $income -or $null -eq $tax -or $null -eq $fee){$kind='확인 필요'}
 return [pscustomobject]@{Key=($day+'|'+$id);Day=$day;Kind=$kind;Name=$name;Symbol=$symbol;Amount=$amount;IncomeTax=$income;TradeTax=$tax;Fee=$fee;Foreign=$fx}
}
function Asset-EstimateFee([decimal]$amount,[string]$day,[string]$profile){
 $null=At58-Day $day;if($amount -lt 0){throw 'ASSET_FEE_AMOUNT'}
 switch -CaseSensitive ($profile){
  'SUPER365_FREE' {if($day -lt '20260101' -or $day -gt '20261231'){return [math]::Floor($amount*0.00009D)};return 0D}
  'LIFETIME_ETF' {return [math]::Floor($amount*0.000042087D)}
  default {return [math]::Floor($amount*0.00009D)}
 }
}
function Asset-CostReport($ledger,$costRows,[string]$profile='SUPER365_FREE'){
 $daily=@{};foreach($r in $ledger.Rows){if(!$daily.ContainsKey($r.Day)){$daily[$r.Day]=@{Buy=0D;Sell=0D;BuyFee=0D;SellFee=0D;Tax=0D;Confirmed=$false;Label='추정 · Super365 기본 0.009% 가정'}};$k=if($r.Side -ceq '매수'){'Buy'}else{'Sell'};$daily[$r.Day][$k]+=$r.Amount}
 $seen=@{};foreach($c in $costRows){if($seen.ContainsKey($c.Day)){throw 'ASSET_COST_DUPLICATE'};$seen[$c.Day]=$true;if($daily.ContainsKey($c.Day)){$d=$daily[$c.Day];if($d.Buy -eq $c.Buy -and $d.Sell -eq $c.Sell){$d.BuyFee=$c.BuyFee;$d.SellFee=$c.SellFee;$d.Tax=$c.Tax;$d.Confirmed=$true;$d.Label='실제 일별 비용 · 금액 비례 배분'}}}
 $buyFee=0D;$sellFee=0D;$tax=0D;$actual=0D;$est=0D;$verified=0;$estimated=0
 foreach($day in $daily.Keys){$d=$daily[$day];if(!$d.Confirmed){$d.BuyFee=Asset-EstimateFee $d.Buy $day $profile;$d.SellFee=Asset-EstimateFee $d.Sell $day $profile;$d.Tax=0D;if($profile -ceq 'SUPER365_FREE'){$d.Label=if($day -ge '20260101' -and $day -le '20261231'){'공식 혜택 산정 · Super365 0% (월 한도 미초과 전제)'}else{'공시 기본요율 추정 · 0.009% (혜택 기간 외 재확인)'}}elseif($profile -ceq 'LIFETIME_ETF'){$d.Label='추정 · 평생우대 ETF 요율 가정'};$estimated++;$est+=$d.BuyFee+$d.SellFee+$d.Tax}else{$verified++;$actual+=$d.BuyFee+$d.SellFee+$d.Tax};$buyFee+=$d.BuyFee;$sellFee+=$d.SellFee;$tax+=$d.Tax}
 $progress=@{};$rows=New-Object 'Collections.Generic.List[object]';$cumCost=0D
 foreach($r in $ledger.Rows){$d=$daily[$r.Day];$side=if($r.Side -ceq '매수'){'Buy'}else{'Sell'};$key=$r.Day+'|'+$side;if(!$progress.ContainsKey($key)){$progress[$key]=0D};$prev=$progress[$key];$next=$prev+$r.Amount;$fee=$d[$side+'Fee'];$allocated=[math]::Floor($fee*$next/$d[$side])-[math]::Floor($fee*$prev/$d[$side]);$tx=0D;if($side -ceq 'Sell'){$tx=[math]::Floor($d.Tax*$next/$d.Sell)-[math]::Floor($d.Tax*$prev/$d.Sell)};$progress[$key]=$next;$cumCost+=$allocated+$tx
  $rows.Add([object[]]@($r.Date,$r.Stage,$r.Side,$r.Price,$r.Qty,$r.Amount,$allocated,$tx,$(if($null -eq $r.Gross){''}else{$r.Gross}),($r.GrossTotal-$cumCost),$d.Label))
 }
 return [pscustomobject]@{Rows=$rows.ToArray();BuyFee=$buyFee;SellFee=$sellFee;Tax=$tax;Actual=$actual;Estimated=$est;Total=($buyFee+$sellFee+$tax);VerifiedDays=$verified;EstimatedDays=$estimated;Net=($ledger.Gross-$cumCost)}
}
function Asset-Collect($ctx,$state,[string]$from,[string]$to){
 $now=At58-Now $ctx
 if(!$state -or $state.Schema -cne 'AT-ASSETS-1' -or $state.Scope -cne $ctx.Scope -or $state.From -cne $from -or $state.To -cne $to){$state=[pscustomobject]@{Schema='AT-ASSETS-1';Scope=$ctx.Scope;From=$from;To=$to;Phase='COST';Cursor='';Keys=@();CostRows=@();Transactions=@();StartedUtc=$now.ToString('o');CompletedUtc=''}}
 if($state.Phase -ceq 'COMPLETE'){
  if(($now-(Ops-Utc $state.CompletedUtc)).TotalSeconds -lt 300){return $state}
  $state.Phase='COST';$state.Cursor='';$state.Keys=@();$state.CostRows=@();$state.Transactions=@();$state.StartedUtc=$now.ToString('o');$state.CompletedUtc=''
 }
 for($i=0;$i -lt 2;$i++){
  if($state.Phase -ceq 'COST'){$path='/accounts/v1/me/profit-loss';$query=@{iqry_sta_date=$from;iqry_fin_date=$to;crdt_expn_incu_yn='N'}}elseif($state.Phase -ceq 'TRANSACTIONS'){$path='/accounts/v1/me/transactions';$query=@{from=$from;to=$to;sort='ASC'}}else{throw 'ASSET_PHASE'}
  if($state.Cursor){$query.tr_cont='1';$query.tr_cont_key=$state.Cursor}
  $reply=At58-Get $ctx $path $query;$data=At58-Value $reply 'data';if($data -isnot [array]){throw 'ASSET_PAGE_SCHEMA'}
  foreach($r in $data){if($state.Phase -ceq 'COST'){$item=Asset-CostRow $r $from $to;if(@($state.CostRows|Where-Object Day -ceq $item.Day).Count){throw 'ASSET_COST_DUPLICATE'};$state.CostRows+=@($item)}else{$item=Asset-Transaction $r $from $to;if($item){$old=@($state.Transactions|Where-Object Key -ceq $item.Key);if($old.Count){if(($old[0]|ConvertTo-Json -Compress) -cne ($item|ConvertTo-Json -Compress)){throw 'ASSET_TRANSACTION_CONFLICT'}}else{$state.Transactions+=@($item)}}}}
  if($state.Transactions.Count -gt 10000 -or $state.CostRows.Count -gt 4000){throw 'ASSET_HISTORY_LIMIT'}
  $cont=[string](At58-Value $reply 'tr_cont');if($cont -cnotin @('','0','1')){throw 'ASSET_PAGE_SCHEMA'}
  if($cont -ceq '1' -or [string]$reply.rsp_cd -ceq '5762'){$key=[string](At58-Value $reply 'tr_cont_key');if([string]::IsNullOrWhiteSpace($key) -or $key -cin $state.Keys -or $state.Keys.Count -ge 1000){throw 'ASSET_PAGE_INCOMPLETE'};$state.Keys+=@($key);$state.Cursor=$key}else{if($state.Phase -ceq 'COST'){$state.Phase='TRANSACTIONS';$state.Cursor='';$state.Keys=@()}else{$state.Phase='COMPLETE';$state.CompletedUtc=(At58-Now $ctx).ToString('o');break}}
 }
 return $state
}
function Asset-ProtectedRead([string]$path,[string]$purpose){try{return ((Sheet-Unprotect ([IO.File]::ReadAllText($path)) $purpose)|ConvertFrom-Json)}catch{return $null}}
function Asset-ProtectedWrite([string]$path,[string]$purpose,$value){At58-Atomic $path (At58-Protect ($value|ConvertTo-Json -Depth 15 -Compress) $purpose)}
function Asset-Cell($v){if($v -is [ValueType] -and $v -isnot [bool]){return @{userEnteredValue=@{numberValue=[double]$v}}};return @{userEnteredValue=@{stringValue=[string]$v}}}
function Asset-Payload($snapshot,$ledger,$report,$history,[int]$previousEnd=55){
 $id=1830155726;$req=New-Object 'Collections.Generic.List[object]'
 function AssetPut([int]$row,[int]$col,$v){$req.Add(@{updateCells=@{start=@{sheetId=$id;rowIndex=$row-1;columnIndex=$col-1};rows=@(@{values=@((Asset-Cell $v))});fields='userEnteredValue'}})}
 $complete=$history -and $history.Phase -ceq 'COMPLETE';$costStamp=if($complete){'기록 조회 '+(At58-Kst (Ops-Utc $history.CompletedUtc)).ToString('MM/dd HH:mm:ss')}else{'기록 수집 중 · 비용은 추정/확인분 구분'}
 AssetPut 9 6 '비용 반영 누적손익 · Super365'
 AssetPut 12 1 ('Super365 확인 · 2026년 국내 ETF/API 수수료 0% · 월 200억원 한도 미초과 전제 / '+$costStamp)
 AssetPut 18 4 (Sheet-OptionalNumber $snapshot.Cash 'Withdrawable');AssetPut 19 4 (Sheet-OptionalNumber $snapshot.Cash 'D1')
 AssetPut 24 5 $ledger.Gross;$todayGross=0D;foreach($row in $ledger.Rows){if($row.Day -ceq $snapshot.Day -and $null -ne $row.Gross){$todayGross+=[decimal]$row.Gross}};AssetPut 25 5 $todayGross
 AssetPut 26 5 $report.BuyFee;AssetPut 27 5 $report.SellFee;AssetPut 28 5 $report.Tax;AssetPut 29 5 $report.Actual;AssetPut 30 5 $report.Net
 AssetPut 26 7 '실제 조회 우선. 2026년 Super365 무료 혜택 산정(월 한도 미초과 전제), 이후 공시 기본 0.009% 추정'
 AssetPut 27 7 '실제/추정 비용을 같은 날 매도 체결금액 비례로 배분. 건별 증권사 확정액은 아님'
 AssetPut 28 7 '0210A0 국내 주식형 ETF: 거래세·농특세·매매차익세 0%. 실제 조회 비용 우선'
 AssetPut 29 7 '매매일지의 일별 매수·매도금액과 모두 일치하는 계좌 일별 비용만 확인분에 포함'
 AssetPut 30 7 ('비용 전 누적손익 − 산정 비용 '+$report.Total.ToString('N0')+'원 (추정 '+$report.Estimated.ToString('N0')+'원 포함)')
 AssetPut 31 5 ('실제 조회 '+$report.VerifiedDays+'일 / 요율 산정 '+$report.EstimatedDays+'일')
 AssetPut 31 7 'Super365 계좌 사용자 확인. 과거 실청구액·고객 전체 월 약정액은 별도 대조; 확인 비용 우선'
 AssetPut 32 5 '실제 일별 비용 배분 / 추정 구분';AssetPut 32 7 '매매별 비용 근거는 K열. 매수 비용을 포함한 누적손익은 J열'
 $in=0D;$out=0D;$div=0D;$divTax=0D;$interest=0D;$interestTax=0D;$unknown=0;$tx=New-Object 'Collections.Generic.List[object]'
 if($complete){foreach($r in $history.Transactions){switch -CaseSensitive($r.Kind){'입금' {$in+=$r.Amount};'출금' {$out+=$r.Amount};'배당·분배금' {$div+=$r.Amount;$divTax+=$r.IncomeTax};'이자·이용료' {$interest+=$r.Amount;$interestTax+=$r.IncomeTax};'확인 필요' {$unknown++};'외화 · 별도 확인' {$unknown++}}
  if($r.Kind -cne '매매·상품정산'){$tx.Add([object[]]@([datetime]::ParseExact($r.Day,'yyyyMMdd',[Globalization.CultureInfo]::InvariantCulture).ToOADate(),$r.Kind,$r.Name,$r.Symbol,$r.Amount,$r.IncomeTax,$r.Fee,$r.TradeTax,$r.Foreign,'',''))}
 }}
 AssetPut 35 5 $(if($complete){'순입금 '+($in-$out).ToString('N0')+'원'}else{'조회 중'})
 AssetPut 35 7 $(if($complete){'입금 '+$in.ToString('N0')+'원 / 출금 '+$out.ToString('N0')+'원 · '+$ledger.From+'부터'}else{'연속조회 완료 후 합산 · 매매·RP 정산은 입출금에서 제외'})
 AssetPut 36 5 $(if($complete){$div}else{'조회 중'});AssetPut 36 7 $(if($complete){'원화 배당·분배 거래금액 / 원천징수 '+$divTax.ToString('N0')+'원 · 세액을 중복 차감하지 않음'}else{'실제 지급·원천징수 내역 조회. 미지급 분배금은 예상 소득으로 더하지 않음'})
 AssetPut 37 1 'RP이자·예탁금이용료';AssetPut 37 5 $(if($complete){$interest}else{'조회 중'});AssetPut 37 7 $(if($complete){'원화 이자·이용료 거래금액 / 원천징수 '+$interestTax.ToString('N0')+'원'}else{'이자 지급 거래만 분류 · RP 원금·정산금은 이자 수익으로 합산하지 않음'})
 $loan=Sheet-OptionalNumber $snapshot.Valuation 'Loan';$credit=Sheet-OptionalNumber $snapshot.Cash 'CreditLoan';$due=Sheet-OptionalNumber $snapshot.Cash 'Receivable'
 AssetPut 38 5 ('대출 '+$loan+' / 미수 '+$due);AssetPut 38 7 ('신용대출 '+$credit+'원 · 대출 합계에 포함, 중복 합산하지 않음')
 AssetPut 43 5 $(if($ledger.Qty -eq $snapshot.TargetQty){'일치'}else{'확인 필요'})
 $portfolio=Ops-Get (Ops-Get $snapshot 'Live') 'Portfolio'
 AssetPut 44 5 $(if($portfolio -and [math]::Abs(($ledger.Gross-[decimal]$portfolio.ActualCosts)-[decimal]$portfolio.Realized) -lt 1){'일치'}elseif($portfolio){'확인 필요'}else{'조회 대기'})
 AssetPut 44 7 '기존 전략 원장과 신규 확인비용 기준 대조. 추가 조회한 과거 비용·추정비용은 표시에서 별도 반영'
 AssetPut 45 5 $ledger.Rows.Count
 AssetPut 48 4 'https://home.imeritz.com/mobile/content/feeinfo/tax.html'
 AssetPut 49 4 'https://openapi.imeritz.com/intro'
 AssetPut 50 4 'https://www.samsungfund.com/etf/insight/guide/view05.do'
 AssetPut 48 1 '메리츠 · 수수료·거래세';AssetPut 49 1 '메리츠 · API 수수료';AssetPut 50 1 '삼성자산운용 · ETF 과세'
 AssetPut 52 1 ('실제 비용 확인 '+$report.VerifiedDays+'일 / 추정 '+$report.EstimatedDays+'일 · 미분류·외화 '+$unknown+'건은 아래 별도 표시 · 자산 기록 '+$costStamp)
 AssetPut 54 1 '매매손익은 비용 전. J열은 매수 수수료도 발생 즉시 차감한 누적손익. 비용 근거는 K열 · 단위: 원·주'
 $table=New-Object 'Collections.Generic.List[object]';$table.Add([object[]]@('일자','차수','매매','체결단가','수량','체결금액','수수료','세금','매매별 손익(비용 전)','비용 반영 누적손익','비용 근거'))
 foreach($r in $report.Rows){$table.Add([object[]]$r)}
 $table.Add([object[]]@('','','','','','','','','','',''));$txHeader=55+$table.Count
 $table.Add([object[]]@('입출금·배당·이자 거래내역','','','','','','','','','',''))
 $table.Add([object[]]@('일자','분류','거래내용','종목','거래금액','소득·지방세','수수료','거래세','외화금액','조회 범위',''))
 if($complete){if($tx.Count){foreach($r in $tx){$table.Add([object[]]$r)}}else{$table.Add([object[]]@('','해당 기간 내역 없음','','','','','','','','',''))}}else{$table.Add([object[]]@('','연속조회 진행 중','','','','','','','','',''))}
 $end=54+$table.Count;if($end -gt 60055){throw 'ASSET_SHEET_LIMIT'}
 $dateRange='A56:A'+$end;$dateFormula='=IF(COUNT('+$dateRange+')=0,"기록 없음",TEXT(MIN('+$dateRange+'),"yyyy-mm-dd")&" ~ "&TEXT(MAX('+$dateRange+'),"yyyy-mm-dd"))'
 $req.Add(@{updateCells=@{start=@{sheetId=$id;rowIndex=41;columnIndex=4};rows=@(@{values=@(@{userEnteredValue=@{formulaValue=$dateFormula}})});fields='userEnteredValue'}})
 $req.Add(@{repeatCell=@{range=@{sheetId=$id;startRowIndex=54;endRowIndex=[math]::Max($previousEnd,$end);startColumnIndex=0;endColumnIndex=11};cell=@{};fields='userEnteredValue'}})
 $req.Add(@{repeatCell=@{range=@{sheetId=$id;startRowIndex=54;endRowIndex=[math]::Max($previousEnd,$end);startColumnIndex=0;endColumnIndex=11};cell=@{userEnteredFormat=@{backgroundColor=@{red=1;green=1;blue=1};textFormat=@{fontFamily='Arial';fontSize=10;bold=$false};wrapStrategy='WRAP';verticalAlignment='MIDDLE'}};fields='userEnteredFormat.backgroundColor,userEnteredFormat.textFormat,userEnteredFormat.wrapStrategy,userEnteredFormat.verticalAlignment'}})
 $cells=foreach($row in $table){@{values=@(foreach($v in $row){Asset-Cell $v})}}
 $req.Add(@{updateCells=@{start=@{sheetId=$id;rowIndex=54;columnIndex=0};rows=@($cells);fields='userEnteredValue'}})
 foreach($row in @(54,$txHeader,($txHeader-1))){$req.Add(@{repeatCell=@{range=@{sheetId=$id;startRowIndex=$row;endRowIndex=$row+1;startColumnIndex=0;endColumnIndex=11};cell=@{userEnteredFormat=@{backgroundColor=@{red=0.85;green=0.90;blue=0.95};textFormat=@{bold=$true;fontSize=10};wrapStrategy='WRAP'}};fields='userEnteredFormat.backgroundColor,userEnteredFormat.textFormat,userEnteredFormat.wrapStrategy'}})}
 $req.Add(@{autoResizeDimensions=@{dimensions=@{sheetId=$id;dimension='ROWS';startIndex=$txHeader-1;endIndex=$end}}})
 return [pscustomobject]@{Requests=$req.ToArray();End=$end;PreviousEnd=$previousEnd;TransactionHeader=$txHeader;TransactionCount=$tx.Count;Unknown=$unknown}
}
function Asset-PresentationStateValid($state,[string]$kind,[datetime]$now,$payload=$null){
 # Protected storage can still be truncated or contain an older incompatible shape.
 # Never let malformed state establish equality or a trusted previous extent.
 try{
  if($null -eq $state -or !($state -is [Collections.IDictionary] -or $state -is [pscustomobject])){return $false}
  $schema=if($kind -ceq 'Pending'){'AT-ASSET-PENDING-1'}else{'AT-ASSET-PRESENTATION-1'}
  if((Ops-Get $state 'Schema' '') -cne $schema -or [string](Ops-Get $state 'Target' '') -cnotmatch '^[a-f0-9]{64}$'){return $false}
  $end=Ops-Get $state 'End';if([string]$end -cnotmatch '^[0-9]{2,5}$' -or [int]$end -lt 56 -or [int]$end -gt 60055){return $false}
  $names=if($kind -ceq 'Pending'){@('StartedUtc')}else{@('FullValuesUtc','LastWriteUtc')};$times=@{}
  foreach($name in $names){
   $value=Ops-Get $state $name
   if($value -isnot [datetime] -and [string]$value -cnotmatch '^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,7})?(?:Z|[+-][0-9]{2}:[0-9]{2})$'){return $false}
   $utc=Ops-Utc $value;if($utc -gt $now.AddSeconds(2)){return $false};$times[$name]=$utc
  }
  if($kind -ceq 'Pending'){return $true}
  $header=Ops-Get $state 'TransactionHeader'
  if([string]$header -cnotmatch '^[0-9]{2,5}$' -or [int]$header -lt 56 -or [int]$header -ge [int]$end -or $times.LastWriteUtc -lt $times.FullValuesUtc){return $false}
  $hashes=Ops-Get $state 'Hashes';if($null -eq $hashes -or !($hashes -is [Collections.IDictionary] -or $hashes -is [pscustomobject])){return $false}
  $keys=@(if($hashes -is [Collections.IDictionary]){$hashes.Keys}else{$hashes.PSObject.Properties.Name})
  $expected=@(foreach($request in $payload.Requests){if($request.ContainsKey('updateCells')){[string]$request.updateCells.start.rowIndex+'|'+[string]$request.updateCells.start.columnIndex}})
  if(!$expected.Count -or $keys.Count -ne $expected.Count){return $false}
  foreach($key in $expected){if($keys -cnotcontains $key -or [string](Ops-Get $hashes $key '') -cnotmatch '^[a-f0-9]{64}$'){return $false}}
  return $true
 }catch{return $false}
}
function Asset-PublishPlan($payload,$published,[string]$target,[int]$gridRows,[datetime]$now,$pending=$null,$conditionalFormats=@(),[bool]$unreadableState=$false){
 $id=1830155726;if($gridRows -lt 56 -or $gridRows -gt 60055 -or $payload.End -lt 56 -or $payload.End -gt 60055){throw 'ASSET_SHEET_LIMIT'}
 $cacheShape=Asset-PresentationStateValid $published 'Published' $now $payload;$pendingShape=Asset-PresentationStateValid $pending 'Pending' $now
 $repair=$unreadableState -or ($null -ne $published -and (!$cacheShape -or $published.Target -cne $target)) -or ($null -ne $pending -and !$pendingShape)
 $valid=$cacheShape -and !$repair -and $published.Target -ceq $target
 $uncertain=$pendingShape -and $pending.Target -ceq $target
 $force=!$valid -or $uncertain -or $repair
 if($valid){$age=($now-(Ops-Utc $published.FullValuesUtc)).TotalSeconds;if($age -ge 300){$force=$true}}
 $layout=!$valid -or $uncertain -or $repair -or $published.End -ne $payload.End -or $published.TransactionHeader -ne $payload.TransactionHeader
 $clearEnd=[int]$payload.PreviousEnd;if($valid){$clearEnd=[math]::Max($clearEnd,[int]$published.End)};if($uncertain){$clearEnd=[math]::Max($clearEnd,[int]$pending.End)}
 # Lost cache extent means the entire allocated app detail region may be stale.
 # The fresh table overwrites retained rows; only its tail is cleared, never headers.
 if($repair){$clearEnd=$gridRows}
 $rows=$gridRows;$requests=New-Object 'Collections.Generic.List[object]';$hashes=[ordered]@{};$tableChanged=$false;$writtenRanges=0;$writtenCells=0;$skippedRanges=0
 if($payload.End -gt $rows){
  $rows=[int][math]::Min(60055,([math]::Ceiling($payload.End/250.0)*250))
  $requests.Add(@{appendDimension=@{sheetId=$id;dimension='ROWS';length=($rows-$gridRows)}})
  # Inherit existing numeric/date styles only into newly allocated rows.
  $requests.Add(@{copyPaste=@{source=@{sheetId=$id;startRowIndex=55;endRowIndex=56;startColumnIndex=0;endColumnIndex=11};destination=@{sheetId=$id;startRowIndex=$gridRows;endRowIndex=$rows;startColumnIndex=0;endColumnIndex=11};pasteType='PASTE_FORMAT';pasteOrientation='NORMAL'}})
  # Google may canonicalize an open-ended conditional range to the grid end.
  # Extend only app detail ranges that ended at the previous capacity.
  for($i=0;$i -lt @($conditionalFormats).Count;$i++){
   $rule=At58S-Clone $conditionalFormats[$i];$changed=$false
   foreach($range in @($rule.ranges)){
    if((Ops-Get $range 'sheetId' -1) -eq $id -and (Ops-Get $range 'startRowIndex' 0) -ge 54 -and (Ops-Get $range 'endRowIndex' -1) -eq $gridRows){$range.endRowIndex=$rows;$changed=$true}
   }
   if($changed){$requests.Add(@{updateConditionalFormatRule=@{sheetId=$id;index=$i;rule=$rule}})}
  }
  $layout=$true
 }
 $clearEnd=[int][math]::Min($clearEnd,$rows)
 foreach($request in $payload.Requests){
  if($request.ContainsKey('updateCells')){
   $u=$request.updateCells;$key=([string]$u.start.rowIndex+'|'+[string]$u.start.columnIndex)
   # Canonical array of cell values; each generated cell has exactly one value type.
   $signature=Ops-Key (ConvertTo-Json -InputObject @($u.rows) -Depth 20 -Compress)
   $hashes[$key]=$signature;$same=$valid -and (Ops-Get (Ops-Get $published 'Hashes') $key '') -ceq $signature
   if($force -or !$same){$requests.Add($request);$writtenRanges++;foreach($row in @($u.rows)){$writtenCells+=@($row.values).Count};if($u.start.rowIndex -eq 54 -and $u.start.columnIndex -eq 0){$tableChanged=$true}}else{$skippedRanges++}
  }elseif($request.ContainsKey('repeatCell')){
   $r=$request.repeatCell
   if($r.fields -ceq 'userEnteredValue'){
    # The table overwrite covers every retained cell. Clear only an old tail,
    # including a possibly applied but unacknowledged previous write.
    if($clearEnd -gt $payload.End){$requests.Add(@{repeatCell=@{range=@{sheetId=$id;startRowIndex=[int]$payload.End;endRowIndex=$clearEnd;startColumnIndex=0;endColumnIndex=11};cell=@{};fields='userEnteredValue'}});$writtenRanges++;$writtenCells+=($clearEnd-$payload.End)*11}
   }elseif($layout){
    $copy=At58S-Clone $request
    if($copy.repeatCell.range.startRowIndex -eq 54){$copy.repeatCell.range.endRowIndex=[math]::Max($copy.repeatCell.range.endRowIndex,$clearEnd)}
    if($copy.repeatCell.range.endRowIndex -gt $rows){$copy.repeatCell.range.endRowIndex=$rows}
    $requests.Add($copy)
   }
  }elseif($request.ContainsKey('autoResizeDimensions')){if($layout -or $tableChanged){$requests.Add($request)}}else{throw 'ASSET_PRESENTATION_REQUEST'}
 }
 $full=if($force){$now.ToString('o')}else{$published.FullValuesUtc}
 $lastWrite=if($requests.Count){$now.ToString('o')}else{$published.LastWriteUtc}
 $next=[pscustomobject]@{Schema='AT-ASSET-PRESENTATION-1';Target=$target;End=[int]$payload.End;TransactionHeader=[int]$payload.TransactionHeader;Hashes=[pscustomobject]$hashes;FullValuesUtc=$full;LastWriteUtc=$lastWrite}
 return [pscustomobject]@{Requests=$requests.ToArray();Cache=$next;UncertainEnd=[math]::Max($clearEnd,[int]$payload.End);GridRows=$rows;WrittenRanges=$writtenRanges;WrittenCells=$writtenCells;SkippedRanges=$skippedRanges;FullRefresh=[bool]$force}
}
function Asset-Publish($headers,[string]$base,$payload,[string]$scope,[int]$gridRows,[string]$outputRoot){
 $now=Ops-Now;$target=Ops-Key ('AT-ASSET-PRESENTATION-1|'+$script:At58SheetId+'|'+$scope)
 $cachePath=Join-Path $outputRoot 'assets-presentation.dpapi';$pendingPath=Join-Path $outputRoot 'assets-presentation-pending.dpapi'
 $published=Asset-ProtectedRead $cachePath 'AT-ASSET-PRESENTATION-1';$pending=Asset-ProtectedRead $pendingPath 'AT-ASSET-PENDING-1'
 $unreadableState=($null -eq $published -and (Test-Path -LiteralPath $cachePath)) -or ($null -eq $pending -and (Test-Path -LiteralPath $pendingPath))
 $cacheShape=Asset-PresentationStateValid $published 'Published' $now $payload;$pendingShape=Asset-PresentationStateValid $pending 'Pending' $now
 $repair=$unreadableState -or ($null -ne $published -and (!$cacheShape -or $published.Target -cne $target)) -or ($null -ne $pending -and !$pendingShape)
 $pendingGrowth=$pendingShape -and $pending.Target -ceq $target -and [int]$pending.End -gt $gridRows
 $conditionalFormats=@()
 if($payload.End -gt $gridRows -or $repair -or $pendingGrowth){
  # Growth and corrupted state need the current capacity, including an earlier
  # server-applied growth whose response was lost. Normal refresh does not read it.
  $meta=Invoke-RestMethod -Method Get -Uri ($base+'?fields=sheets(properties(sheetId,gridProperties(rowCount)),conditionalFormats)') -Headers $headers -TimeoutSec 10 -MaximumRedirection 0 -ErrorAction Stop
  $found=@($meta.sheets|Where-Object {$_.properties.sheetId -eq 1830155726})
  if($found.Count -ne 1){throw 'ASSET_SHEET_STRUCTURE'}
  $gridRows=[int]$found[0].properties.gridProperties.rowCount;$conditionalFormats=@(Ops-Get $found[0] 'conditionalFormats' @())
 }
 $plan=Asset-PublishPlan $payload $published $target $gridRows $now $pending $conditionalFormats $unreadableState
 if($plan.Requests.Count){
  # Save ambiguity boundary before sending; commit hashes only after exact success.
  Asset-ProtectedWrite $pendingPath 'AT-ASSET-PENDING-1' @{Schema='AT-ASSET-PENDING-1';Target=$target;End=$plan.UncertainEnd;StartedUtc=$now.ToString('o')}
  $reply=Invoke-RestMethod -Method Post -Uri ($base+':batchUpdate') -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes((@{requests=$plan.Requests}|ConvertTo-Json -Depth 20 -Compress))) -TimeoutSec 10 -MaximumRedirection 0 -ErrorAction Stop
  if($reply.spreadsheetId -cne $script:At58SheetId -or @($reply.replies).Count -ne $plan.Requests.Count){throw 'ASSET_SHEET_RESPONSE'}
  Asset-ProtectedWrite $cachePath 'AT-ASSET-PRESENTATION-1' $plan.Cache
  if(Test-Path -LiteralPath $pendingPath){Remove-Item -LiteralPath $pendingPath -Force}
 }
 return [pscustomobject]@{Requests=$plan.Requests.Count;Cached=($plan.Requests.Count -eq 0);LastPublishedUtc=$plan.Cache.LastWriteUtc;GridRows=$plan.GridRows;WrittenRanges=$plan.WrittenRanges;WrittenCells=$plan.WrittenCells;SkippedRanges=$plan.SkippedRanges;FullRefresh=$plan.FullRefresh}
}
function Asset-Pump($headers,[string]$base,$meta,$snapshot,$journalInput,[string]$dataRoot,[string]$outputRoot){
 $sheet=@($meta.sheets|Where-Object {$_.properties.title -ceq '자산상세내역' -and $_.properties.sheetId -eq 1830155726})
 if(!$sheet.Count -or !$journalInput){return};if($sheet[0].properties.gridProperties.columnCount -lt 11 -or $snapshot.Symbol -cne '0210A0'){throw 'ASSET_SHEET_STRUCTURE'}
 $now=Ops-Now;$last=Ops-ReadJson (Join-Path $outputRoot 'assets-status.json');if($last -and ($now-(Ops-Utc $last.Utc)).TotalSeconds -lt 20){return}
 $ledger=Asset-Ledger $journalInput.Ledger;$ctx=$null;$history=$null;$status='OK';$tokenPath=Join-Path $outputRoot 'assets-token.dpapi';$cachePath=Join-Path $outputRoot 'assets-history.dpapi';$completePath=Join-Path $outputRoot 'assets-complete.dpapi'
 try{
  $ctx=At58-Context $dataRoot $snapshot.Symbol
  $saved=Asset-ProtectedRead $tokenPath 'AT-ASSET-TOKEN-1';if($saved -and $saved.Scope -ceq $ctx.Scope -and (Ops-Utc $saved.Until) -gt $now.AddMinutes(2)){$ctx.Token=$saved.Token;$ctx.TokenUntil=Ops-Utc $saved.Until;$ctx.Mac=At58-Mac}
  $history=Asset-ProtectedRead $cachePath 'AT-ASSET-HISTORY-1'
  $history=Asset-Collect $ctx $history $ledger.From $snapshot.Day
  Asset-ProtectedWrite $cachePath 'AT-ASSET-HISTORY-1' $history
  if($history.Phase -ceq 'COMPLETE'){Asset-ProtectedWrite $completePath 'AT-ASSET-HISTORY-1' $history}
 }catch{$status='ASSET_HISTORY_RETRY';$history=$null}finally{
  if($ctx -and $ctx.Token){Asset-ProtectedWrite $tokenPath 'AT-ASSET-TOKEN-1' @{Scope=$ctx.Scope;Token=$ctx.Token;Until=$ctx.TokenUntil.ToString('o')}}
  if($ctx){$ctx.Credential=$null;$ctx.Token=''};$saved=$null
 }
 $complete=Asset-ProtectedRead $completePath 'AT-ASSET-HISTORY-1'
 if($complete -and ($complete.Scope -cne $snapshot.Scope -or $complete.From -cne $ledger.From)){$complete=$null}
 $costRows=if($history -and $history.Phase -cin @('TRANSACTIONS','COMPLETE')){@($history.CostRows)}elseif($complete){@($complete.CostRows)}else{@()}
 $report=Asset-CostReport $ledger $costRows
 $displayHistory=if($history -and $history.Phase -ceq 'COMPLETE'){$history}elseif($complete){$complete}else{$history}
 $payload=Asset-Payload $snapshot $ledger $report $displayHistory ([int](Ops-Get $last 'EndRow' (55+$ledger.Rows.Count)))
 $published=Asset-Publish $headers $base $payload $snapshot.Scope ([int]$sheet[0].properties.gridProperties.rowCount) $outputRoot
 Ops-WriteJson (Join-Path $outputRoot 'assets-status.json') @{Utc=(Ops-Now).ToString('o');Code=$status;Day=$snapshot.Day;SnapshotUtc=$snapshot.CompletedUtc;PublishedUtc=$published.LastPublishedUtc;Cached=$published.Cached;WriteRequests=$published.Requests;WrittenRanges=$published.WrittenRanges;WrittenCells=$published.WrittenCells;SkippedRanges=$published.SkippedRanges;FullRefresh=$published.FullRefresh;HistoryStartedUtc=$(if($history){$history.StartedUtc}else{''});HistoryCompletedUtc=$(if($history){$history.CompletedUtc}else{''});Phase=$(if($history){$history.Phase}else{'RETRY'});EndRow=$payload.End;Rows=$ledger.Rows.Count;VerifiedDays=$report.VerifiedDays;EstimatedDays=$report.EstimatedDays;Unclassified=$payload.Unknown}
}

function SheetDiag-Get($o,[string]$k,$default=$null){if($null -eq $o){return $default};if($o -is [Collections.IDictionary]){if($o.Contains($k)){return $o[$k]}}elseif($o.PSObject.Properties[$k]){return $o.$k};return $default}
function SheetDiag-Json([string]$p){if(!(Test-Path -LiteralPath $p -PathType Leaf)){return $null};$f=Get-Item -LiteralPath $p;if($f.Length -gt 2MB -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'LOG_FILE_REJECTED'};return ([IO.File]::ReadAllText($p,[Text.Encoding]::UTF8)|ConvertFrom-Json)}
function SheetDiag-Write([string]$p,$o){
 $tmp=$p+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 try{
  [IO.File]::WriteAllText($tmp,($o|ConvertTo-Json -Depth 12 -Compress),[Text.UTF8Encoding]::new($false))
  # Windows PowerShell converts $null to an empty string for a string argument.
  # NullString passes an actual null backup path to File.Replace.
  if([IO.File]::Exists($p)){[IO.File]::Replace($tmp,$p,[Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($tmp,$p)}
 }catch{throw 'LOCAL_SAVE_FAILED'}finally{if([IO.File]::Exists($tmp)){try{[IO.File]::Delete($tmp)}catch{}}}
}
function SheetDiag-Utc($v){if($v -is [datetime]){return $v.ToUniversalTime().ToString('o')};$s=[string]$v;if($s -cnotmatch '^20\d\d-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,7})?(?:Z|[+-]\d\d:\d\d)$'){return ''};try{return [datetime]::Parse($s,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime().ToString('o')}catch{return ''}}
function SheetDiag-Kst($v){$s=SheetDiag-Utc $v;if(!$s){return ''};return [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([datetime]::Parse($s).ToUniversalTime(),'Korea Standard Time').ToString('yyyy-MM-dd HH:mm:ss')}
function SheetDiag-Age($v,[datetime]$now){$s=SheetDiag-Utc $v;if(!$s){return ''};return [math]::Floor(($now.ToUniversalTime()-([datetime]::Parse($s).ToUniversalTime())).TotalSeconds)}
function SheetDiag-Clean($o){
 $r=[ordered]@{}
 foreach($k in @('Schema','Source','State','Code','Mode','Fault','LastFault','ExitReason','LiveMode','LiveState','LiveMaintenance','Phase','Outcome','Step','Reason','StopReason','CommandError','AutoStartCode','ErrorType','Network')){$v=[string](SheetDiag-Get $o $k '');if($v -cmatch '^[A-Za-z][A-Za-z0-9_ -]{0,63}$'){$r[$k]=$v}}
 foreach($k in @('Version','BundleVersion')){$v=[string](SheetDiag-Get $o $k '');if($v -cmatch '^\d{1,4}(\.\d{1,4}){1,3}$'){$r[$k]=$v}}
 foreach($k in @('RunId','HostSession')){$v=[string](SheetDiag-Get $o $k '');if($v -cmatch '^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$'){$r[$k]=$v}}
 foreach($k in @('Utc','LastSuccessUtc','SnapshotUtc','StartedUtc','StageUtc','PublishedUtc')){$v=SheetDiag-Utc (SheetDiag-Get $o $k);if($v){$r[$k]=$v}}
 $v=[string](SheetDiag-Get $o 'Stage' '');if($v -cmatch '^[a-zA-Z/][a-zA-Z0-9_/-]{0,99}$'){$r.Stage=$v}
 $v=[string](SheetDiag-Get $o 'ApiCode' '');if($v -cmatch '^(?:(?:EGW|IGW)[0-9]{5}|[0-9]{4,5})$'){$r.ApiCode=$v}
 foreach($k in @('Failures','Calls','Sequence','OrdersSent','OpenOrders','UncertainOrders','Confirmations','Sessions','Receipts','Fills','Pending','Gaps','Duplicates','Rows','Written','Total','Added','HostProtocol','Http','Line','Orders','PaperOrders','PaperFills','SimulatedPosts','ElapsedMs','Win32','WrittenRanges','SkippedRanges','WrittenCells','WriteRequests')){$v=SheetDiag-Get $o $k;$n=0L;if($null -ne $v -and [long]::TryParse([string]$v,[ref]$n) -and $n -ge 0 -and $n -le 2147483647){$r[$k]=$n}}
 foreach($k in @('ExecutionEnabled','Reconciled','Connected','Running','DesiredRunning','Busy','LiveCommandPending','RepairRunning','RepairTransaction','CircuitOpen','TelegramReady','AutoRepair','Available','SnapshotAvailable','TestOnly','InputSaved','AutoStartEnabled','AutoStartAttempted','AutoStartSuspended','FullRefresh','Cached')){$v=SheetDiag-Get $o $k;if($v -is [bool]){$r[$k]=$v}}
 return $r
}
function SheetDiag-ReadStatus([string]$root,[string]$name,[datetime]$now){
 $p=Join-Path $root $name;$read='OK';$r=[ordered]@{};$live=[ordered]@{}
 try{if((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'DIAG_LINKED_ROOT'};$j=SheetDiag-Json $p;if($null -eq $j){$read='MISSING'}else{$r=SheetDiag-Clean $j;if(SheetDiag-Get $j 'Live'){$live=SheetDiag-Clean $j.Live};if(SheetDiag-Get $j 'Error'){foreach($k in @('ErrorType','Network','Http','Win32')){$err=SheetDiag-Clean $j.Error;if($err.Contains($k)){$r[$k]=$err[$k]}}}}}catch{$read='READ_ERROR'}
 return [pscustomobject]@{File=$name;Read=$read;Age=(SheetDiag-Age (SheetDiag-Get $r 'Utc') $now);Data=$r;Live=$live}
}
function SheetDiag-Tail([string]$path,[int]$limit=100){
 if(!(Test-Path -LiteralPath $path -PathType Leaf)){return @()};if((Get-Item -LiteralPath (Split-Path $path)).Attributes -band [IO.FileAttributes]::ReparsePoint){return @()};$f=Get-Item -LiteralPath $path;if($f.Attributes -band [IO.FileAttributes]::ReparsePoint){return @()}
 # Read at most 256 KiB. A partially written final record is ignored.
 $fs=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
 try{$n=[int][math]::Min(262144,$fs.Length);$offset=$fs.Length-$n;[void]$fs.Seek($offset,[IO.SeekOrigin]::Begin);$buf=New-Object byte[] $n;$got=0;while($got -lt $n){$read=$fs.Read($buf,$got,$n-$got);if(!$read){break};$got+=$read};$lines=[Text.Encoding]::UTF8.GetString($buf,0,$got) -split '\r?\n';if($offset -gt 0){$lines=@($lines|Select-Object -Skip 1)};return @($lines|Where-Object {$_}|Select-Object -Last $limit)}finally{$fs.Dispose()}
}
function SheetDiag-Snapshot([string]$data,[string]$manage,[string]$hostRoot,[datetime]$now=[datetime]::UtcNow){
 $now=$now.ToUniversalTime()
 $sources=New-Object 'Collections.Generic.List[object]'
 foreach($n in @('status.json','strategy-input-status.json','strategy-status.json','execution-status.json','order-status.json','simulation-status.json','input-refresh-status.json','input-refresh-success.json')){$sources.Add((SheetDiag-ReadStatus $data $n $now))}
 foreach($n in @('runtime.json','manager-status.json','sheets-status.json','journal-status.json','bundle-status.json','update-status.json','manager-error.json','assets-status.json','diagnostics-status.json')){$sources.Add((SheetDiag-ReadStatus $manage $n $now))}
 $active=SheetDiag-ReadStatus $hostRoot 'active.json' $now;$sources.Add($active)
 $logs=New-Object 'Collections.Generic.List[object]'
 $kst=[TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($now,'Korea Standard Time')
 foreach($day in @($kst.AddDays(-1).ToString('yyyyMMdd'),$kst.ToString('yyyyMMdd'))){foreach($item in @(@($data,'read'),@($data,'execution'),@($manage,'manager'))){$name=$item[1]+'-'+$day+'.jsonl';try{foreach($line in (SheetDiag-Tail (Join-Path $item[0] $name) 1000)){try{$r=SheetDiag-Clean ($line.TrimStart([char]0xFEFF)|ConvertFrom-Json);if((SheetDiag-Get $r 'Utc') -and (SheetDiag-Get $r 'Code')){$logs.Add([pscustomobject]@{File=$name;Data=$r})}}catch{}}}catch{}}}
 return [pscustomobject]@{Schema='AVATA_MAINPC_LOG_1';CollectedUtc=$now.ToString('o');Sources=$sources.ToArray();Logs=@($logs.ToArray()|Sort-Object {$_.Data.Utc} -Descending|Select-Object -First 300)}
}
function SheetDiag-Row($kind,$name,$d,$age,$read='',$live=$null){
 $detail=[ordered]@{Read=$read};foreach($k in $d.Keys){if($k -notin @('Utc','State','Code','Stage','ApiCode','Failures','Calls','Sequence','RunId')){$detail[$k]=$d[$k]}};if($live -and $live.Count){$detail.Live=$live}
 return ,@($kind,$name,(SheetDiag-Kst (SheetDiag-Get $d 'Utc')),$age,[string](SheetDiag-Get $d 'State' ''),[string](SheetDiag-Get $d 'Code' ''),[string](SheetDiag-Get $d 'ApiCode' ''),[string](SheetDiag-Get $d 'Stage' ''),(SheetDiag-Get $d 'Failures' ''),(SheetDiag-Get $d 'Calls' ''),(SheetDiag-Get $d 'Sequence' ''),($detail|ConvertTo-Json -Depth 5 -Compress),[string](SheetDiag-Get $d 'RunId' ''))
}
function SheetDiag-Values($snapshot,[string]$device,[long]$sequence,[string]$state='RUNNING'){
 $rows=New-Object 'Collections.Generic.List[object]';$now=[datetime]::Parse($snapshot.CollectedUtc).ToUniversalTime()
 $rows.Add(@('AVATA_MAINPC_LOG_1',$device,'1.1.6','MAINPC'))
 $app=@($snapshot.Sources|Where-Object File -ceq 'status.json')[0];$health=if($app.Read -cne 'OK' -or $app.Age -is [string] -or [double]$app.Age -gt 90 -or [double]$app.Age -lt -30){'APP_STALE'}else{'APP_FRESH'}
 $rows.Add(@('수집 시각(KST)',(SheetDiag-Kst $snapshot.CollectedUtc),'수집 시각(UTC)',$snapshot.CollectedUtc,'전송 번호',$sequence,'수집기 상태',$state,'앱 원본 갱신',$health))
 $rows.Add(@('아바타 자동 진단 전송 · 원본 파일의 시각/경과초를 확인하세요. 수집 시각만 최신이어도 아바타 조회가 멈췄을 수 있습니다.'))
 $rows.Add(@('키·토큰·계좌번호·보유내역·주문번호 제외 / 최근 로그 300건 / 이전 기록은 메인PC에 그대로 유지'))
 $rows.Add(@('종류','파일','원본 시각(KST)','경과초','상태','진단 코드','API 코드','단계','실패 횟수','요청 누적','완료 횟수','추가 진단 정보','실행 ID'))
 foreach($s in $snapshot.Sources){$rows.Add((SheetDiag-Row 'STATUS' $s.File $s.Data $s.Age $s.Read $s.Live))}
 foreach($l in $snapshot.Logs){$rows.Add((SheetDiag-Row 'LOG' $l.File $l.Data (SheetDiag-Age (SheetDiag-Get $l.Data 'Utc') $now)))}
 while($rows.Count -lt 400){$rows.Add(@())}
 $fixed=New-Object 'Collections.Generic.List[object]';foreach($r in $rows){$cells=New-Object object[] 13;for($i=0;$i -lt 13;$i++){$cells[$i]=if($i -lt $r.Count -and $null -ne $r[$i]){$r[$i]}else{''}};$fixed.Add($cells)}
 return ,$fixed.ToArray()
}

# This worker only reads bounded diagnostics and writes its own status/cache and diagnostic tab.
function SheetDiag-Identity([string]$root){
 $path=Join-Path $root 'diagnostics-device.json';$id=SheetDiag-Json $path
 if(!$id){$id=@{Schema='AVATA-MAINPC-DEVICE-1';DeviceId=[guid]::NewGuid().ToString()};SheetDiag-Write $path $id}
 if($id.Schema -cne 'AVATA-MAINPC-DEVICE-1' -or $id.DeviceId -cnotmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'){throw 'DIAG_DEVICE_INVALID'}
 return [string]$id.DeviceId
}
function SheetDiag-Auth($cfg,[string]$root){
 $key=$null;$plain=$null;$saved=$null;$raw=$null;$jwt=$null;$auth=$null
 try{
  $raw=[IO.File]::ReadAllText($cfg.KeyPath);$fingerprint=Ops-Key $raw;$key=$raw|ConvertFrom-Json;$raw=$null
  if($key.type -cne 'service_account' -or $key.client_email -notmatch '^[^\s@]+@[^\s@]+\.gserviceaccount\.com$' -or !$key.private_key.StartsWith('-----BEGIN PRIVATE KEY-----')){throw 'DIAG_AUTH'}
  $cache=Join-Path $root 'diagnostics-token.dpapi'
  try{$saved=(Sheet-Unprotect ([IO.File]::ReadAllText($cache)) 'AT58-DIAG-TOKEN-1')|ConvertFrom-Json;if($saved.Key -ceq $fingerprint -and (Ops-Utc $saved.Until) -gt (Ops-Now).AddMinutes(2)){return [string]$saved.Token}}catch{}
  $epoch=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();$claims=@{iss=$key.client_email;scope='https://www.googleapis.com/auth/spreadsheets';aud='https://oauth2.googleapis.com/token';iat=$epoch;exp=($epoch+3600)}|ConvertTo-Json -Compress
  $unsigned=[At58SheetsJwt]::B64([Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}'))+'.'+[At58SheetsJwt]::B64([Text.Encoding]::UTF8.GetBytes($claims));$jwt=[At58SheetsJwt]::Sign($unsigned,$key.private_key)
  $auth=Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/token' -ContentType 'application/x-www-form-urlencoded' -Body @{grant_type='urn:ietf:params:oauth:grant-type:jwt-bearer';assertion=$jwt} -TimeoutSec 10 -MaximumRedirection 0
  if(!$auth.access_token -or [int]$auth.expires_in -le 120){throw 'DIAG_AUTH'}
  Add-Type -AssemblyName System.Security
  $plain=[Text.Encoding]::UTF8.GetBytes((@{Key=$fingerprint;Token=$auth.access_token;Until=(Ops-Now).AddSeconds([int]$auth.expires_in-60).ToString('o')}|ConvertTo-Json -Compress))
  $cipher=[Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($plain,[Text.Encoding]::UTF8.GetBytes('AT58-DIAG-TOKEN-1'),[Security.Cryptography.DataProtectionScope]::CurrentUser))
  [IO.File]::WriteAllText($cache,$cipher,[Text.UTF8Encoding]::new($false))
  return [string]$auth.access_token
 }finally{if($plain){[Array]::Clear($plain,0,$plain.Length)};$key=$null;$saved=$null;$raw=$null;$jwt=$null;$auth=$null}
}
function SheetDiag-Target($headers,[string]$base,[string]$device){
 $meta=Invoke-RestMethod -Method Get -Uri ($base+'?fields=sheets(properties(sheetId,title,gridProperties(rowCount,columnCount)))') -Headers $headers -TimeoutSec 10 -MaximumRedirection 0
 $tabs=@($meta.sheets|Where-Object {$_.properties.title -ceq '메인PC_진단' -or $_.properties.sheetId -eq 2026110590})
 if(!$tabs.Count){
  # Creation and initial ownership are one atomic Sheets batch. Never overwrite an existing tab.
  $body=@{requests=@(@{addSheet=@{properties=@{sheetId=2026110590;title='메인PC_진단';gridProperties=@{rowCount=400;columnCount=13;frozenRowCount=5;hideGridlines=$true}}}},@{updateCells=@{start=@{sheetId=2026110590;rowIndex=0;columnIndex=0};rows=@(@{values=@(@{userEnteredValue=@{stringValue='AVATA_MAINPC_LOG_1'}},@{userEnteredValue=@{stringValue=$device}},@{userEnteredValue=@{stringValue='1.1.6'}},@{userEnteredValue=@{stringValue='MAINPC'}})});fields='userEnteredValue'}})}|ConvertTo-Json -Depth 14 -Compress
  $reply=Invoke-RestMethod -Method Post -Uri ($base+':batchUpdate') -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 10 -MaximumRedirection 0
  if($reply.spreadsheetId -cne ($base.Split('/')[-1]) -or $reply.replies.Count -ne 2){throw 'DIAG_CREATE_UNCONFIRMED'}
 }elseif($tabs.Count -ne 1 -or $tabs[0].properties.title -cne '메인PC_진단' -or $tabs[0].properties.sheetId -ne 2026110590 -or $tabs[0].properties.gridProperties.rowCount -lt 400 -or $tabs[0].properties.gridProperties.columnCount -lt 13){throw 'DIAG_TAB_MISMATCH'}
 $range=[uri]::EscapeDataString("'메인PC_진단'!A1:D1")
 $head=Invoke-RestMethod -Method Get -Uri ($base+'/values/'+$range) -Headers $headers -TimeoutSec 10 -MaximumRedirection 0
 if(!$head.values -or $head.values[0].Count -lt 4 -or $head.values[0][0] -cne 'AVATA_MAINPC_LOG_1' -or $head.values[0][3] -cne 'MAINPC'){throw 'DIAG_MARKER_MISMATCH'}
 if($head.values[0][1] -cne $device){throw 'DIAG_DEVICE_MISMATCH'}
}
function SheetDiag-Send($snapshot,$headers,[string]$base,[string]$device,[long]$seq){
 SheetDiag-Target $headers $base $device
 $values=SheetDiag-Values $snapshot $device $seq
 if($values.Count -ne 400 -or @($values|Where-Object {$_.Count -ne 13}).Count){throw 'DIAG_WRITE_SHAPE'}
 $range="'메인PC_진단'!A1:M400"
 $body=@{range=$range;majorDimension='ROWS';values=$values}|ConvertTo-Json -Depth 10 -Compress
 $r=Invoke-RestMethod -Method Put -Uri ($base+'/values/'+[uri]::EscapeDataString($range)+'?valueInputOption=RAW') -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 10 -MaximumRedirection 0
 if($r.spreadsheetId -cne ($base.Split('/')[-1]) -or $r.updatedRows -ne 400 -or $r.updatedColumns -ne 13){throw 'DIAG_WRITE_UNCONFIRMED'}
}
function SheetDiag-Failure($record){
 $code=[string]$record.Exception.Message
 if($code -cmatch '^DIAG_[A-Z_]{1,50}$'){return $code}
 return 'DIAG_TRANSPORT_OR_STORAGE'
}
function SheetDiag-Run([string]$data,[string]$manage){
 $headers=$null;$mutex=$null;$owned=$false;$lastSuccess='';$seq=0L;$device=''
 try{
  $created=$false;$mutex=[Threading.Mutex]::new($true,('Local\Avata-MainPC-Diagnostics-'+(Ops-Key $manage.ToLowerInvariant()).Substring(0,24)),[ref]$created)
  if(!$created){return 2};$owned=$true
  $cfg=Sheet-Config $manage;if(!$cfg.Enabled){throw 'DIAG_DISABLED'}
  $sheet=Sheet-Id ([string](Ops-Get $cfg 'SheetId' ''));$device=SheetDiag-Identity $manage
  $previous=SheetDiag-Json (Join-Path $manage 'diagnostics-status.json')
  if($previous){$lastSuccess=SheetDiag-Utc (Ops-Get $previous 'LastSuccessUtc');$seq=[math]::Max(0,[long](Ops-Get $previous 'Sequence' 0))}
  $seq++
  $headers=@{Authorization=('Bearer '+(SheetDiag-Auth $cfg $manage))}
  $hostRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'esbada_AT_host'
  $snapshot=SheetDiag-Snapshot $data $manage $hostRoot
  SheetDiag-Send $snapshot $headers ('https://sheets.googleapis.com/v4/spreadsheets/'+$sheet) $device $seq
  $now=Ops-Now
  SheetDiag-Write (Join-Path $manage 'diagnostics-status.json') @{Schema='AVATA_MAINPC_LOG_1';Version='1.1.6';Code='OK';Utc=$now.ToString('o');LastSuccessUtc=$now.ToString('o');Sequence=$seq;DeviceId=$device}
  return 0
 }catch{
  $code=SheetDiag-Failure $_
  try{SheetDiag-Write (Join-Path $manage 'diagnostics-status.json') @{Schema='AVATA_MAINPC_LOG_1';Version='1.1.6';Code=$code;Utc=(Ops-Now).ToString('o');LastSuccessUtc=$lastSuccess;Sequence=$seq;DeviceId=$device}}catch{}
  return 1
 }finally{$headers=$null;if($mutex){if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}}
}
function SheetDiag-Pump([string]$bundle,[string]$data,[string]$manage){
 if(!$script:At58DiagPump){$script:At58DiagPump=@{Job=$null;Next=[datetime]::MinValue;Failures=0}}
 $p=$script:At58DiagPump;$now=Ops-Now
 if($p.Job){
  if(!$p.Job.Process.HasExited){if(($now-$p.Job.Started).TotalSeconds -le 55){return};$p.Job.Process.Kill();if(!$p.Job.Process.WaitForExit(1000)){return}}
  $ok=$p.Job.Process.ExitCode -eq 0;$p.Job.Process.Dispose();$p.Job=$null
  $p.Failures=if($ok){0}else{[math]::Min(3,$p.Failures+1)}
  $p.Next=$now.AddSeconds($(if($ok){15}else{[math]::Min(120,15*[math]::Pow(2,$p.Failures))}))
 }
 if($now -lt $p.Next){return}
 $cfg=Sheet-Config $manage;if(!$cfg.Enabled){$p.Next=$now.AddSeconds(30);return}
 # No dependency on snapshots, ledger reconciliation, trading mode, or the normal sheet worker.
 $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $p.Job=Ops-StartProcess $exe @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $bundle 'At58.SheetWorker.ps1'),'-DataRoot',$data,'-ManagementRoot',$manage,'-Diagnostics') $bundle
}
function SheetDiag-StopPump {
 if($script:At58DiagPump -and $script:At58DiagPump.Job){$p=$script:At58DiagPump.Job.Process;try{if(!$p.HasExited){$p.Kill()};$p.Dispose()}catch{};$script:At58DiagPump.Job=$null}
}

$script:At58DiagPump=$null
