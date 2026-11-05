$ErrorActionPreference='Stop'

function Ops-SharingViolation($errorRecord){
 $e=$errorRecord.Exception
 while($e -and $e.InnerException){$e=$e.InnerException}
 return ($e -is [IO.IOException] -and ($e.HResult -band 65535) -in @(32,33))
}

function Ops-WriteBytes([string]$path,[byte[]]$bytes){
 [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path)))
 $temp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 try{
  [IO.File]::WriteAllBytes($temp,$bytes)
  # Readers such as antivirus or the log relay may briefly omit FileShare.Delete.
  # Retry only sharing/lock violations. Never turn permission or disk errors into success.
  $delays=@(20,40,80,160,320,400)
  for($attempt=0;;$attempt++){
   try{
    if([IO.File]::Exists($path)){[IO.File]::Replace($temp,$path,[Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temp,$path)}
    return
   }catch{
    if($attempt -ge $delays.Count -or !(Ops-SharingViolation $_)){throw}
    Start-Sleep -Milliseconds $delays[$attempt]
   }
  }
 }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}

function Ops-WriteJson([string]$path,$value){
 Ops-WriteBytes $path ([Text.UTF8Encoding]::new($false).GetBytes(($value|ConvertTo-Json -Depth 12 -Compress)))
}

function Ops-ReadJson([string]$path){

 for($attempt=0;$attempt -lt 3;$attempt++){

  $stream=$null;$reader=$null

  try{$stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete));$reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8);return ($reader.ReadToEnd()|ConvertFrom-Json)}catch{if($attempt -lt 2){Start-Sleep -Milliseconds 10}}finally{if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}

 }

 return $null

}

function Ops-Get($o,[string]$name,$default=$null){if($null -ne $o -and $o.PSObject.Properties[$name]){return $o.$name};return $default}

function Ops-Now {return [datetime]::UtcNow}

function Ops-Utc($value){if($value -is [datetime]){return $value.ToUniversalTime()};return [datetimeoffset]::Parse([string]$value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime}

function Ops-NativePaths {

 if('At58PathTags' -as [type]){return}

 Add-Type -TypeDefinition @'

using System;

using System.ComponentModel;

using System.Runtime.InteropServices;

public static class At58PathTags {

 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]

 struct FindData {

  public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation,Access,Write;

  public uint SizeHigh,SizeLow,Tag,Reserved;

  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=260)] public string Name;

  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=14)] public string Alternate;

 }

 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]

 static extern IntPtr FindFirstFileW(string name,out FindData data);

 [DllImport("kernel32.dll", SetLastError=true)] static extern bool FindClose(IntPtr handle);

 public static uint Tag(string path) {

  FindData d; IntPtr h=FindFirstFileW(path.TrimEnd('\\'),out d);

  if(h==new IntPtr(-1))throw new Win32Exception(Marshal.GetLastWin32Error());

  try{return (d.Attributes & 0x400)!=0 ? d.Tag : 0;}finally{FindClose(h);}

 }

 public static bool Cloud(uint tag){return (tag & 0xffff0fffU)==0x9000001aU;}

}

'@

}

function Ops-IsCloudTag([uint32]$tag){Ops-NativePaths;return [At58PathTags]::Cloud($tag)}

function Ops-ReparseTag([string]$path){Ops-NativePaths;return [At58PathTags]::Tag($path)}

