param([string]$DataRoot,[string]$ManagementRoot,[string]$OutputRoot=$ManagementRoot,[string]$ConfigRoot=$ManagementRoot,[switch]$Diagnostics)

$ErrorActionPreference='Stop'

. (Join-Path $PSScriptRoot 'At58.Ops.ps1')

. (Join-Path $PSScriptRoot 'At58.Sheets.ps1')

. (Join-Path $PSScriptRoot 'At58.SheetsJwt.ps1')

if($Diagnostics){exit (SheetDiag-Run $DataRoot $ManagementRoot)}

. (Join-Path $PSScriptRoot 'payload/At58.Core.ps1')

$inputDiag=At58ID-StartRefresh $DataRoot

$code='SHEET_ERROR';$token='';$key=$null

try{

 At58ID-Refresh $inputDiag 'CONFIG'
 $cfg=Sheet-Config $ConfigRoot;if(!$cfg.Enabled){throw 'SHEET_DISABLED'};$code='SHEET_ID';$script:At58SheetId=Sheet-Id ([string](Ops-Get $cfg 'SheetId' ''))

 At58ID-Refresh $inputDiag 'SNAPSHOT'
 $s=(Sheet-Unprotect ([IO.File]::ReadAllText((Join-Path $DataRoot 'snapshot.dpapi'))) 'esbada-at-direct-v1')|ConvertFrom-Json

 At58ID-Refresh $inputDiag 'KEY'
 $code='SHEET_KEY';$raw=[IO.File]::ReadAllText($cfg.KeyPath);$key=$raw|ConvertFrom-Json;$fingerprint=Ops-Key $raw;$raw=$null

 if($key.type -cne 'service_account' -or $key.client_email -notmatch '^[^\s@]+@[^\s@]+\.gserviceaccount\.com$' -or !$key.private_key.StartsWith('-----BEGIN PRIVATE KEY-----')){throw 'SHEET_KEY'}

 $cache=Join-Path $OutputRoot 'sheets-token.dpapi';$saved=$null

 try{$saved=(Sheet-Unprotect ([IO.File]::ReadAllText($cache)) 'AT58-SHEET-TOKEN-1')|ConvertFrom-Json;if($saved.Key -ceq $fingerprint -and (Ops-Utc $saved.Until) -gt (Ops-Now).AddMinutes(2)){$token=$saved.Token}}catch{}

 if(!$token){

 At58ID-Refresh $inputDiag 'AUTH'
  $code='SHEET_AUTH';$epoch=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();$claims=@{iss=$key.client_email;scope='https://www.googleapis.com/auth/spreadsheets';aud='https://oauth2.googleapis.com/token';iat=$epoch;exp=($epoch+3600)}|ConvertTo-Json -Compress

  $unsigned=[At58SheetsJwt]::B64([Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}'))+'.'+[At58SheetsJwt]::B64([Text.Encoding]::UTF8.GetBytes($claims));$jwt=[At58SheetsJwt]::Sign($unsigned,$key.private_key)

  $auth=Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/token' -ContentType 'application/x-www-form-urlencoded' -Body @{grant_type='urn:ietf:params:oauth:grant-type:jwt-bearer';assertion=$jwt} -TimeoutSec 10 -MaximumRedirection 0

  if(!$auth.access_token -or [int]$auth.expires_in -le 120){throw 'SHEET_AUTH'};$token=$auth.access_token

  Add-Type -AssemblyName System.Security;$plain=[Text.Encoding]::UTF8.GetBytes((@{Key=$fingerprint;Token=$token;Until=(Ops-Now).AddSeconds([int]$auth.expires_in-60).ToString('o')}|ConvertTo-Json -Compress))

  try{$cipher=[Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($plain,[Text.Encoding]::UTF8.GetBytes('AT58-SHEET-TOKEN-1'),[Security.Cryptography.DataProtectionScope]::CurrentUser));[void][IO.Directory]::CreateDirectory($OutputRoot);[IO.File]::WriteAllText($cache,$cipher,[Text.Encoding]::UTF8)}finally{[Array]::Clear($plain,0,$plain.Length)}

 }

 $headers=@{Authorization=('Bearer '+$token)};$base='https://sheets.googleapis.com/v4/spreadsheets/'+$script:At58SheetId

 At58ID-Refresh $inputDiag 'STRUCTURE'
 $code='SHEET_STRUCTURE';$meta=Invoke-RestMethod -Method Get -Uri ($base+'?fields=sheets(properties(sheetId,title,gridProperties(rowCount,columnCount)))') -Headers $headers -TimeoutSec 10 -MaximumRedirection 0

 foreach($item in @(@{Title='메인';Id=2026110201;Rows=28;Cols=13},@{Title='자동매매현황';Id=2026110101;Rows=30;Cols=8},@{Title='AT주문내역';Id=2026110102;Rows=1005;Cols=12})){

  $found=@($meta.sheets|Where-Object {$_.properties.title -ceq $item.Title});if($found.Count -ne 1 -or $found[0].properties.sheetId -ne $item.Id -or $found[0].properties.gridProperties.rowCount -lt $item.Rows -or $found[0].properties.gridProperties.columnCount -lt $item.Cols){throw 'SHEET_STRUCTURE'}

 }

 At58ID-Refresh $inputDiag 'JOURNAL_CONTEXT'
 $journal=Sheet-JournalContext $s $DataRoot;$journalInput=$null;$jr=$null
 if((Ops-Get $s 'StrategyEnabled' $false)){

  try{$journalInput=Sheet-StrategyInput $headers $base $meta $s $DataRoot $journal $inputDiag}catch{

   $strategyCode=(At58-Error $_).Code;if($strategyCode -ceq 'UNEXPECTED'){$strategyCode='STRATEGY_SHEET_READ'}

   Ops-WriteJson (Join-Path $DataRoot 'strategy-input-status.json') @{Utc=(Ops-Now).ToString('o');Code=$strategyCode}
   if($journal){throw}

  }

 }

 # Refresh input before presentation validation: stale/mixed-day display data
 # must not prevent the reader from obtaining today's input and reconciling again.
 At58ID-Refresh $inputDiag 'PRESENTATION'
 $body=Sheet-Build $s (Ops-ReadJson (Join-Path $DataRoot 'status.json')) (Ops-ReadJson (Join-Path $ManagementRoot 'manager-status.json'));Sheet-ValidatePayload $body

 if($journal){
 At58ID-Refresh $inputDiag 'JOURNAL'
  $code='SHEET_JOURNAL';if(!$journalInput){throw 'SHEET_JOURNAL_INPUT'}
  $jr=Sheet-JournalSync $headers $base $meta $journalInput $journal $OutputRoot
  $cell=(@($body.data|Where-Object range -ceq "'자동매매현황'!B23"))[0]
  $cell.values[0][0]+=' · 체결일지 '+$jr.Written+'건 반영'+$(if($jr.Pending){' / 남은 '+$jr.Pending+'건'}else{''})
 }
 At58ID-Refresh $inputDiag 'PUBLISH'
 $code='SHEET_SEND';$presentation=Sheet-PublishPresentation $headers $base $body $OutputRoot $s.Scope

 # Additional reporting has independent failure state and never blocks the normal journal/status update.
 At58ID-Refresh $inputDiag 'ASSET_REPORT'
 try{Asset-Pump $headers $base $meta $s $journalInput $DataRoot $OutputRoot}catch{try{Ops-WriteJson (Join-Path $OutputRoot 'assets-status.json') @{Utc=(Ops-Now).ToString('o');Code='ASSET_REPORT_RETRY'}}catch{}}

 At58ID-Refresh $inputDiag 'DONE'
 $code='OK';Ops-WriteJson (Join-Path $OutputRoot 'sheets-status.json') @{Code=$code;At=[TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Ops-Now),'Korea Standard Time').ToString('yyyy-MM-dd HH:mm:ss');Utc=(Ops-Now).ToString('o');SnapshotUtc=$s.CompletedUtc;Day=$s.Day;WrittenRanges=$presentation.WrittenRanges;SkippedRanges=$presentation.SkippedRanges;WrittenCells=$presentation.WrittenCells;FullRefresh=$presentation.FullRefresh;JournalReady=($null -ne $jr -and $jr.Code -ceq 'OK' -and $jr.Pending -eq 0)};exit 0

}catch{

 $failure=$_;At58ID-Refresh $inputDiag 'FAILED' $failure
 $errorType=$failure.Exception.GetType().Name;$network='';$http=0

 $e=$failure.Exception;for($i=0;$e -and $i -lt 5;$i++){try{if($e -is [Net.WebException]){$network=[string]$e.Status};if($e.Response){$http=[int]$e.Response.StatusCode}}catch{};$e=$e.InnerException}

 if($_.Exception.Message -cmatch '^SHEET_[A-Z_]{1,40}$'){$code=$_.Exception.Message}

 try{Ops-WriteJson (Join-Path $OutputRoot 'sheets-status.json') @{Code=$code;ErrorType=$errorType;Network=$network;Http=$http;At=[TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Ops-Now),'Korea Standard Time').ToString('yyyy-MM-dd HH:mm:ss');Utc=(Ops-Now).ToString('o')}}catch{};exit 1

}finally{$token='';$key=$null;$auth=$null;$headers=$null;$jwt=$null;$saved=$null}

