#requires -Version 5.1
param([string]$Root=$PSScriptRoot,[string]$CorePath='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if(!$CorePath){$CorePath=Join-Path $Root 'bundle/payload/At58.Core.ps1'}
. $CorePath
$script:checks=0
function Check($ok,[string]$name){if(!$ok){throw ('FAILED: '+$name)};$script:checks++;'PASS '+$name}
function Reject($action,[string]$code,[string]$name){$actual='';try{& $action|Out-Null}catch{$actual=(At58-Error $_).Code};Check ($actual -ceq $code) $name}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('avata-auth-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
function Fixture {
 $script:now=[datetime]::SpecifyKind([datetime]'2026-11-07T12:00:00',[DateTimeKind]::Utc)
 $script:calls=New-Object 'Collections.Generic.List[string]';$script:mode='expired';$script:issued=0;$script:rejected=0
 $ctx=At58-Context $testRoot '0210A0' ([pscustomobject]@{AppKey='fixture-only-key';AppSecret='fixture-only-secret'})
 $ctx.Clock={return $script:now};$ctx.NoWait=$true;$ctx.Mac='112233445566'
 $ctx.Transport={param($method,$path,$query,$body,$token)
  $script:calls.Add($method+' '+$path)
  if($path -ceq '/oauth2/token'){
   if($method -cne 'POST'){throw 'TEST_BAD_METHOD'};$script:issued++
   switch($script:mode){
    'issue-timeout' {At58-ApiFailure '' 0 $path 'Timeout'}
    'issue-network' {At58-ApiFailure '' 0 $path}
    'issue-rate' {At58-ApiFailure 'EGW00200' 500 $path}
    'credentials' {At58-ApiFailure 'EGW00103' 401 $path}
    'schema' {return [pscustomobject]@{access_token='bad';expires_in=20}}
   }
   return [pscustomobject]@{access_token=$(if($script:mode -ceq 'same-token'){'never-log-this-token'}else{'never-log-this-token-'+$script:issued});expires_in=3600}
  }
  if($method -cne 'GET' -or $path -cne '/accounts/v1/me/deposit'){throw 'TEST_ORDER_OR_UNEXPECTED_ROUTE'}
  if($script:mode -cin @('expired','same-token') -or ($script:mode -ceq 'once' -and $script:rejected -eq 0)){$script:rejected++;return [pscustomobject]@{rsp_cd='EGW00123';data=$null}}
  if($script:mode -ceq 'http-expired'){At58-ApiFailure 'EGW00123' 500 $path}
  return [pscustomobject]@{rsp_cd='0000';data=[pscustomobject]@{fixture=1};rsp_sub_msg=''}
 }
 return $ctx
}
function GetRead($ctx){At58-Get $ctx '/accounts/v1/me/deposit' @{}}
try{
 $c=Fixture
 Reject {GetRead $c} 'TOKEN_EXPIRED' 'persistent expired read has bounded immediate retry'
 Check ($script:calls.Count -eq 4 -and $script:issued -eq 2 -and !$c.Token) 'first failed cycle issues two tokens and clears rejected token'
 $before=$script:calls.Count;$script:now=$script:now.AddSeconds(5)
 Reject {GetRead $c} 'TOKEN_EXPIRED' 'next read retains original expiry code while waiting'
 Check ($script:calls.Count -eq $before) 'cross-cycle cooldown prevents further token or read requests'
 $script:now=$script:now.AddSeconds(25)
 Reject {GetRead $c} 'TOKEN_EXPIRED' 'recovery is retried at the first cooldown boundary'
 Check ($script:calls.Count -eq 8 -and (At58Auth-State $c).Failures -eq 2) 'failed recovery advances the shared cycle failure count'
 Check (((At58Auth-State $c).RetryUtc-$script:now).TotalSeconds -eq 60) 'second cooldown is sixty seconds'
 foreach($expected in @(120,300,300)){
  $script:now=(At58Auth-State $c).RetryUtc
  Reject {GetRead $c} 'TOKEN_EXPIRED' 'persistent authentication remains bounded'
  Check (((At58Auth-State $c).RetryUtc-$script:now).TotalSeconds -eq $expected) ('cooldown progression '+$expected)
 }
 $before=$script:calls.Count
 Reject {At58-Token $c} 'TOKEN_EXPIRED' 'direct token caller cannot bypass cooldown'
 Check ($script:calls.Count -eq $before) 'trade auth preflight makes no token or order request during cooldown'
 $script:now=(At58Auth-State $c).RetryUtc;$script:mode='normal';$null=GetRead $c
 Check ((At58Auth-State $c).Failures -eq 0 -and (At58Auth-State $c).RetryUtc -eq [datetime]::MinValue) 'authenticated GET success resets failure count and cooldown'
 $before=$script:calls.Count;$null=GetRead $c
 Check ($script:calls.Count -eq $before+1) 'healthy token reused after recovery'
 $script:mode='expired';Reject {GetRead $c} 'TOKEN_EXPIRED' 'a new independent auth incident is retained'
 Check (((At58Auth-State $c).RetryUtc-$script:now).TotalSeconds -eq 30) 'successful recovery resets next incident to thirty seconds'
 $c=Fixture;$script:mode='once';$null=GetRead $c
 Check ($script:calls.Count -eq 4 -and $script:issued -eq 2 -and (At58Auth-State $c).Failures -eq 0) 'single transient expiry refreshes immediately and succeeds without cooldown'
 foreach($case in @(@('issue-timeout','TIMEOUT'),@('issue-network','NETWORK'),@('issue-rate','RATE_LIMIT'),@('credentials','CREDENTIAL_INVALID'),@('schema','TOKEN_SCHEMA'))){
  $c=Fixture;$script:mode=$case[0]
  Reject {GetRead $c} $case[1] ('issuance failure classification '+$case[0])
  Check ($script:calls.Count -eq 1 -and !$c.Token) 'failed issuance is not repeated immediately'
  $script:now=$script:now.AddSeconds(5);Reject {GetRead $c} $case[1] 'issuance cooldown preserves failure code'
  Check ($script:calls.Count -eq 1) 'issuance recovery waits across cycles'
 }
 $c=Fixture;$script:mode='same-token';Reject {GetRead $c} 'TOKEN_EXPIRED' 'broker returning the rejected token remains a failure'
 $events=@(Get-Content -LiteralPath (Join-Path $testRoot 'auth-reader-20261107.jsonl')|ForEach-Object {$_|ConvertFrom-Json})
 Check (@($events|Where-Object {$_.Event -ceq 'TOKEN_ISSUED' -and $_.SameRejectedToken -eq $true}).Count -gt 0) 'reissued rejected token is diagnosed as a boolean only'
 Check (@($events|Where-Object {$_.Event -ceq 'TOKEN_ISSUED' -and $_.TokenComparisonKnown -eq $true -and $_.SameRejectedToken -eq $false}).Count -gt 0) 'known different token is distinct from absent comparison'
 Check (@($events|Where-Object {$_.Event -ceq 'TOKEN_ISSUED' -and $_.TokenComparisonKnown -eq $false}).Count -gt 0) 'first issuance has no fabricated token comparison'
 $waitCount=@($events|Where-Object Event -ceq 'AUTH_RETRY_WAIT').Count
 1..5|ForEach-Object {try{GetRead $c|Out-Null}catch{}}
 $after=@(Get-Content -LiteralPath (Join-Path $testRoot 'auth-reader-20261107.jsonl')|ForEach-Object {$_|ConvertFrom-Json})
 Check (@($after|Where-Object Event -ceq 'AUTH_RETRY_WAIT').Count -eq $waitCount) 'cooldown is logged once instead of every blocked poll'
 $script:now=(At58Auth-State $c).RetryUtc;$script:mode='issue-timeout'
 Reject {GetRead $c} 'TIMEOUT' 'failed issuance after same-token rejection remains a timeout'
 $status=Get-Content -LiteralPath (Join-Path $testRoot 'auth-reader-status.json') -Raw|ConvertFrom-Json
 Check (!$status.TokenComparisonKnown -and !$status.SameRejectedToken -and $status.TokenAgeSeconds -eq -1) 'failed issuance cannot claim a known token comparison or new token age'
 $c.Token='never-log-this-token';$c.TokenUntil=$script:now.AddHours(1);$a=At58Auth-State $c;$a.RetryUtc=[datetime]::MinValue;$a.SameRejectedToken=$true;$a.TokenComparisonKnown=$true;$script:mode='normal';$null=GetRead $c
 $status=Get-Content -LiteralPath (Join-Path $testRoot 'auth-reader-status.json') -Raw|ConvertFrom-Json
 Check ($status.Event -ceq 'AUTH_RECOVERED' -and !$status.TokenComparisonKnown -and !$status.SameRejectedToken) 'recovery does not fabricate a changed-token comparison'
 Check (@($events|Where-Object {$_.Event -ceq 'TOKEN_REJECTED' -and $_.Http -eq 200 -and $_.ApiCode -ceq 'EGW00123'}).Count -gt 0) 'HTTP 200 auth rejection retains safe response metadata'
 $c=Fixture;$script:mode='http-expired';Reject {GetRead $c} 'TOKEN_EXPIRED' 'HTTP 500 authentication rejection follows same recovery path'
 $status=Get-Content -LiteralPath (Join-Path $testRoot 'auth-reader-status.json') -Raw|ConvertFrom-Json
 Check ($status.Http -eq 500 -and $status.ApiCode -ceq 'EGW00123' -and $status.RetrySeconds -eq 30) 'status retains HTTP failure and next retry deadline'
 $raw=Get-Content -LiteralPath (Join-Path $testRoot 'auth-reader-20261107.jsonl') -Raw
 Check ($raw -notmatch 'never-log-this-token|fixture-only-key|fixture-only-secret|112233445566|Authorization|AppKey|AppSecret|TokenHash') 'authentication evidence excludes credentials tokens MAC and token fingerprints'
 $c=Fixture;$c.AuthRole='ASSET';Reject {GetRead $c} 'TOKEN_EXPIRED' 'asset authentication has its own recovery role'
 $saved=At58Auth-ExportRecovery $c;$savedJson=$saved|ConvertTo-Json -Compress
 Check ($savedJson -notmatch 'never-log-this-token|fixture-only-secret|RejectedToken|IssuedUtc') 'exported recovery metadata does not store a token or rejected token'
 $replacement=At58-Context $testRoot '0210A0' ([pscustomobject]@{AppKey='fixture-only-key';AppSecret='fixture-only-secret'});$replacement.AuthRole='ASSET';$replacement.Clock=$c.Clock;$replacement.Transport=$c.Transport;$replacement.NoWait=$true;$replacement.Mac=$c.Mac
 At58Auth-ImportRecovery $replacement ($savedJson|ConvertFrom-Json)
 $before=$script:calls.Count;Reject {GetRead $replacement} 'TOKEN_EXPIRED' 'replacement asset worker restores cooldown before any REST'
 Check ($script:calls.Count -eq $before) 'replacement asset process cannot reset issuance limit'
 Check ((Test-Path (Join-Path $testRoot 'auth-asset-status.json')) -and (Test-Path (Join-Path $testRoot 'auth-asset-20261107.jsonl'))) 'asset evidence uses separate files from reader evidence'
 $wrong=Fixture;$wrong.AuthRole='READER';At58Auth-ImportRecovery $wrong $saved
 Check ((At58Auth-State $wrong).Failures -eq 0) 'different role cannot import another recovery state'
 $wrong.AuthRole='ASSET';$saved.Scope='different';At58Auth-ImportRecovery $wrong $saved
 Check ((At58Auth-State $wrong).Failures -eq 0) 'different account scope cannot import recovery state'
 $c=Fixture;$clone=At58X-Context $c;$script:mode='issue-timeout'
 Reject {At58-Token $clone} 'TIMEOUT' 'trade context auth preflight records issuance failure'
 Check ((Test-Path (Join-Path $testRoot 'auth-reader-status.json')) -and !(Test-Path (Join-Path $clone.Root 'auth-reader-status.json'))) 'trade context auth evidence remains in reader diagnostic root'
 Check ((At58Auth-State $clone).Failures -eq 1) 'trade context schedules auth cooldown without an order'
 $c=Fixture;$script:mode='normal';$c.Root=Join-Path $testRoot 'not-a-directory';$c.AuthDiagnosticRoot=$c.Root;[IO.File]::WriteAllText($c.Root,'fixture')
 $null=GetRead $c;Check ($script:calls.Count -eq 2 -and $c.Token) 'diagnostic storage failure cannot turn successful broker read into failure'
 Check (@($script:calls|Where-Object {$_ -like 'POST *' -and $_ -cne 'POST /oauth2/token'}).Count -eq 0) 'test makes no broker order POST or revoke'
 'AUTH RECOVERY TESTS COMPLETE: '+$script:checks+' passed; synthetic transport only.'
}finally{if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}}
