param([string]$Root=$PSScriptRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
. (Join-Path $Root 'bundle/At58.Ops.ps1')
. (Join-Path $Root 'bundle/At58.Sheets.ps1')
. (Join-Path $Root 'bundle/payload/At58.Core.ps1')
$script:checks=0
function Check($ok,[string]$name){if(!$ok){throw ('FAILED: '+$name)};$script:checks++;'PASS '+$name}
function Reject($body,[string]$code,[string]$name){$found='';try{& $body|Out-Null}catch{$found=$_.Exception.Message};Check ($found -ceq $code) ($name+' ['+$found+']')}
function Clone($v){
 # Test fixtures must preserve nested arrays. PS5.1 JSON round-tripping can
 # serialize pipeline-wrapped arrays as {value,Count}, unlike a Sheets response.
 if($null -eq $v){return $null}
 if($v -is [array]){$copy=[object[]]::new($v.Length);for($i=0;$i -lt $v.Length;$i++){$copy[$i]=Clone $v[$i]};return ,$copy}
 if($v -is [Collections.IDictionary]){$copy=[ordered]@{};foreach($key in $v.Keys){$copy[$key]=Clone $v[$key]};return [pscustomobject]$copy}
 if($v -is [pscustomobject]){$copy=[ordered]@{};foreach($p in $v.PSObject.Properties){$copy[$p.Name]=Clone $p.Value};return [pscustomobject]$copy}
 return $v
}
function Baseline-Identity($rows){$lines=@();foreach($row in $rows){$cells=@();foreach($v in $row){$cells+=,[string]$v};$lines+=,($cells -join '|')};return ($lines -join "`n")}
function Same-Cells($before,$after){
 if($before.Count -ne $after.Count){return $false}
 for($i=0;$i -lt $before.Count;$i++){
  if($after[$i] -isnot [array] -or $before[$i].Count -ne $after[$i].Count){return $false}
  for($j=0;$j -lt $before[$i].Count;$j++){
   $a=$before[$i][$j];$b=$after[$i][$j]
   if($a -is [ValueType]){
    if($b -isnot [ValueType]){return $false}
    $delta=[math]::Abs([decimal]$a-[decimal]$b)
    if(($j -eq 0 -and $delta -gt .00000001) -or ($j -ne 0 -and $delta -ne 0)){return $false}
   }elseif([string]$a -cne [string]$b){return $false}
  }
 }
 return $true
}
function Order([string]$key,[string]$id,[string]$day='20261104',[string]$side='매수',[int]$stage=9){[pscustomobject]@{Key=$key;Day=$day;BrokerId=$id;Action='NEW';Intent=[pscustomobject]@{Stage=$stage;Side=$side}}}
function Fill([string]$name,[string]$order,[decimal]$qty,[decimal]$price,[string]$time,[string]$day='20261104'){[pscustomobject]@{Key=(At58-Hash $name);OrderKey=$order;Account=('a'*64);Day=$day;Time=$time;Qty=$qty;Price=$price;Amount=($qty*$price);Evidence='BROKER_NOTIFICATION_RECONCILED'}}
function Catalog($fills,$orders=$script:orders){Sheet-JournalCatalog $script:state ([pscustomobject]@{Mode='LIVE';Scope='synthetic-scope';Account=('a'*64);Symbol='SYNTHETIC';Orders=$orders;Fills=$fills;Revision=7})}
$script:orders=@((Order 'buy-a' '101'),(Order 'buy-b' '202'),(Order 'sell-c' '303' '20261104' '매도'),(Order 'next-day' '101' '20261105'),(Order 'amended' '404'))
$script:state=[pscustomobject]@{TestOnly=$false;Scope='synthetic-scope';Symbol='SYNTHETIC';SourceHash=''}
$a=Fill 'fill-a1' 'buy-a' 9 6175 '100000001';$b=Fill 'fill-a2' 'buy-a' 1 6175 '100000002'
$c=Fill 'fill-b1' 'buy-b' 10 5905 '110000001';$d=Fill 'fill-b2' 'buy-b' 6 5910 '110000002'
$cat=Catalog @($a,$b,$c,$d)
Check ($cat.Orders.Count -eq 2 -and $cat.Entries.Count -eq 4) 'four notifications become two order rows while retaining all fills'
Check ($cat.Orders[0].Values[3] -eq 6175 -and $cat.Orders[0].Values[4] -eq 10 -and $cat.Orders[0].Values[5] -eq 61750) '9 plus 1 shares merge without changing amount'
Check ($cat.Orders[1].Values[4] -eq 16 -and $cat.Orders[1].Values[5] -eq 94510 -and $cat.Orders[1].Values[3] -eq 5906.875) 'different prices use quantity-weighted average and exact total'
Check ($cat.Orders[0].BrokerId -ceq '101' -and $cat.Orders[1].BrokerId -ceq '202') 'distinct order numbers stay separate at the same stage'
$next=Fill 'fill-next' 'next-day' 2 6175 '100000001' '20261105'
Check ((Catalog @($a,$b,$next)).Orders.Count -eq 2) 'reused order number on another date is separate'
Check ((Catalog @($a,(Fill 'fill-amend' 'amended' 1 6175 '100001001'))).Orders.Count -eq 2) 'replacement order number is not merged with its original'
Reject {Catalog @($a,$a)} 'SHEET_JOURNAL_DUPLICATE' 'duplicate notification rejected'
$bad=Clone $a;$bad.Amount++
Reject {Catalog @($bad)} 'SHEET_JOURNAL_FILL' 'fill amount cannot disagree with broker price and quantity'
$bad=Clone $a;$bad.Account='b'*64
Reject {Catalog @($bad)} 'SHEET_JOURNAL_FILL' 'another account fill cannot enter the catalog'
$bad=Clone $a;$bad.Evidence='SIMULATED'
Reject {Catalog @($bad)} 'SHEET_JOURNAL_FILL' 'only reconciled broker fills are grouped'
$same=@((Order 'buy-a' '101'),(Order 'buy-b' '101'))
Reject {Catalog @($a,$c) $same} 'SHEET_JOURNAL_ORDER_CONFLICT' 'conflicting nodes for one broker order are rejected'
$manualHeader=@('날짜','차수','구분(매수/매도)','체결단가','수량','체결금액','AT 체결키')
$manual=@(([datetime]'2026-11-03').ToOADate(),1,'매수',5000,20,100000)
function LegacyRows($catalog){$r=New-Object 'Collections.Generic.List[object]';$r.Add([object[]]$script:manualHeader);$r.Add([object[]]$script:manual);foreach($e in $catalog.Entries){$r.Add([object[]]@($e.Values[0],$e.Values[1],$e.Values[2],$e.Values[3],$e.Values[4],$e.Values[5],$e.Key))};return ,$r.ToArray()}
$legacy=LegacyRows $cat;$layout=[pscustomobject]@{Rows=1000;Cols=7;Range="'매매일지'!A1:G1000"}
$view=Sheet-JournalFilter $legacy $cat
Check ($view.Rows.Count -eq 2 -and $view.Covered.Count -eq 4) 'legacy fill rows are validated and excluded from strategy baseline'
$plan=Sheet-JournalPlan $cat $legacy $layout
Check ($plan.Deleted -eq 2 -and $plan.LastRow -eq 4 -and $plan.Updated -eq 2 -and $plan.SchemaChange) 'existing split rows migrate in place to two order rows'
$deletes=@($plan.Requests|Where-Object {$_.ContainsKey('deleteDimension')}|ForEach-Object {$_.deleteDimension.range.startIndex})
Check (($deletes -join ',') -ceq '5,3') 'only redundant automatic rows are deleted in descending order'
Check (($plan.Rows[1]|ConvertTo-Json -Compress) -ceq ($manual|ConvertTo-Json -Compress)) 'manual trade values remain unchanged'
Check ((Sheet-JournalFormula) -match 'I2:I' -and (Sheet-JournalFormula $false) -notmatch 'I2:I') 'exact amounts have their own formula source; manual multiplication stays available'
# A minimal synthetic Sheets executor interprets the actual batch requests.
$script:fakeRows=New-Object 'Collections.Generic.List[object]';$script:fakeFormula=Sheet-JournalFormula $false;$script:cols=7;$script:gridRows=1000
function Load-Rows($rows,[int]$cols=7){$script:fakeRows.Clear();foreach($r in $rows){$v=[object[]]::new(9);for($j=0;$j -lt $r.Count;$j++){$v[$j]=$r[$j]};$script:fakeRows.Add($v)};$script:cols=$cols;$script:gridRows=1000;$script:fakeFormula=Sheet-JournalFormula ($cols -ge 9)}
function Apply-Batch($requests){
 foreach($r in $requests){
  if($r.ContainsKey('appendDimension')){if($r.appendDimension.dimension -ceq 'COLUMNS'){$script:cols+=$r.appendDimension.length}else{$script:gridRows+=$r.appendDimension.length};continue}
  if($r.ContainsKey('deleteDimension')){$x=$r.deleteDimension.range;Check ($x.dimension -ceq 'ROWS' -and $x.endIndex -eq $x.startIndex+1 -and [string]$script:fakeRows[$x.startIndex][6] -ne '') 'batch deletion targets one owned automatic row';$script:fakeRows.RemoveAt($x.startIndex);$script:gridRows--;continue}
  if($r.ContainsKey('updateCells')){
   $x=$r.updateCells;if($x.fields -cne 'userEnteredValue'){continue};$i=[int]$x.start.rowIndex;$col=[int]$x.start.columnIndex
   foreach($row in $x.rows){while($script:fakeRows.Count -le $i){$script:fakeRows.Add(([object[]]::new(9)))};$j=$col
    foreach($cell in $row.values){$v=$cell.userEnteredValue;if($v.ContainsKey('formulaValue')){$script:fakeFormula=$v.formulaValue}elseif($v.ContainsKey('numberValue')){$script:fakeRows[$i][$j]=$v.numberValue}else{$script:fakeRows[$i][$j]=$v.stringValue};$j++};$i++
   };continue
  }
  if(!$r.ContainsKey('copyPaste') -and !$r.ContainsKey('repeatCell') -and !$r.ContainsKey('updateDimensionProperties')){throw 'UNSUPPORTED_SYNTHETIC_REQUEST'}
 }
 for($i=1;$i -lt $script:fakeRows.Count;$i++){$r=$script:fakeRows[$i];if([string]$r[2] -ne ''){$r[5]=if($script:fakeFormula -ceq (Sheet-JournalFormula) -and [string]$r[8] -ne ''){[decimal]$r[8]}else{[decimal]$r[3]*[decimal]$r[4]}}}
}
Load-Rows $legacy;Apply-Batch $plan.Requests
$grouped=Clone $script:fakeRows.ToArray();$gLayout=[pscustomobject]@{Rows=$script:gridRows;Cols=9;Range="'매매일지'!A1:I"+$script:gridRows}
$filtered=Sheet-JournalFilter $grouped $cat
Check ($filtered.Seen.Count -eq 2 -and $filtered.Covered.Count -eq 4 -and $grouped[3][5] -eq 94510) 'batch readback validates one row per order and exact amounts'
Check ((Sheet-JournalPlan $cat $grouped $gLayout).Requests.Count -eq 0) 'repeat sync is idempotent after migration'
Check ((Baseline-Identity $filtered.Rows) -ceq (Baseline-Identity $view.Rows)) 'strategy baseline is identical before and after migration'
$partial=Catalog @($a);$later=Catalog @($a,$b)
$partialRows=@($grouped[0],$manual,(Sheet-JournalOrderRow $partial.Orders[0]))
$p=Sheet-JournalPlan $later $partialRows $gLayout
Check ($p.Updated -eq 1 -and $p.Missing.Count -eq 0 -and $p.LastRow -eq 3 -and $p.Rows[2][4] -eq 10) 'later partial fill updates the existing order row rather than adding a row'
$earlier=Fill 'out-of-time-order' 'buy-a' 2 6170 '095959001'
$late=Catalog @($a,$b,$earlier)
Check ((Sheet-JournalFilter $partialRows $late).Covered.Count -eq 1) 'late notification with earlier timestamp preserves historical checkpoint validity'
Check ((Sheet-JournalPlan $late $partialRows $gLayout).Rows[2][4] -eq 12) 'late notification is included once in the cumulative order row'
$bad=Clone $grouped;$bad[2][4]++
Reject {Sheet-JournalPlan $cat $bad $gLayout} 'SHEET_JOURNAL_CHANGED' 'edited grouped quantity cannot be silently overwritten'
$bad=Clone $grouped;$bad[2][8]++
Reject {Sheet-JournalPlan $cat $bad $gLayout} 'SHEET_JOURNAL_CHANGED' 'edited exact amount is rejected'
$bad=Clone $grouped;$bad[2][7]='wrong'
Reject {Sheet-JournalPlan $cat $bad $gLayout} 'SHEET_JOURNAL_CHANGED' 'edited visible order identity is rejected'
$bad=Clone $grouped;$bad[2][6]='ATO1-unknown'
Reject {Sheet-JournalPlan $cat $bad $gLayout} 'SHEET_JOURNAL_UNKNOWN' 'unknown automatic row cannot be removed'
$bad=@($grouped[0],$manual,$grouped[2],$legacy[2])
Reject {Sheet-JournalFilter $bad $cat} 'SHEET_JOURNAL_DUPLICATE' 'mixed grouped and original rows cannot count a fill twice'
$bad=Clone $legacy;$bad[0]+=@('사용자 메모')
Reject {Sheet-JournalPlan $cat $bad $gLayout} 'SHEET_JOURNAL_COLUMN' 'unrelated extra columns block migration rather than being overwritten'
$fraction=Catalog @((Fill 'fraction1' 'buy-a' 1 5905 '100000001'),(Fill 'fraction2' 'buy-a' 2 5910 '100000002'))
$fractionPlan=Sheet-JournalPlan $fraction (LegacyRows $fraction) $layout
Load-Rows (LegacyRows $fraction);Apply-Batch $fractionPlan.Requests
Check ($script:fakeRows[2][4] -eq 3 -and $script:fakeRows[2][5] -eq 17725 -and $script:fakeRows[2][8] -eq 17725) 'repeating-decimal average cannot round the total amount'
# Preserve calculation chronology when a different order fills between partial buys.
$middle=Fill 'middle-sell' 'sell-c' 5 6300 '100000002'
$last=Fill 'last-buy' 'buy-a' 1 5000 '100000003'
$interleaved=Catalog @($a,$middle,$last)
$detail=Sheet-JournalDetailedRows (LegacyRows $interleaved) $interleaved
$originalAsset=Asset-Ledger (LegacyRows $interleaved);$detailAsset=Asset-Ledger $detail
Check ($detailAsset.Gross -eq $originalAsset.Gross -and $detailAsset.Average -eq $originalAsset.Average -and $detailAsset.Qty -eq $originalAsset.Qty) 'interleaved buy and sell profit remains based on original fill chronology'
$interPlan=Sheet-JournalPlan $interleaved (LegacyRows $interleaved) $layout
Load-Rows (LegacyRows $interleaved);Apply-Batch $interPlan.Requests
$afterAsset=Asset-Ledger (Sheet-JournalDetailedRows $script:fakeRows.ToArray() $interleaved)
Check ($afterAsset.Gross -eq $originalAsset.Gross -and $afterAsset.Average -eq $originalAsset.Average) 'grouped sheet does not alter asset profit or remaining cost basis'
# The broker book object itself must never be changed by presentation functions.
$fills=@($a,$b,$c,$d);$before=$fills|ConvertTo-Json -Depth 12 -Compress;$null=Catalog $fills
Check (($fills|ConvertTo-Json -Depth 12 -Compress) -ceq $before) 'original fill records remain immutable'
$empty=Catalog @();$emptyPlan=Sheet-JournalPlan $empty @($manualHeader,$manual) $layout
Check ($emptyPlan.Requests.Count -eq 0 -and $emptyPlan.Count -eq 0) 'no automatic fills leaves a manual-only sheet unchanged'
$one=Catalog @($a);$onePlan=Sheet-JournalPlan $one @($manualHeader,$manual) $layout
Check ($onePlan.Missing.Count -eq 1 -and $onePlan.Rows[2][4] -eq 9) 'only filled quantity is shown while an order remainder is still open or cancelled'
# On the production engine, also exercise the real import and Windows protection.
if($env:OS -eq 'Windows_NT'){
 . (Join-Path $Root 'tests/CashFixture.ps1')
 $realDir=Join-Path ([IO.Path]::GetTempPath()) ('JournalImport-'+[guid]::NewGuid().ToString('N'))
 try{
  $f=Cash-Fixture $realDir;$rawBefore=Clone $f.Raw;$rawBefore.Day='20261105';$rawBefore.Ledger=$view.Rows
  $rawAfter=Clone $rawBefore;$rawAfter.Ledger=$filtered.Rows
  Check ((At58S-Import $rawBefore).Hash -ceq (At58S-Import $rawAfter).Hash) 'real strategy import preserves the baseline hash across migration'
  $backupPath=Join-Path $realDir 'journal-backup.dpapi'
  Asset-ProtectedWrite $backupPath 'AT58-JOURNAL-BACKUP-1' @{Schema='AT-JOURNAL-BACKUP-1';Rows=$legacy;Formula=(Sheet-JournalFormula $false)}
  $saved=Asset-ProtectedRead $backupPath 'AT58-JOURNAL-BACKUP-1'
  $sameCells=Same-Cells $legacy $saved.Rows
  if(!$sameCells){Write-Output ('SYNTHETIC BACKUP BEFORE '+(@{Rows=$legacy}|ConvertTo-Json -Depth 10 -Compress));Write-Output ('SYNTHETIC BACKUP AFTER '+($saved|ConvertTo-Json -Depth 10 -Compress))}
  Check ($sameCells -and (At58S-Cell $saved.Rows 2 6) -ceq $legacy[2][6] -and $saved.Formula -ceq (Sheet-JournalFormula $false) -and [IO.File]::ReadAllText($backupPath) -notmatch '매수|ATF1') 'Windows encrypted backup round-trips the full original journal'
 }finally{if(Test-Path -LiteralPath $realDir){Remove-Item -LiteralPath $realDir -Recurse -Force}}
}
# Full sync with synthetic network, baseline import, and encrypted backup writer.
$script:networkPosts=0;$script:backups=0;$script:hostStatus=@{Version='58.17.8';State='CURRENT'};$script:failBackup=$false;$script:timeoutAfterCommit=$false;$script:breakReadback=$false
function At58S-Import($raw){[pscustomobject]@{Hash=(At58-Hash (Baseline-Identity $raw.Ledger))}}
function Asset-ProtectedWrite($path,$purpose,$value){if($script:failBackup){throw 'SYNTHETIC_BACKUP_FAILURE'};if($purpose -cne 'AT58-JOURNAL-BACKUP-1' -or $value.Schema -cne 'AT-JOURNAL-BACKUP-1'){throw 'BACKUP_IDENTITY'};$script:backups++}
function Ops-ReadJson($path){return $script:hostStatus}
function Ops-WriteJson($path,$value){$script:lastStatus=$value}
function Invoke-RestMethod {
 param($Method,$Uri,$Headers,$Body,$ContentType,$TimeoutSec,$MaximumRedirection,$ErrorAction)
 if($Method -ceq 'Get'){
  if($Uri -match 'valueRenderOption=FORMULA'){return @{values=,@($script:fakeFormula)}}
  if($script:breakReadback -and $script:networkPosts -gt 0){$broken=Clone $script:fakeRows.ToArray();$broken[2][5]=1;return @{values=$broken}}
  return @{values=$script:fakeRows.ToArray()}
 }
 if($Method -cne 'Post' -or !$Uri.EndsWith(':batchUpdate')){throw 'UNEXPECTED_NETWORK'}
 $script:networkPosts++;$parsed=[Text.Encoding]::UTF8.GetString($Body)|ConvertFrom-Json
 # Convert nested objects to hashtables for the synthetic batch executor on PS5.1.
 function Hashify($v){if($null -eq $v){return $null};if($v -is [pscustomobject]){$h=@{};foreach($p in $v.PSObject.Properties){$h[$p.Name]=Hashify $p.Value};return $h};if($v -is [array]){$a=@();foreach($x in $v){$a+=,(Hashify $x)};return ,$a};return $v}
 $payload=Hashify $parsed;Apply-Batch $payload.requests | Out-Null
 if($script:timeoutAfterCommit){$script:timeoutAfterCommit=$false;throw 'SYNTHETIC_TIMEOUT_AFTER_COMMIT'}
 return @{spreadsheetId='SYNTHETIC_JOURNAL_ONLY'}
}
function Input-For($rows,$catalog){$raw=[pscustomobject]@{Ledger=(Sheet-JournalFilter $rows $catalog).Rows};$source=At58S-Import $raw;$script:state.SourceHash=$source.Hash;[pscustomobject]@{Source=$source;Raw=$raw;Ledger=$rows}}
function Meta([int]$cols=7){Clone @{sheets=@(@{properties=@{title='매매일지';sheetId=1136811970;gridProperties=@{rowCount=1000;columnCount=$cols}}})}}
$script:At58SheetId='SYNTHETIC_JOURNAL_ONLY';$temp=Join-Path ([IO.Path]::GetTempPath()) ('JournalGrouping-'+[guid]::NewGuid().ToString('N'))
Load-Rows $legacy;$inputData=Input-For $legacy $cat
$result=Sheet-JournalSync @{} 'https://synthetic.invalid' (Meta) $inputData $cat $temp
Check ($result.Total -eq 2 -and $result.FillCount -eq 4 -and $result.Pending -eq 0 -and $script:networkPosts -eq 1 -and $script:backups -eq 2) 'full sync backs up then commits and verifies the grouped journal'
Check ($inputData.Ledger.Count -eq 6 -and (Asset-Ledger $inputData.Ledger).Qty -eq 46) 'asset input is expanded to original fills after successful sync'
$inputData=Input-For $script:fakeRows.ToArray() $cat
$null=Sheet-JournalSync @{} 'https://synthetic.invalid' (Meta 9) $inputData $cat $temp
Check ($script:networkPosts -eq 1) 'retry after successful sync sends no additional mutation'
Load-Rows $legacy;$inputData=Input-For $legacy $cat;$script:hostStatus.State='VERIFYING'
Reject {Sheet-JournalSync @{} 'https://synthetic.invalid' (Meta) $inputData $cat $temp} 'SHEET_JOURNAL_UPDATE_WAIT' 'schema migration waits until update verification is committed'
Check ($script:networkPosts -eq 1) 'uncommitted host cannot change the sheet'
$script:hostStatus.State='CURRENT';$script:failBackup=$true
Reject {Sheet-JournalSync @{} 'https://synthetic.invalid' (Meta) $inputData $cat $temp} 'SYNTHETIC_BACKUP_FAILURE' 'backup failure prevents the write'
Check ($script:networkPosts -eq 1) 'failed backup leaves sheet untouched'
$script:failBackup=$false;$script:fakeFormula='=1'
Reject {Sheet-JournalSync @{} 'https://synthetic.invalid' (Meta) $inputData $cat $temp} 'SHEET_JOURNAL_FORMULA' 'unrecognized amount formula is preserved and reported'
$script:fakeFormula=Sheet-JournalFormula $false;$script:timeoutAfterCommit=$true
Reject {Sheet-JournalSync @{} 'https://synthetic.invalid' (Meta) $inputData $cat $temp} 'SYNTHETIC_TIMEOUT_AFTER_COMMIT' 'ambiguous response is not treated as verified success'
$posts=$script:networkPosts;$inputData=Input-For $script:fakeRows.ToArray() $cat
$null=Sheet-JournalSync @{} 'https://synthetic.invalid' (Meta 9) $inputData $cat $temp
Check ($script:networkPosts -eq $posts -and $script:fakeRows.Count -eq 4) 'retry after lost response recognizes committed result without duplication'
Load-Rows $legacy;$inputData=Input-For $legacy $cat;$script:networkPosts=0;$script:breakReadback=$true
Reject {Sheet-JournalSync @{} 'https://synthetic.invalid' (Meta) $inputData $cat $temp} 'SHEET_JOURNAL_CHANGED' 'corrupt readback cannot report successful migration'
$script:breakReadback=$false
'JOURNAL GROUPING CHECKS PASSED: '+$script:checks
