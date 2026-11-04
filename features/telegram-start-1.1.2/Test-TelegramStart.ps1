param([string]$Root=$PSScriptRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
. (Join-Path $Root 'bundle/At58.Ops.ps1')
. (Join-Path $Root 'bundle/At58.Sheets.ps1')
. (Join-Path $Root 'bundle/At58.Telegram.ps1')
. (Join-Path $Root 'bundle/payload/At58.Core.ps1')
. (Join-Path $Root 'tests/CashFixture.ps1')
$script:checks=0;$script:network=0;$script:calls=@();$script:updates=@();$script:message=100;$script:failMethod='';$script:afterPoll=$null
function Check($ok,[string]$name){if(!$ok){throw ('FAILED: '+$name)};$script:checks++;Write-Output ('PASS '+$name)}
function Invoke-RestMethod {$script:network++;throw 'TEST_NETWORK_FORBIDDEN'}
function At58T-Wire {$script:network++;throw 'TEST_ORDER_FORBIDDEN'}
function At58-Http {$script:network++;throw 'TEST_NETWORK_FORBIDDEN'}
function Ops-Now {return $script:cashClock}
function Tg-Call($token,$method,$body){
 $script:calls+=@([pscustomobject]@{Method=$method;Body=$body})
 if($method -ceq $script:failMethod){throw 'SYNTHETIC_SEND_FAILURE'}
 switch($method){
  'sendMessage' {$script:message++;return [pscustomobject]@{message_id=$script:message;chat=[pscustomobject]@{id=$body.chat_id}}}
  'getUpdates' {if($script:afterPoll){& $script:afterPoll};return $script:updates}
  default {return $true}
 }
}
$work=Join-Path ([IO.Path]::GetTempPath()) ('AvataTelegramTest-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
try{
 $f=Cash-Fixture (Join-Path $work 'account');$owner=$f.Owner;$owner.Version='58.17.8';$owner.ManagementRoot=Join-Path $work 'manage'
 [void][IO.Directory]::CreateDirectory($owner.ManagementRoot)
 [IO.File]::WriteAllText((Join-Path $owner.ManagementRoot 'telegram.dpapi'),'synthetic-encrypted-config-placeholder')
 $script:cashClock=[datetime]::UtcNow;$now=$script:cashClock;$script:sourceForTG=$f.Source
 $fingerprint=At58TG-ConfigHash $owner.ManagementRoot
 $config=[pscustomobject]@{Enabled=$true;Token='synthetic-not-a-token';ChatId='-12345';OwnerUserId='12345';MessageThreadId=9}
 function At58X-Input($owner){return @{Source=$script:sourceForTG}}
 function Fresh {
  $box=At58X-Mailbox $owner.RunId;$box.Mode='LIVE';$box.SourceHash=$f.Source.Hash;$box.LastUtc=$now.ToString('o');$box.UiUtc=$now.ToString('o')
  $box.Last=[pscustomobject]@{Schema='AT-LIVE-STATUS-1';HostProtocol=2;RunId=$owner.RunId;Utc=$now.ToString('o');State='DISARMED';ExecutionEnabled=$false;Reconciled=$true;Confirmations=2;OpenOrders=0;UncertainOrders=0;TestOnly=$false}
  $b=[pscustomobject]@{Version='58.17.8';State='CURRENT';HostSession='synthetic-host';Utc=$now.ToString('o')}
  $m=[pscustomobject]@{BundleVersion='58.17.8';State='HEALTHY';HostSession='synthetic-host';RunId=$owner.RunId;Utc=$now.ToString('o');CircuitOpen=$false;RepairRunning=$false;RepairTransaction=$false}
  return @{Box=$box;Bundle=$b;Manager=$m}
 }
 function Save-Host($v){Ops-WriteJson (Join-Path $owner.ManagementRoot 'bundle-status.json') $v.Bundle;Ops-WriteJson (Join-Path $owner.ManagementRoot 'manager-status.json') $v.Manager}
 function View {return [pscustomobject]@{Utc=$now.ToString('o');RunId=$owner.RunId;Scope=$owner.Scope;SourceHash=$f.Source.Hash;Symbol='0210A0';Device='MAIN';Ready=$true;Active=$false;ActiveUtc='';ArmState='DISARMED';AutoEnabled=$false;Blocked=$false}}
 function Prompt($view){$p=TgC-NewPrompt $view $config $fingerprint $now;$p.State='PENDING';$p.MessageId=99L;return $p}
 function Callback($p,[string]$answer='Y'){return [pscustomobject]@{id='synthetic-callback';from=[pscustomobject]@{id='12345';is_bot=$false};message=[pscustomobject]@{message_id=$p.MessageId;chat=[pscustomobject]@{id='-12345'};message_thread_id=9};data=('avstart:'+$answer+':'+$p.Nonce)}}
 function Approval {return (TgC-Decision (Prompt (View)) $now)}
 function Pipe($view){return [hashtable]::Synchronized(@{View=$view;Stop=$false;Paused=$false;Decision=$null})}
 $view=View;$p=Prompt $view;$cb=Callback $p
 Check ((TgC-Callback $p $cb $view $fingerprint $now) -ceq 'YES') 'owner Yes on current message is accepted'
 Check ((TgC-Callback $p (Callback $p 'N') $view $fingerprint $now) -ceq 'NO') 'owner No is a decline'
 $body=TgC-PromptBody $p $view;$json=$body|ConvertTo-Json -Depth 8 -Compress|ConvertFrom-Json
 Check ($json.text.StartsWith('실주문 시작하시겠습니까?') -and $json.reply_markup.inline_keyboard.Count -eq 1 -and $json.reply_markup.inline_keyboard[0].Count -eq 2) 'Telegram request has an actual two-button inline keyboard'
 Check ($json.reply_markup.inline_keyboard[0][0].text -ceq 'Yes' -and $json.reply_markup.inline_keyboard[0][1].text -ceq 'No' -and [Text.Encoding]::UTF8.GetByteCount($json.reply_markup.inline_keyboard[0][0].callback_data) -le 64) 'exact Yes No labels and callback byte limit'
 $cases=@(
  @{Name='another user';Change={$args[0].Cb.from.id='777'}},
  @{Name='bot sender';Change={$args[0].Cb.from.is_bot=$true}},
  @{Name='another group';Change={$args[0].Cb.message.chat.id='-555'}},
  @{Name='another topic';Change={$args[0].Cb.message.message_thread_id=8}},
  @{Name='another message';Change={$args[0].Cb.message.message_id=78}},
  @{Name='another PC nonce';Change={$args[0].Cb.data='avstart:Y:'+('a'*32)}},
  @{Name='text command';Change={$args[0].Cb.data='/start'}},
  @{Name='inline forwarded message';Change={$args[0].Cb|Add-Member inline_message_id 'foreign'}},
  @{Name='old program run';Change={$args[0].View.RunId=[guid]::NewGuid().ToString()}},
  @{Name='changed account';Change={$args[0].View.Scope='e'*64}},
  @{Name='changed strategy';Change={$args[0].View.SourceHash='b'*64}},
  @{Name='stale UI';Change={$args[0].View.Utc=$now.AddSeconds(-16).ToString('o')}},
  @{Name='future UI';Change={$args[0].View.Utc=$now.AddSeconds(3).ToString('o')}},
  @{Name='no longer ready';Change={$args[0].View.Ready=$false}},
  @{Name='automatic start enabled';Change={$args[0].View.AutoEnabled=$true}},
  @{Name='pause or update';Change={$args[0].View.Blocked=$true}},
  @{Name='already started';Change={$args[0].View.Active=$true}},
  @{Name='expired invitation';Change={$args[0].Prompt.ExpiresUtc=$now.ToString('o')}},
  @{Name='already declined';Change={$args[0].Prompt.State='DECLINED'}},
  @{Name='already consumed';Change={$args[0].Prompt.State='ACCEPTED'}}
 )
 foreach($case in $cases){$v=View;$p=Prompt $v;$x=@{View=$v;Prompt=$p;Cb=(Callback $p)};& $case.Change $x;Check ((TgC-Callback $p $x.Cb $v $fingerprint $now) -cne 'YES') ('callback rejects '+$case.Name)}
 $v=View;$p=Prompt $v;Check ((TgC-Callback $p (Callback $p) $v ('f'*64) $now) -ceq 'NOT_READY') 're-pairing invalidates old approval'
 $p=Prompt (View);$a=TgC-Decision $p $now;$thrown=$false;try{$null=TgC-Decision $p $now}catch{$thrown=$true};Check $thrown 'same prompt cannot produce a second decision'
 $v=Fresh;Save-Host $v;$approval=Approval
 Check (At58TG-TryQueue $owner $v.Box $approval $v.Bundle $v.Manager $now) 'verified approval queues a one-time guarded command'
 Check ($v.Box.Command.Action -ceq 'ARM_TELEGRAM' -and !(At58AS-Load $owner).Enabled) 'remote start does not write persistent automatic consent'
 At58X-Commands $owner $v.Box
 Check ($v.Box.CommandError -ceq '' -and $owner.LiveSession.State -ceq 'ARMED' -and !$v.Box.TelegramPermit) 'worker verifies and consumes approval through normal authorization'
 $owner.Remove('LiveSession')
 Check (!(At58TG-TryQueue $owner $v.Box $approval $v.Bundle $v.Manager $now)) 'same callback cannot queue again after consumption'
 $guardCases=@(
  @{Name='auto preference enabled';Change={$null=At58AS-Save $owner $true}},
  @{Name='stop wins';Change={$args[0].Box.StopRequested=$true}},
  @{Name='open order';Change={$args[0].Box.Last.OpenOrders=1}},
  @{Name='uncertain order';Change={$args[0].Box.Last.UncertainOrders=1}},
  @{Name='reconciliation lost';Change={$args[0].Box.Last.Reconciled=$false}},
  @{Name='one confirmation';Change={$args[0].Box.Last.Confirmations=1}},
  @{Name='stale account';Change={$args[0].Box.Last.Utc=$now.AddSeconds(-31).ToString('o')}},
  @{Name='changed source at queue';Change={$args[0].Box.SourceHash='b'*64}},
  @{Name='repair started';Change={$args[0].Manager.RepairRunning=$true}},
  @{Name='bundle validation';Change={$args[0].Bundle.State='VERIFYING'}},
  @{Name='different manager';Change={$args[0].Manager.RunId=[guid]::NewGuid().ToString()}},
  @{Name='test status in real session';Change={$args[0].Box.Last.TestOnly=$true}}
 )
 foreach($case in $guardCases){$null=At58AS-Save $owner $false;$v=Fresh;$a=Approval;& $case.Change $v;Check (!(At58TG-TryQueue $owner $v.Box $a $v.Bundle $v.Manager $now)) ('queue rejects '+$case.Name)}
 $null=At58AS-Save $owner $false
 foreach($case in @('expired','new config','new source','new account','restarted')){
  $v=Fresh;$a=Approval
  switch($case){'expired'{$a.ExpiresUtc=$now.ToString('o')};'new config'{$a.ConfigHash='f'*64};'new source'{$a.SourceHash='f'*64};'new account'{$a.Scope='f'*64};'restarted'{$a.RunId=[guid]::NewGuid().ToString()}}
  Check (!(At58TG-TryQueue $owner $v.Box $a $v.Bundle $v.Manager $now)) ('queue rejects '+$case+' decision')
 }
 foreach($case in @('auto changed','repair changed','expired','limits changed','config changed','source changed')){
  $null=At58AS-Save $owner $false;$v=Fresh;Save-Host $v;$a=Approval;$null=At58TG-TryQueue $owner $v.Box $a $v.Bundle $v.Manager $now
  switch($case){'auto changed'{$null=At58AS-Save $owner $true};'repair changed'{$v.Manager.RepairRunning=$true;Save-Host $v};'expired'{$v.Box.TelegramPermit.ExpiresUtc=$now.ToString('o')};'limits changed'{$v.Box.TelegramPermit.LimitsHash='f'*64};'config changed'{$v.Box.TelegramPermit.ConfigHash='f'*64};'source changed'{$script:sourceForTG=At58S-Clone $f.Source;$script:sourceForTG.Hash='f'*64}}
  At58X-Commands $owner $v.Box
  Check ($v.Box.CommandError -and !$owner.ContainsKey('LiveSession') -and !$v.Box.TelegramPermit) ('worker rechecks '+$case)
  $script:sourceForTG=$f.Source
 }
 $null=At58AS-Save $owner $false;$v=Fresh;Save-Host $v;At58X-Queue $v.Box 'ARM_TELEGRAM' $v.Box.SourceHash (At58D-Limits) $now ('a'*32);At58X-Commands $owner $v.Box
 Check ($v.Box.CommandError -ceq 'LIVE_TELEGRAM_APPROVAL') 'bare remote command without verified in-memory permit is rejected'
 $v=Fresh;Save-Host $v;$a=Approval;$null=At58TG-TryQueue $owner $v.Box $a $v.Bundle $v.Manager $now;At58X-Queue $v.Box 'STOP'
 Check (!$v.Box.TelegramPermit -and $v.Box.Command.Action -ceq 'STOP') 'local stop replaces queued remote start and revokes permit'
 # Exercise the complete Telegram controller using only synthetic API replies.
 $s=TgC-NewState;$pipe=Pipe (View);$script:calls=@();TgC-Step $s $pipe $config $fingerprint $now
 Check ($s.Prompt.State -ceq 'PENDING' -and @($script:calls|Where-Object Method -ceq 'sendMessage').Count -eq 1 -and !$pipe.Decision) 'ready state sends one prompt without starting'
 TgC-Step $s $pipe $config $fingerprint $now
 Check (@($script:calls|Where-Object Method -ceq 'sendMessage').Count -eq 1) 'ready polling does not duplicate prompt'
 $cb=Callback $s.Prompt 'N';$script:updates=@([pscustomobject]@{update_id=1;callback_query=$cb});TgC-Step $s $pipe $config $fingerprint $now
 Check ($s.Prompt.State -ceq 'DECLINED' -and !$pipe.Decision) 'No consumes prompt without command'
 TgC-Step $s $pipe $config $fingerprint $now
 Check (@($script:calls|Where-Object Method -ceq 'sendMessage').Count -eq 1) 'No does not repeatedly ask during the same run'
 $old=$s.Prompt.Nonce;$cb=Callback $s.Prompt 'R';$script:updates=@([pscustomobject]@{update_id=2;callback_query=$cb});TgC-Step $s $pipe $config $fingerprint $now
 Check (!$pipe.Decision -and !$s.Prompt) 'readiness refresh after No does not authorize trading'
 $script:updates=@();TgC-Step $s $pipe $config $fingerprint $now
 Check ($s.Prompt.Nonce -cne $old -and $s.Prompt.State -ceq 'PENDING') 'readiness refresh sends a new Yes No prompt'
 $s=TgC-NewState;$pipe=Pipe (View);$script:updates=@();TgC-Step $s $pipe $config $fingerprint $now
 $cb=Callback $s.Prompt;$script:updates=@([pscustomobject]@{update_id=2;callback_query=$cb},[pscustomobject]@{update_id=3;callback_query=$cb});TgC-Step $s $pipe $config $fingerprint $now
 Check ($pipe.Decision -and $s.Prompt.State -ceq 'ACCEPTED' -and $s.Offset -eq 4) 'duplicate callback batch publishes one approval and advances offset'
 $s=TgC-NewState;$pipe=Pipe (View);$pipe.View.AutoEnabled=$true;$script:calls=@();$script:updates=@();TgC-Step $s $pipe $config $fingerprint $now
 Check (@($script:calls).Count -eq 0 -and !$s.Prompt) 'automatic mode receives no start confirmation'
 $pipe.View.Active=$true;$pipe.View.ArmState='ARMED';$pipe.View.Ready=$false;$pipe.View.ActiveUtc=$now.ToString('o');TgC-Step $s $pipe $config $fingerprint $now;TgC-Step $s $pipe $config $fingerprint $now
 Check (@($script:calls|Where-Object Method -ceq 'sendMessage').Count -eq 1 -and $script:calls[0].Body.text.StartsWith('실주문 시작합니다.')) 'successful automatic or manual activation sends one exact start notice'
 $pipe.View.Active=$false;TgC-Step $s $pipe $config $fingerprint $now;$pipe.View.Active=$true;TgC-Step $s $pipe $config $fingerprint $now
 Check (@($script:calls|Where-Object Method -ceq 'sendMessage').Count -eq 1) 'temporary stale read while armed does not repeat start notice'
 $s=TgC-NewState;$pipe=Pipe (View);$script:calls=@();TgC-Step $s $pipe $config $fingerprint $now;$old=$s.Prompt.Nonce;$pipe.View.Ready=$false;TgC-Step $s $pipe $config $fingerprint $now
 Check (!$s.Prompt -and !$pipe.Decision) 'readiness loss invalidates and removes buttons'
 $pipe.View.Ready=$true;TgC-Step $s $pipe $config $fingerprint $now
 Check ($s.Prompt -and $s.Prompt.Nonce -cne $old) 'recovered readiness receives a new nonce'
 $s=TgC-NewState;$pipe=Pipe (View);$script:failMethod='sendMessage';$failed=$false;try{TgC-Step $s $pipe $config $fingerprint $now}catch{$failed=$true}
 Check ($failed -and !$pipe.Decision -and !$s.Prompt) 'ambiguous send failure cannot authorize an untracked button'
 $script:failMethod='';$script:calls=@();TgC-Step $s $pipe $config $fingerprint $now
 Check (!$script:calls.Count) 'send retries are backed off'
 $s=TgC-NewState;$pipe=Pipe (View);$script:calls=@();$script:updates=@();TgC-Step $s $pipe $config $fingerprint $now
 $cb=Callback $s.Prompt;$script:updates=@([pscustomobject]@{update_id=7;callback_query=$cb});TgC-Step $s $pipe $config $fingerprint $now
 $pipe.RejectedNonce=$pipe.Decision.Nonce;$script:updates=@();TgC-Step $s $pipe $config $fingerprint $now
 $notices=@($script:calls|Where-Object {$_.Method -ceq 'sendMessage' -and $_.Body.text.StartsWith('실주문 시작을 완료하지 못했습니다.')})
 Check ($notices.Count -eq 1 -and $s.Prompt.State -ceq 'FAILED') 'rejected UI handoff sends a failure notice instead of success'
 Check (@($script:calls|Where-Object {$_.Method -ceq 'sendMessage' -and $_.Body.text.StartsWith('실주문 시작합니다.')}).Count -eq 0) 'queued request alone never emits a success notice'
 $s=TgC-NewState;$pipe=Pipe (View);$script:updates=@();TgC-Step $s $pipe $config $fingerprint $now
 $cb=Callback $s.Prompt;$script:updates=@([pscustomobject]@{update_id=8;callback_query=$cb});$script:afterPoll={$pipe.View.Ready=$false};TgC-Step $s $pipe $config $fingerprint $now;$script:afterPoll=$null
 Check (!$pipe.Decision -and $s.Prompt.State -ceq 'INVALID') 'readiness change during Telegram network wait is rechecked'
 # Execute the actual UI adapter with inert label objects and synthetic account files.
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'bundle/payload/esbada_Merits_AT_v58.ps1'),[ref]$tokens,[ref]$errors)
 Check (!$errors.Count) 'integrated UI parses on Windows PowerShell 5.1'
 $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Live-TelegramTick'},$true)
 Invoke-Expression $fn.Extent.Text
 $managed=$true;$HostProtocol=2;$RunId=$owner.RunId;$ManagementRoot=$owner.ManagementRoot;$Symbol='0210A0'
 $script:At58TelegramSettings=$false;$script:At58UpdateQueued=$false;$script:At58TrayEnabled=$false;$script:At58AutoOwner=$owner
 $script:At58Auto=@{Enabled=$false;Code='OFF'};$script:At58Ui=@{Running=$true;Failed=$false;Fault='';ExitReason='';PauseAfterLiveStop=$false}
 $liveLabel=[pscustomobject]@{Text=''};$liveArm=[pscustomobject]@{Enabled=$true};$script:readRequests=0
 function Live-RequestRead {$script:readRequests++}
 $now=[datetime]::UtcNow;$script:cashClock=$now;$v=Fresh;Save-Host $v;$script:At58LiveBox=$v.Box
 $pipe=Pipe (View);$pipe.Decision=Approval;$script:At58Telegram=@{Pipe=$pipe}
 Live-TelegramTick
 Check ($script:readRequests -eq 1 -and $v.Box.Command.Action -ceq 'ARM_TELEGRAM' -and !$pipe.Decision) 'actual UI adapter hands verified Yes to guarded account worker'
 Live-TelegramTick
 Check ($script:readRequests -eq 1) 'UI timer does not replay a consumed decision'
 $v=Fresh;Save-Host $v;$script:At58LiveBox=$v.Box;$pipe.Decision=Approval;$script:At58UpdateQueued=$true;Live-TelegramTick
 Check (!$v.Box.Command -and $pipe.RejectedNonce) 'UI update request blocks approval and reports rejection'
 $script:At58UpdateQueued=$false;$script:At58Auto.Enabled=$true;$pipe.Decision=Approval;Live-TelegramTick
 Check (!$v.Box.Command -and $pipe.View.AutoEnabled) 'UI automatic-mode view suppresses invitation'
 Check (!(At58AS-Load $owner).Enabled -and $script:network -eq 0) 'all tests preserve auto-start off and make zero real network or broker calls'
 Write-Output ('TELEGRAM START TESTS COMPLETE: '+$script:checks+' passed; synthetic local state only.')
}finally{
 $resolved=[IO.Path]::GetFullPath($work);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf).StartsWith('AvataTelegramTest-')){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