function Ops-Inside([string]$root,[string]$path){

 $r=[IO.Path]::GetFullPath($root).TrimEnd('\')+'\';$p=[IO.Path]::GetFullPath($path)

 if(!$p.StartsWith($r,[StringComparison]::OrdinalIgnoreCase)){throw 'PATH_OUTSIDE_ROOT'}

 $check=$p

 while($check -and $check.Length -ge $r.TrimEnd('\').Length){if(Test-Path -LiteralPath $check){if((Get-Item -LiteralPath $check -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){if(!(Ops-IsCloudTag (Ops-ReparseTag $check))){throw 'REPARSE_PATH'}}};$check=[IO.Path]::GetDirectoryName($check)}

 return $p

}

function Ops-ReleasePath([string]$root,[string]$id){if($id -cnotmatch '^[a-z0-9-]{1,80}$'){throw 'RELEASE_ID'};return (Ops-Inside $root (Join-Path $root ('releases\'+$id)))}

function Ops-Event([string]$root,[string]$code,[string]$incident='',[string]$detail=''){

 if($code -cnotmatch '^[A-Z0-9_]{1,60}$' -or $incident -cnotmatch '^[a-f0-9-]{0,36}$'){throw 'EVENT_FORMAT'}

 $now=Ops-Now;$kst=[TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($now,'Korea Standard Time')

 $record=[ordered]@{Utc=$now.ToString('o');At=$kst.ToString('yyyy-MM-dd HH:mm:ss');Code=$code;Incident=$incident}
 # Store only bounded diagnostic identifiers, never message text or credentials.
 if($detail -cmatch '^[A-Z][A-Z0-9_]{0,59}( [A-Z][A-Z0-9_]{0,59})?$'){$parts=$detail.Split(' ');$record.Stage=$parts[-1];if($parts.Count -eq 2){$record.State=$parts[0]}}

 [void][IO.Directory]::CreateDirectory($root)

 [IO.File]::AppendAllText((Join-Path $root ('manager-'+$kst.ToString('yyyyMMdd')+'.jsonl')),(($record|ConvertTo-Json -Compress)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))

}

function Ops-Classify($runtime,$status,[string]$runId,[datetime]$started,[bool]$exited,[datetime]$now){

 $rValid=$runtime -and (Ops-Get $runtime 'RunId') -ceq $runId

 if($rValid -and (Ops-Get $runtime 'ExitReason') -ceq 'USER_CLOSE'){return 'USER_CLOSE'}

 if($exited){return 'PROCESS_EXIT'}

 if(($now-$started).TotalSeconds -lt 45){return 'STARTING'}

 if(!$rValid){return 'NO_HEARTBEAT'}

 try{$age=($now-(Ops-Utc (Ops-Get $runtime 'Utc'))).TotalSeconds}catch{return 'NO_HEARTBEAT'}

 if($age -lt -5 -or $age -gt 30){return 'NO_HEARTBEAT'}

 if(!(Ops-Get $runtime 'DesiredRunning' $false)){return 'PAUSED'}

 if((Ops-Get $runtime 'Fault' '') -cne ''){return 'APP_FAULT'}

 $sValid=$status -and (Ops-Get $status 'RunId') -ceq $runId

 if(!$sValid){if(($now-$started).TotalSeconds -gt 120){return 'NO_RESULT'};return 'STARTING'}

 try{$sAge=($now-(Ops-Utc (Ops-Get $status 'Utc'))).TotalSeconds}catch{return 'STATUS_INVALID'}

 if(Ops-Get $status 'Live'){try{$null=Ops-LiveStatus $runtime $status $runId $now}catch{return 'READONLY_GUARD'}}elseif((Ops-Get $status 'ExecutionEnabled' $true) -ne $false -or (Ops-Get $status 'OrdersSent' -1) -ne 0){return 'READONLY_GUARD'}

 if($sAge -gt 390 -or $sAge -lt -5){return 'RESULT_STALE'}

 if((Ops-Get $status 'Code') -ceq 'LIVE_ROLLOVER_WAIT' -and (Ops-RolloverState (Ops-Get $status 'Live') $runId $now) -ceq 'WAIT'){return 'ROLLOVER_WAIT'}

 if((Ops-Get $status 'Code') -ceq 'OK'){return 'HEALTHY'}

 if([int](Ops-Get $status 'Failures' 0) -ge 3){return 'PERSISTENT_ERROR'}

 return 'RETRYING'

}

function Ops-SafeIncident($runtime,$status,[string]$classification){

 $code=[string](Ops-Get $status 'Code' 'UNKNOWN');if($code -cnotmatch '^[A-Z0-9_]{1,40}$'){$code='UNKNOWN'}

 $api=[string](Ops-Get $status 'ApiCode' '');if($api -cnotmatch '^(?:(?:EGW|IGW)[0-9]{5}|[0-9]{4,5})?$'){$api=''}

 $stage=[string](Ops-Get $status 'Stage' 'UNKNOWN');if($stage -cnotmatch '^[a-zA-Z0-9_/-]{1,100}$'){$stage='UNKNOWN'}

 $fault=[string](Ops-Get $runtime 'Fault' '');if($fault -cnotmatch '^[A-Z0-9_]{0,40}$'){$fault='UNKNOWN'}

 return [pscustomobject]@{Schema='AT58-INCIDENT-1';Id=[guid]::NewGuid().ToString();Utc=(Ops-Now).ToString('o');Classification=$classification;Code=$code;ApiCode=$api;Stage=$stage;Fault=$fault;ExecutionEnabled=[bool](Ops-Get $status 'ExecutionEnabled' $false)}

}

function Ops-StartProcess([string]$exe,[string[]]$arguments,[string]$working,[string]$stdin=''){

 # Windows command-line quoting; never construct a shell command from logs or AI output.

 $quoted=@(foreach($arg in $arguments){'"'+[regex]::Replace([regex]::Replace($arg,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'})

 $si=[Diagnostics.ProcessStartInfo]::new();$si.FileName=$exe;$si.Arguments=$quoted -join ' ';$si.WorkingDirectory=$working;$si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.WindowStyle='Hidden'

 $si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true

 $p=[Diagnostics.Process]::new();$p.StartInfo=$si;[void]$p.Start()

 $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();$p.StandardInput.Write($stdin);$p.StandardInput.Close()

 return [pscustomobject]@{Process=$p;Output=$out;Error=$err;Started=(Ops-Now)}

}

function Ops-FindCodex {

 $cmd=Get-Command codex.exe -ErrorAction SilentlyContinue;if($cmd){return $cmd.Source}

 $paths=@();if($env:CODEX_ELECTRON_RESOURCES_PATH){$paths+=Join-Path $env:CODEX_ELECTRON_RESOURCES_PATH 'codex.exe'}

 $paths+=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\OpenAI\Codex\bin\codex.exe'

 foreach($p in $paths){if([IO.File]::Exists($p)){return $p}}

 try{$pkg=Get-AppxPackage -Name OpenAI.Codex -ErrorAction Stop|Select-Object -First 1;if($pkg){$p=Join-Path $pkg.InstallLocation 'app\resources\codex.exe';if([IO.File]::Exists($p)){return $p}}}catch{}

 return ''

}

function Ops-Hash([string]$path){return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}

function Ops-ValidateCore([string]$baseline,[string]$candidate){

 # Automatic deployment may change only pure response conversion functions.

 $allowed=@('At58-Object','At58-Session','At58-Holdings','At58-Orders','At58-Number','At58-Day','At58-Hour','At58-Symbol')

 $asts=@();foreach($p in @($baseline,$candidate)){$tok=$null;$err=$null;$a=[Management.Automation.Language.Parser]::ParseFile($p,[ref]$tok,[ref]$err);if($err.Count){throw 'PATCH_PARSE'};$asts+=,$a}

 $functions=@();$outside=@()

 foreach($a in $asts){$map=@{};$other=@();foreach($s in $a.EndBlock.Statements){if($s -is [Management.Automation.Language.FunctionDefinitionAst]){if($map.ContainsKey($s.Name)){throw 'PATCH_DUPLICATE'};$map[$s.Name]=$s}else{$other+=$s.Extent.Text}};$functions+=,$map;$outside+=,($other -join "`n")}

 $skeletons=@()

 for($i=0;$i -lt 2;$i++){

  $text=[IO.File]::ReadAllText(@($baseline,$candidate)[$i],[Text.Encoding]::UTF8)

  foreach($function in @($functions[$i].Values|Sort-Object {$_.Extent.StartOffset} -Descending)){$e=$function.Extent;$text=$text.Remove($e.StartOffset,$e.EndOffset-$e.StartOffset).Insert($e.StartOffset,('@FUNCTION:'+ $function.Name+'@'))}

  $skeletons+=,$text

 }

 if($skeletons[0] -cne $skeletons[1]){throw 'PATCH_OUTSIDE_FUNCTION'}

 if($outside[0] -cne $outside[1] -or (($functions[0].Keys|Sort-Object)-join '|') -cne (($functions[1].Keys|Sort-Object)-join '|')){throw 'PATCH_SCOPE'}

 $changes=@()

 foreach($name in $functions[0].Keys){

  $old=$functions[0][$name];$new=$functions[1][$name];if($old.Extent.Text -ceq $new.Extent.Text){continue}

  if($name -cnotin $allowed){throw 'PATCH_SCOPE'};$changes+=$name

  $baselineCalls=@($old.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object {$_.Extent.Text})

  foreach($node in $new.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true)){

   $command=$node.GetCommandName();if(!$command){throw 'PATCH_DYNAMIC_COMMAND'}

   if($command -cnotin @('At58-Value','At58-Fail','At58-Object','At58-Day','At58-Hour','At58-Number','At58-Text','At58-Symbol','At58-Hash','ConvertTo-Json')){if($node.Extent.Text -cnotin $baselineCalls){throw 'PATCH_COMMAND'}}

  }

  $types=@($old.FindAll({param($n)$n -is [Management.Automation.Language.TypeConstraintAst] -or $n -is [Management.Automation.Language.TypeExpressionAst]},$true)|ForEach-Object {$_.Extent.Text})

  foreach($node in $new.FindAll({param($n)$n -is [Management.Automation.Language.TypeConstraintAst] -or $n -is [Management.Automation.Language.TypeExpressionAst]},$true)){if($node.Extent.Text -cnotin $types){throw 'PATCH_TYPE'}}

  $variables=@('null','true','false')+@($old.FindAll({param($n)$n -is [Management.Automation.Language.VariableExpressionAst]},$true)|ForEach-Object {$_.VariablePath.UserPath})

  foreach($node in $new.FindAll({param($n)$n -is [Management.Automation.Language.VariableExpressionAst]},$true)){if($node.VariablePath.UserPath -match ':'){throw 'PATCH_SCOPE_VARIABLE'};if($node.VariablePath.UserPath -cnotin $variables){throw 'PATCH_VARIABLE'}}

  $methods=@($old.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst]},$true)|ForEach-Object {if($_.Member -isnot [Management.Automation.Language.StringConstantExpressionAst]){throw 'BASELINE_DYNAMIC'};$_.Member.Value})

  foreach($node in $new.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst]},$true)){if($node.Member -isnot [Management.Automation.Language.StringConstantExpressionAst] -or $node.Member.Value -cnotin $methods){throw 'PATCH_METHOD'}}

  if($new.FindAll({param($n)$n -is [Management.Automation.Language.RedirectionAst] -or $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true).Count -gt 1){throw 'PATCH_NESTED_OR_REDIRECTION'}

 }

 if(!$changes.Count){throw 'PATCH_EMPTY'}

 return ,$changes

}

function Ops-NewTransaction([string]$active,[string]$candidate,[string]$incident){return [pscustomobject]@{Previous=$active;Candidate=$candidate;Incident=$incident;Phase='PENDING';CreatedUtc=(Ops-Now).ToString('o')}}

function Ops-RecoveryRelease($pointer,$transaction){if($transaction -and (Ops-Get $transaction 'Phase') -ceq 'PENDING'){return [string]$transaction.Previous};return [string]$pointer.Active}

function Ops-Ready($status,[string]$runId,[datetime]$started){if(Ops-Get $status 'Live'){$l=$status.Live;return ($status.RunId -ceq $runId -and $status.Code -ceq 'OK' -and $status.Sequence -ge 3 -and (Ops-Utc $status.Utc) -gt $started -and $l.Schema -ceq 'AT-LIVE-STATUS-1' -and $l.RunId -ceq $runId -and !$l.TestOnly -and $l.State -ceq 'DISARMED' -and !$l.ExecutionEnabled -and !$l.OpenOrders -and !$l.UncertainOrders -and $l.Reconciled -and $l.Confirmations -ge 2)};return ($status -and (Ops-Get $status 'RunId') -ceq $runId -and (Ops-Get $status 'Code') -ceq 'OK' -and [int](Ops-Get $status 'Sequence' 0) -ge 3 -and (Ops-Utc (Ops-Get $status 'Utc')) -gt $started -and (Ops-Get $status 'ExecutionEnabled' $true) -eq $false -and (Ops-Get $status 'OrdersSent' -1) -eq 0)}

function Ops-CanRepair($attempts,[datetime]$now){$recent=@($attempts|Where-Object {($now-(Ops-Utc $_)).TotalHours -lt 24});return ($recent.Count -lt 3 -and @($recent|Where-Object {($now-(Ops-Utc $_)).TotalHours -lt 1}).Count -eq 0)}

function Ops-CanRestart($attempts,[datetime]$now){return (@($attempts|Where-Object {($now-(Ops-Utc $_)).TotalMinutes -lt 30}).Count -lt 3 -and @($attempts|Where-Object {($now-(Ops-Utc $_)).TotalHours -lt 24}).Count -lt 10)}

function Ops-Key([string]$text){$h=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}}

function Ops-StopOwned($child,[string]$root,[string]$runId){

 if(!$child -or $child.Process.HasExited){return}

 Ops-WriteJson (Join-Path $root 'stop.request.json') @{RunId=$runId;Action='RESTART'}

 if(!$child.Process.WaitForExit(20000)){$latest=Ops-ReadJson (Join-Path $root 'runtime.json');if((Ops-Get $latest 'LiveMode' '') -ceq 'LIVE'){throw 'LIVE_STOP_TIMEOUT'};$child.Process.Kill();if(!$child.Process.WaitForExit(5000)){throw 'OWNED_PROCESS_STOP_FAILED'}}

}



function Ops-ReceiptAlert($watch,$status,[string]$runId,[bool]$desired,[datetime]$now){

 if(!$watch.ContainsKey('RunId') -or $watch.RunId -cne $runId -or !$desired){$watch.Clear();$watch.RunId=$runId;$watch.Since=$now;$watch.Notified=$false;if(!$desired){return $null}}

 $code='FEED_STATUS_MISSING';$healthy=$false

 if($status -and (Ops-Get $status 'RunId') -ceq $runId){

  try{

   $age=($now-(Ops-Utc (Ops-Get $status 'Utc'))).TotalSeconds

   if($age -ge -5 -and $age -le 90 -and (Ops-Get $status 'Mode') -ceq 'OBSERVE' -and (Ops-Get $status 'ExecutionEnabled' $true) -eq $false -and (Ops-Get $status 'OrdersSent' -1) -eq 0){

    $candidate=[string](Ops-Get $status 'Code');if($candidate -cmatch '^[A-Z0-9_]{1,40}$'){$code=$candidate}

    $healthy=$code -ceq 'LISTENING' -and (Ops-Get $status 'Connected' $false)

   }

  }catch{}

 }

 if($healthy){$notice=$watch.Notified;$watch.Since=$now;$watch.Notified=$false;if($notice){return [pscustomobject]@{Event='FEED_RECOVERED';Code='LISTENING'}};return $null}

 if(!$watch.Notified -and ($now-$watch.Since).TotalSeconds -ge 300){$watch.Notified=$true;return [pscustomobject]@{Event='FEED_FAULT';Code=$code}}

 return $null

}



function Ops-SimulationAlert($watch,$status,[string]$runId,[bool]$desired,[datetime]$now,$runtime=$null){
 # A live session does not run the simulated chain. Its old status is not an incident.
 # Match the owned run so a previous process cannot suppress a paper-mode fault.
 if($runtime -and (Ops-Get $runtime 'RunId') -ceq $runId -and (Ops-Get $runtime 'LiveMode') -ceq 'LIVE'){
  $watch.Clear();return $null
 }


 $adapted=$null

 if($status -and (Ops-Get $status 'Mode') -ceq 'SIMULATED_CHAIN'){

  $code=[string](Ops-Get $status 'Code')

  $normal=$code -cin @('SIM_ORDER','SIM_WAIT','SIM_DUPLICATE','SIM_RECONCILE_WAIT','SIM_CANCEL','MARKET_CLOSED','PRE_CLOSE','SIM_MARKET_WAIT','SIM_PARTIAL_WAIT')

  $adapted=[pscustomobject]@{RunId=(Ops-Get $status 'RunId');Utc=(Ops-Get $status 'Utc');Mode='OBSERVE';Code=$(if($normal){'LISTENING'}else{$code});Connected=$normal;ExecutionEnabled=(Ops-Get $status 'ExecutionEnabled' $true);OrdersSent=(Ops-Get $status 'OrdersSent' -1)}

 }

 $notice=Ops-ReceiptAlert $watch $adapted $runId $desired $now

 if($notice){$notice.Event=if($notice.Event -ceq 'FEED_FAULT'){'SIM_FAULT'}else{'SIM_RECOVERED'};if($notice.Code -ceq 'FEED_STATUS_MISSING'){$notice.Code='SIM_STATUS_MISSING'};return $notice}

 return $null

}



function Ops-LiveStatus($runtime,$status,[string]$runId,[datetime]$now){

 $l=Ops-Get $status 'Live';if(!$l){return $null}

 if((Ops-Get $runtime 'HostProtocol' 0) -ne 2 -or (Ops-Get $status 'HostProtocol' 0) -ne 2 -or (Ops-Get $runtime 'RunId') -cne $runId -or (Ops-Get $status 'RunId') -cne $runId){throw 'LIVE_HOST_IDENTITY'}

 foreach($name in @('Schema','HostProtocol','RunId','Utc','State','ExecutionEnabled','OrdersSent','OpenOrders','UncertainOrders','Reconciled','Confirmations','TestOnly')){if($null -eq (Ops-Get $l $name)){throw 'LIVE_STATUS_INVALID'}}

 if($l.Schema -cne 'AT-LIVE-STATUS-1' -or $l.HostProtocol -ne 2 -or $l.RunId -cne $runId -or $l.TestOnly -ne $false -or $l.State -cnotin @('DISARMED','ARMED','STOPPING','REVIEW')){throw 'LIVE_STATUS_INVALID'}

 foreach($name in @('ExecutionEnabled','Reconciled','TestOnly')){if($l.$name -isnot [bool]){throw 'LIVE_STATUS_INVALID'}}

 foreach($name in @('OrdersSent','OpenOrders','UncertainOrders','Confirmations')){$v=0L;if(![long]::TryParse([string]$l.$name,[ref]$v) -or $v -lt 0){throw 'LIVE_STATUS_INVALID'}}

 if($status.ExecutionEnabled -ne $l.ExecutionEnabled -or $status.OrdersSent -ne $l.OrdersSent){throw 'LIVE_STATUS_INVALID'}

 $age=($now-(Ops-Utc $l.Utc)).TotalSeconds;if($age -lt -2 -or $age -gt 90){throw 'LIVE_STATUS_STALE'}

 return $l

}

function Ops-LiveMaintenance($runtime,$status,[string]$runId,[datetime]$now){

 if(!(Ops-Get $status 'Live') -and (Ops-Get $runtime 'LiveMode' '') -cne 'LIVE'){return 'LEGACY'}

 try{$l=Ops-LiveStatus $runtime $status $runId $now;if(!$l){return 'DEFER_IDENTITY'}}catch{return 'DEFER_IDENTITY'}

 if(($now-(Ops-Utc $runtime.Utc)).TotalSeconds -gt 15 -or ($now-(Ops-Utc $l.Utc)).TotalSeconds -gt 20){return 'DEFER_STALE'}

 if($l.UncertainOrders -gt 0 -or $l.State -ceq 'REVIEW'){return 'DEFER_REVIEW'}

 if($l.ExecutionEnabled -or $l.State -cne 'DISARMED' -or $l.OpenOrders -gt 0 -or (Ops-Get $runtime 'LiveCommandPending' $false) -or (Ops-Get $runtime 'ExecutionEnabled' $true)){return 'DEFER_ACTIVE'}

 if(!$l.Reconciled -or $l.Confirmations -lt 2){return 'DEFER_RECONCILE'}

 return 'QUIESCENT'

}



function Ops-RolloverState($live,[string]$runId,[datetime]$now){
 $r=Ops-Get $live 'Rollover';if(!$r){return ''}
 try{
  if((Ops-Get $live 'State' '') -cnotin @('DISARMED','ARMED','STOPPING') -or (Ops-Get $live 'UncertainOrders' 0) -gt 0){return 'INVALID'}
  $kst=[TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($now,'Korea Standard Time')
  if($r.Schema -cne 'AT-LIVE-ROLLOVER-1' -or $r.RunId -cne $runId -or $r.Day -cne $kst.ToString('yyyyMMdd') -or $r.PreviousDay -cne $kst.AddDays(-1).ToString('yyyyMMdd') -or $r.Phase -cnotin @('INPUT','RECONCILE','COMPLETE')){return 'INVALID'}
  $start=Ops-Utc $r.StartedUtc;$input=Ops-Utc $r.InputUtc
  if($start -gt $now.AddSeconds(2) -or [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($start,'Korea Standard Time').ToString('yyyyMMdd') -cne $r.Day -or $input -gt $now.AddSeconds(2)){return 'INVALID'}
  if($r.Phase -ceq 'COMPLETE'){return 'COMPLETE'}
  if((Ops-Get $live 'ExecutionEnabled' $true) -ne $false -or (Ops-Get $live 'Reconciled' $true) -ne $false){return 'INVALID'}
  $inputDay=[TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($input,'Korea Standard Time').ToString('yyyyMMdd')
  if(($r.Phase -ceq 'INPUT' -and $inputDay -cne $r.PreviousDay) -or ($r.Phase -ceq 'RECONCILE' -and $inputDay -cne $r.Day)){return 'INVALID'}
  if($kst.TimeOfDay.TotalSeconds -ge 120 -or ($now-$input).TotalSeconds -gt 120){return 'STALLED'}
  $age=($now-(Ops-Utc $live.Utc)).TotalSeconds;if($age -lt -2 -or $age -gt 30){return 'STALLED'}
  return 'WAIT'
 }catch{return 'INVALID'}
}

function Ops-LiveAlert($state,$status,[string]$runId,[datetime]$now=(Ops-Now)){
 # Never report a previous application's persisted live status as a current incident.
 if(!$status -or (Ops-Get $status 'RunId') -cne $runId){return $null}
 $live=Ops-Get $status 'Live'
 if(!$live -or (Ops-Get $live 'RunId') -cne $runId){return $null}
 $phase=[string](Ops-Get $live 'State' '')
 $code=[string](Ops-Get $live 'Code' '')
 $uncertain=(Ops-Get $live 'UncertainOrders' 0) -gt 0
 $rollover=Ops-RolloverState $live $runId $now
 $transition=$code -ceq 'LIVE_ROLLOVER_WAIT' -and $rollover -ceq 'WAIT'
 if($code -ceq 'LIVE_ROLLOVER_WAIT' -and !$transition){$code=if($rollover -ceq 'STALLED'){'LIVE_ROLLOVER_STALLED'}else{'LIVE_STATUS_INVALID'}}
 elseif($rollover -ceq 'STALLED' -and $code -cin @('LIVE_RECONCILE_WAIT','LIVE_MARKET_WAIT','LIVE_DISARMED','LIVE_WAIT','LIVE_DUPLICATE_SNAPSHOT')){$code='LIVE_ROLLOVER_STALLED'}
 $notice=$runId+'|'+$phase+'|'+$code+'|'+[string]$uncertain
 if($notice -ceq (Ops-Get $state 'LastLiveNotice' '')){return $null}
 $state|Add-Member NoteProperty LastLiveNotice $notice -Force
 if($uncertain){$code='LIVE_ORDER_REVIEW'}
 $normal=@('LIVE_WAIT','LIVE_DISARMED','LIVE_DUPLICATE_SNAPSHOT','LIVE_ORDER_SENT','LIVE_CANCEL_SENT','LIVE_STOPPED','LIVE_MARKET_WAIT','LIVE_CLOSE_WAIT','LIVE_RECONCILE_WAIT')
 if($uncertain -or $phase -cnotin @('DISARMED','ARMED','STOPPING') -or (!$transition -and $code -cnotin $normal)){
  if($code -cnotmatch '^[A-Z0-9_]{1,40}$'){$code='LIVE_STATUS_INVALID'}
  $state|Add-Member NoteProperty LiveFaultRun $runId -Force
  return [pscustomobject]@{Event='FAULT';Code=('LIVE '+$code)}
 }
 if(!$transition -and $rollover -cnotin @('WAIT','STALLED','INVALID') -and (Ops-Get $state 'LiveFaultRun' '') -ceq $runId){$state|Add-Member NoteProperty LiveFaultRun '' -Force;return [pscustomobject]@{Event='RECOVERED';Code=('LIVE '+$code)}}
 return $null
}

function Ops-MarketNotice($state,$status,[string]$runId,[datetime]$now,$sheets=$null,$assets=$null){
 try{
  if(!$status -or $status.RunId -cne $runId -or $status.Code -cne 'OK'){return $null}
  $live=Ops-Get $status 'Live';$session=Ops-Get $live 'MarketSession'
  if(!$live -or !$session -or $live.RunId -cne $runId -or $live.Mode -cne 'LIVE_CONTROL' -or $live.TestOnly -ne $false -or !$live.Reconciled -or $live.UncertainOrders -ne 0){return $null}
  foreach($stamp in @($status.Utc,$live.Utc,$session.SnapshotUtc)){$age=($now-(Ops-Utc $stamp)).TotalSeconds;if($age -lt -2 -or $age -gt 60){return $null}}
  $zone=[TimeZoneInfo]::FindSystemTimeZoneById('Korea Standard Time');$kst=[TimeZoneInfo]::ConvertTimeFromUtc($now,$zone);$day=$kst.ToString('yyyyMMdd')
  $open=Ops-Utc $session.OpenUtc;$close=Ops-Utc $session.CloseUtc;$snapshot=Ops-Utc $session.SnapshotUtc
  if($session.Day -cne $day -or $close -le $open -or [TimeZoneInfo]::ConvertTimeFromUtc($open,$zone).ToString('yyyyMMdd') -cne $day -or [TimeZoneInfo]::ConvertTimeFromUtc($close,$zone).ToString('yyyyMMdd') -cne $day){return $null}
  if($now -ge $open -and $now -lt $close){
   if($live.State -ceq 'ARMED' -and $live.ExecutionEnabled -eq $true -and $snapshot -ge $open -and (Ops-Get $state 'MarketOpenDay' '') -cne $day){return [pscustomobject]@{Event='MARKET_OPEN';Day=$day;ExpiresUtc=$close.ToString('o')}}
   return $null
  }
  if($now -lt $close -or $snapshot -lt $close -or $live.ExecutionEnabled -ne $false -or $live.State -cnotin @('ARMED','DISARMED') -or $live.OpenOrders -ne 0 -or $live.Code -cnotin @('LIVE_MARKET_WAIT','LIVE_DISARMED','LIVE_WAIT','LIVE_STOPPED','LIVE_DUPLICATE_SNAPSHOT')){return $null}
  if((Ops-Get $state 'MarketCloseDay' '') -ceq $day -or ((Ops-Get $state 'MarketOpenDay' '') -cne $day -and $live.OrdersSent -le 0)){return $null}
  # Fresh post-close journal and asset report, including a history collection
  # started after close. An intraday cached COMPLETE report is not settlement.
  if(!$sheets -or !$assets -or $sheets.Code -cne 'OK' -or $sheets.JournalReady -ne $true -or $assets.Code -cne 'OK' -or $assets.Phase -cne 'COMPLETE'){return $null}
  foreach($report in @($sheets,$assets)){
   if($report.Day -cne $day){return $null}
   foreach($stamp in @($report.Utc,$report.SnapshotUtc)){$v=Ops-Utc $stamp;if($v -lt $close -or $v -gt $now.AddSeconds(2) -or ($now-$v).TotalSeconds -gt 180){return $null}}
  }
  $start=Ops-Utc $assets.HistoryStartedUtc;$end=Ops-Utc $assets.HistoryCompletedUtc
  if($start -lt $close -or $end -lt $start -or $end -gt (Ops-Utc $assets.Utc) -or $end -gt $now.AddSeconds(2)){return $null}
  $expiry=[TimeZoneInfo]::ConvertTimeToUtc([datetime]::SpecifyKind($kst.Date.AddDays(1),[DateTimeKind]::Unspecified),$zone)
  return [pscustomobject]@{Event='MARKET_CLOSE';Day=$day;ExpiresUtc=$expiry.ToString('o')}
 }catch{return $null}
}
function Ops-QueueMarketNotice($state,$notice,[string]$text,[datetime]$now){
 if(!$notice -or $notice.Event -cnotin @('MARKET_OPEN','MARKET_CLOSE') -or $notice.Day -cnotmatch '^20[0-9]{6}$'){throw 'MARKET_NOTICE_INVALID'}
 $field=if($notice.Event -ceq 'MARKET_OPEN'){'MarketOpenDay'}else{'MarketCloseDay'}
 if((Ops-Get $state $field '') -ceq $notice.Day){return $false}
 $state.Outbox=@($state.Outbox)+@([pscustomobject]@{Code=$notice.Event;Text=$text;Utc=$now.ToString('o');ExpiresUtc=$notice.ExpiresUtc})
 $state|Add-Member NoteProperty $field $notice.Day -Force
 return $true
}
function Ops-PruneMarketOutbox($state,[datetime]$now){
 $kept=@($state.Outbox|Where-Object {
  if($_.Code -cin @('MARKET_OPEN','MARKET_CLOSE')){try{(Ops-Utc $_.ExpiresUtc) -gt $now}catch{$false}}else{$true}
 })
 $changed=$kept.Count -ne @($state.Outbox).Count;$state.Outbox=$kept;return $changed
}
