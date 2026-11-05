Add-Type -AssemblyName System.Security

function Tg-Protect([string]$value){$b=[Text.Encoding]::UTF8.GetBytes($value);try{return [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($b,[Text.Encoding]::UTF8.GetBytes('AT58-TELEGRAM-1'),[Security.Cryptography.DataProtectionScope]::CurrentUser))}finally{[Array]::Clear($b,0,$b.Length)}}

function Tg-Load([string]$root){

 $b=$null

 try{$cipher=[IO.File]::ReadAllText((Join-Path $root 'telegram.dpapi'));$b=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($cipher),[Text.Encoding]::UTF8.GetBytes('AT58-TELEGRAM-1'),[Security.Cryptography.DataProtectionScope]::CurrentUser);return ([Text.Encoding]::UTF8.GetString($b)|ConvertFrom-Json)}catch{return $null}finally{if($b){[Array]::Clear($b,0,$b.Length)}}

}

function Tg-Save([string]$root,$config){

 [void][IO.Directory]::CreateDirectory($root);$path=Join-Path $root 'telegram.dpapi';$tmp=$path+'.tmp'

 try{[IO.File]::WriteAllText($tmp,(Tg-Protect ($config|ConvertTo-Json -Compress)),[Text.Encoding]::UTF8);if([IO.File]::Exists($path)){[IO.File]::Replace($tmp,$path,[Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($tmp,$path)}}finally{if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}}

}

function Tg-Call([string]$token,[string]$method,$body){

 if($token -cnotmatch '^[0-9]{5,20}:[A-Za-z0-9_-]{20,100}$' -or $method -cnotin @('getMe','getUpdates','getWebhookInfo','sendMessage','answerCallbackQuery','editMessageText')){throw 'TELEGRAM_INPUT'}

 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

 try{$r=Invoke-RestMethod -Method Post -Uri ('https://api.telegram.org/bot'+$token+'/'+$method) -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes(($body|ConvertTo-Json -Depth 8 -Compress))) -TimeoutSec 8 -ErrorAction Stop;if(!$r.ok){throw 'TELEGRAM_RESPONSE'};return $r.result}catch{

  $retry=60;try{$raw=$_.ErrorDetails.Message|ConvertFrom-Json;$retry=[math]::Max(30,[math]::Min(3600,[int]$raw.parameters.retry_after))}catch{}

  $e=[InvalidOperationException]::new('TELEGRAM_SEND_FAILED');$e.Data['RetryAfter']=$retry;throw $e

 }

}

function Tg-PairCandidate($updates,[string]$nonce,[datetime]$created){

 $matches=@()

 foreach($u in $updates){$m=Ops-Get $u 'message';if(!$m){continue};$chat=Ops-Get $m 'chat';$from=Ops-Get $m 'from';if((Ops-Get $chat 'type') -cne 'private' -or (Ops-Get $m 'text') -cne ('/start '+$nonce)){continue}

  if([string](Ops-Get $chat 'id') -cne [string](Ops-Get $from 'id') -or (Ops-Get $from 'is_bot' $true)){continue}

  try{$at=[datetimeoffset]::FromUnixTimeSeconds([long]$m.date).UtcDateTime;if($at -lt $created.AddSeconds(-5) -or $at -gt $created.AddMinutes(10)){continue}}catch{continue}

  $matches+=[string]$chat.id

 }

 $ids=@($matches|Select-Object -Unique);if($ids.Count -gt 1){throw 'PAIR_AMBIGUOUS'};if($ids.Count -eq 1){return $ids[0]};return ''

}

function Tg-Notify($config,[string]$text){

 if(!$config -or !(Ops-Get $config 'Enabled' $false)){throw 'TELEGRAM_NOT_CONFIGURED'}

 if($text.Length -gt 1200){throw 'TELEGRAM_TOO_LONG'}

 $body=@{chat_id=$config.ChatId;text=$text;protect_content=$true;disable_notification=$false}

 $thread=[long](Ops-Get $config 'MessageThreadId' 0);if($thread -gt 0){$body.message_thread_id=$thread}

 $null=Tg-Call $config.Token 'sendMessage' $body

}

function Tg-OwnerId($config){

 $id=[string](Ops-Get $config 'OwnerUserId' '')

 if(!$id){$id=[string](Ops-Get $config 'ChatId' '')}

 if($id -cmatch '^[1-9][0-9]{0,15}$'){return $id};return ''

}

function Tg-GroupPairCandidate($updates,[string]$nonce,[datetime]$created,[string]$ownerId,[string]$botName){

 if($ownerId -cnotmatch '^[1-9][0-9]{0,15}$' -or $nonce -cnotmatch '^[a-f0-9]{32}$' -or $botName -cnotmatch '^[A-Za-z0-9_]{5,64}$'){throw 'PAIR_INPUT'}

 $candidates=@{}

 foreach($u in $updates){

  $m=Ops-Get $u 'message';if(!$m){continue};$chat=Ops-Get $m 'chat';$from=Ops-Get $m 'from'

  if((Ops-Get $chat 'type') -cnotin @('group','supergroup') -or [string](Ops-Get $chat 'id') -cnotmatch '^-[1-9][0-9]{0,15}$'){continue}

  if([string](Ops-Get $from 'id') -cne $ownerId -or (Ops-Get $from 'is_bot' $true) -or (Ops-Get $m 'sender_chat') -or (Ops-Get $m 'forward_origin') -or (Ops-Get $m 'forward_date')){continue}

  # An explicitly addressed command works with Telegram's default privacy mode.

  $command=[string](Ops-Get $m 'text');$expected='/start@'+$botName+' '+$nonce

  if(![string]::Equals($command,$expected,[StringComparison]::OrdinalIgnoreCase)){continue}

  try{$at=[datetimeoffset]::FromUnixTimeSeconds([long]$m.date).UtcDateTime;if($at -lt $created.AddSeconds(-5) -or $at -gt $created.AddMinutes(10)){continue}}catch{continue}

  $thread=[long](Ops-Get $m 'message_thread_id' 0);if($thread -lt 0){continue}

  $id=[string]$chat.id;$key=$id+':'+$thread

  $title=([string](Ops-Get $chat 'title' '단톡방') -replace '[\x00-\x1f\x7f]',' ');if($title.Length -gt 100){$title=$title.Substring(0,100)}

  $candidates[$key]=[pscustomobject]@{ChatId=$id;ChatType=[string]$chat.type;ChatTitle=$title;MessageThreadId=$thread}

 }

 if($candidates.Count -gt 1){throw 'PAIR_AMBIGUOUS'}

 if($candidates.Count -eq 1){return @($candidates.Values)[0]};return $null

}

function Tg-PreparePair([string]$root,[string]$token,[string]$mode){

 if($mode -cnotin @('private','group')){throw 'PAIR_INPUT'}

 $owner=''

 if($mode -ceq 'group'){

  $saved=Tg-Load $root;$owner=Tg-OwnerId $saved

  if(!$owner -or !$saved -or $saved.Token -cne $token){throw 'PRIVATE_PAIR_REQUIRED'}

 }

 $me=Tg-Call $token 'getMe' @{};$web=Tg-Call $token 'getWebhookInfo' @{}

 if($web.url){throw 'WEBHOOK_IN_USE'}

 if(!$me.is_bot -or $me.username -cnotmatch '^[A-Za-z0-9_]{5,64}$'){throw 'BOT_IDENTITY'}

 if($mode -ceq 'group' -and (Ops-Get $me 'can_join_groups' $true) -eq $false){throw 'GROUPS_DISABLED'}

 $nonce=[guid]::NewGuid().ToString('N');$parameter=if($mode -ceq 'group'){'startgroup'}else{'start'}

 $command=if($mode -ceq 'group'){'/start@'+$me.username+' '+$nonce}else{'/start '+$nonce}

 return [pscustomobject]@{Token=$token;Mode=$mode;OwnerId=$owner;BotName=[string]$me.username;Nonce=$nonce;Created=(Ops-Now);Link=('https://t.me/'+$me.username+'?'+$parameter+'='+$nonce);Command=$command;Offset=$null;Updates=@()}

}

function Tg-ReadPairUpdates($pair){

 $body=@{timeout=0;limit=100;allowed_updates=@('message')};if($null -ne $pair.Offset){$body.offset=$pair.Offset}

 $batch=@(Tg-Call $pair.Token 'getUpdates' $body)

 $pair.Updates=@($pair.Updates)+$batch

 if($pair.Updates.Count -gt 3000){throw 'PAIR_TOO_MANY'}

 if($batch.Count){$ids=@($batch|ForEach-Object {Ops-Get $_ 'update_id'}|Where-Object {$null -ne $_});if($ids.Count){$pair.Offset=[long]($ids|Measure-Object -Maximum).Maximum+1}}

 # One bounded request per click keeps the UI heartbeat responsive. Retain all

 # candidates until the queue is drained so two matching groups fail closed.

 if($batch.Count -eq 100){throw 'PAIR_MORE_UPDATES'}

 return $pair.Updates

}

function Tg-CompletePair([string]$root,$pair,[bool]$autoRepair,[string]$codexPath){

 if(!$pair){throw 'PAIR_REQUIRED'}

 $age=((Ops-Now)-$pair.Created).TotalSeconds;if($age -lt -5 -or $age -gt 600){throw 'PAIR_EXPIRED'}

 if($autoRepair -and ![IO.File]::Exists($codexPath)){throw 'CODEX_MISSING'}

 if($pair.Mode -ceq 'group'){

  $saved=Tg-Load $root

  if(!$saved -or $saved.Token -cne $pair.Token -or (Tg-OwnerId $saved) -cne $pair.OwnerId){throw 'PRIVATE_PAIR_REQUIRED'}

 }

 $updates=@(Tg-ReadPairUpdates $pair)

 if($pair.Mode -ceq 'group'){

  $candidate=Tg-GroupPairCandidate $updates $pair.Nonce $pair.Created $pair.OwnerId $pair.BotName

  if(!$candidate){throw 'PAIR_NOT_FOUND'};$owner=$pair.OwnerId

 }else{

  $id=Tg-PairCandidate $updates $pair.Nonce $pair.Created;if(!$id){throw 'PAIR_NOT_FOUND'}

  $owner=$id;$candidate=[pscustomobject]@{ChatId=$id;ChatType='private';ChatTitle='개인 채팅';MessageThreadId=0}

 }

 $config=[pscustomobject]@{Enabled=$true;Token=$pair.Token;ChatId=$candidate.ChatId;ChatType=$candidate.ChatType;ChatTitle=$candidate.ChatTitle;MessageThreadId=$candidate.MessageThreadId;OwnerUserId=$owner;PrivateChatId=$owner;BotUsername=$pair.BotName;AutoRepair=$autoRepair;CodexPath=$codexPath}

 Tg-Notify $config '[AT58] 알림 수신 테스트입니다. PC에서 저장 완료 표시를 확인하세요. 저장 후 이 대화로 장애·복구·업데이트 결과를 보냅니다.'

 Tg-Save $root $config

 return $config

}

function Tg-UsePrivate([string]$root){

 $saved=Tg-Load $root;$owner=Tg-OwnerId $saved;if(!$saved -or !$owner){throw 'PRIVATE_PAIR_REQUIRED'}

 $config=$saved|ConvertTo-Json -Depth 8|ConvertFrom-Json

 foreach($entry in @{Enabled=$true;ChatId=$owner;ChatType='private';ChatTitle='개인 채팅';MessageThreadId=0;OwnerUserId=$owner;PrivateChatId=$owner}.GetEnumerator()){$config|Add-Member NoteProperty $entry.Key $entry.Value -Force}

 Tg-Notify $config '[AT58] 개인 알림 복귀 테스트입니다. PC에서 저장 완료 표시를 확인하세요.'

 Tg-Save $root $config;return $config

}

function Tg-ConnectionLabel($config){

 if(!$config){return '현재 수신처: 연결 안 됨'}

 $kind=if([string]$config.ChatId -like '-*'){'단톡방'}else{'개인 채팅'}

 $title=[string](Ops-Get $config 'ChatTitle' '');$status=if($config.Enabled){'사용 중'}else{'꺼짐'}

 return ('현재 수신처: '+$kind+$(if($title -and $title -ne $kind){' · '+$title}else{''})+' ('+$status+')')

}

function Tg-PairError([string]$code){

 switch($code){

  'PRIVATE_PAIR_REQUIRED' {return '먼저 같은 봇으로 개인 채팅을 연결·저장하세요. 단톡방 연결은 확인된 본인 계정만 할 수 있습니다.'}

  'GROUPS_DISABLED' {return '이 봇은 그룹 참여가 꺼져 있습니다. BotFather의 /setjoingroups에서 허용한 뒤 다시 준비하세요.'}

  'WEBHOOK_IN_USE' {return '다른 서비스가 이 봇을 사용 중입니다. AT 전용 봇으로 연결하세요.'}

  'PAIR_EXPIRED' {return '연결 코드가 만료됐습니다. 연결 준비를 다시 누르고 새 명령을 보내세요.'}

  'PAIR_AMBIGUOUS' {return '같은 코드가 여러 대화방에서 확인됐습니다. 연결 준비를 다시 누르고 원하는 방 한 곳에만 새 명령을 보내세요.'}

  'PAIR_MORE_UPDATES' {return '이전 메시지를 확인했습니다. 연결 확인·저장을 다시 눌러 다음 메시지를 확인하세요.'}

  'PAIR_TOO_MANY' {return '대기 메시지가 너무 많습니다. 연결 준비부터 다시 진행하세요.'}

  'PAIR_NOT_FOUND' {return '연결 명령을 아직 찾지 못했습니다. 개인 연결에 사용한 본인 계정으로 원하는 방에 아래 연결 명령을 보내세요.'}

  'PAIR_REQUIRED' {return '연결 준비를 먼저 누르세요.'}

  'CODEX_MISSING' {return 'Codex 실행 경로를 찾지 못했습니다. 알림만 연결하려면 자동 수정 체크를 해제하세요.'}

  default {return '연결 또는 저장에 실패했습니다. 토큰·인터넷·봇의 메시지 전송 권한을 확인하세요. 기존 수신처 설정은 유지됩니다.'}

 }

}

function Tg-EventText([string]$code,[string]$detail=''){

 if($code -cin @('MARKET_OPEN','MARKET_CLOSE')){
  if($detail){throw 'NOTIFY_DETAIL'}
  $message=if($code -ceq 'MARKET_OPEN'){'본장에 출근했습니다. 실주문 시작합니다'}else{'장 마감으로 일일정산 후 퇴근합니다.'}
  $at=[TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Ops-Now),'Korea Standard Time').ToString('yyyy-MM-dd HH:mm:ss')
  return ($message+[Environment]::NewLine+'메인PC / '+$at+' (KST)')
 }
 $labels=@{SIM_FAULT='통합 모의 운용 확인 필요 (5분 지속)';SIM_RECOVERED='통합 모의 운용 복구';FEED_FAULT='접수·체결 통보 확인 필요 (5분 지속)';FEED_RECOVERED='접수·체결 통보 연결 복구';BUNDLE_UPDATING='전체 버전 업데이트 시작';BUNDLE_UPDATED='전체 버전 업데이트 완료';BUNDLE_ROLLBACK='이전 전체 버전으로 복귀';BUNDLE_RECOVERED='이전 버전 정상 조회 확인';BUNDLE_FAILED='이전 버전 조회 확인 필요';FAULT='장애 감지';RECOVERED='정상 복귀';RESTART='자동 재시작';RESTART_LIMIT='재시작 한도 도달';REPAIR_STARTED='Codex 분석·수정 시작';REPAIR_FAILED='자동 수정 중단 · 기존 버전 유지';NO_CHANGE='코드 수정 없이 분석 완료';UPDATE='검증 통과 · 업데이트 후 재시작';UPDATED='업데이트 후 정상 조회 3회 확인';ROLLBACK='새 버전 확인 실패 · 이전 버전 복귀';ROLLBACK_RECOVERED='이전 버전 정상 조회 확인';ROLLBACK_FAILED='이전 버전도 정상 조회 미확인';CODEX_UNAVAILABLE='Codex 호출 경로 확인 필요';MANAGER_STARTED='감시 시작';MANAGER_STOPPED='사용자 종료 · 감시 종료';READONLY_GUARD='조회 전용 조건 위반 · 실행 중단'}

 if(!$labels.ContainsKey($code)){throw 'NOTIFY_EVENT'}

 if($code -clike 'BUNDLE_*'){if($detail -cnotmatch '^58\.[0-9]{1,4}\.[0-9]{1,4}$'){throw 'NOTIFY_DETAIL'}}elseif($detail -cnotmatch '^[A-Z0-9_ /-]{0,120}$'){throw 'NOTIFY_DETAIL'}

 $kst=[TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Ops-Now),'Korea Standard Time').ToString('MM/dd HH:mm:ss')

 return ('[AT58] '+$labels[$code]+[Environment]::NewLine+$kst+$(if($detail){[Environment]::NewLine+$detail}else{''}))

}

function Tg-ShowSettings($owner,[string]$root){

 $d=[Windows.Forms.Form]::new();$d.Text='AT58.2 · 텔레그램 개인 / 단톡방 알림';$d.ClientSize=[Drawing.Size]::new(740,640);$d.StartPosition='CenterParent';$d.Font=$owner.Font;$d.FormBorderStyle='FixedDialog';$d.MaximizeBox=$false;$d.MinimizeBox=$false

 function Tg-Label([string]$text,[int]$x,[int]$y,[int]$w,[int]$h){$v=[Windows.Forms.Label]::new();$v.Text=$text;$v.Location=[Drawing.Point]::new($x,$y);$v.Size=[Drawing.Size]::new($w,$h);$d.Controls.Add($v);return $v}

 function Tg-Button([string]$text,[int]$x,[int]$y,[int]$w){$v=[Windows.Forms.Button]::new();$v.Text=$text;$v.Location=[Drawing.Point]::new($x,$y);$v.Size=[Drawing.Size]::new($w,32);$d.Controls.Add($v);return $v}

 $tips=Tg-Label ('처음에는 개인 채팅을 연결하세요. 이후 단톡방으로 알림 수신처를 바꿀 수 있습니다.'+[Environment]::NewLine+'단톡방 연결 명령은 개인 연결에 사용한 본인 계정으로 보내세요.') 18 14 704 46

 $current=Tg-Label '현재 수신처: 연결 안 됨' 18 65 704 28

 $tokenLabel=Tg-Label '봇 토큰' 18 103 100 26

 $tokenInput=[Windows.Forms.TextBox]::new();$tokenInput.Location=[Drawing.Point]::new(120,100);$tokenInput.Width=590;$tokenInput.UseSystemPasswordChar=$true;$d.Controls.Add($tokenInput)

 $modeLabel=Tg-Label '새 수신처' 18 146 100 26

 $mode=[Windows.Forms.ComboBox]::new();$mode.Location=[Drawing.Point]::new(120,140);$mode.Width=310;$mode.DropDownStyle='DropDownList';$mode.Items.AddRange(@('개인 채팅','단톡방 (공동 알림)'));$mode.SelectedIndex=0;$d.Controls.Add($mode)

 $prepare=Tg-Button '연결 준비' 454 138 256

 $linkLabel=Tg-Label '텔레그램 연결 주소 (https://t.me/로 시작)' 18 180 692 25

 $link=[Windows.Forms.TextBox]::new();$link.Location=[Drawing.Point]::new(18,205);$link.Width=692;$link.ReadOnly=$true;$d.Controls.Add($link)

 $copy=Tg-Button '연결 주소 복사' 18 237 160;$copy.Enabled=$false

 $commandLabel=Tg-Label '연결 명령 · 주소 대신 원하는 텔레그램 채팅에 보내도 됩니다.' 18 279 692 25

 $command=[Windows.Forms.TextBox]::new();$command.Location=[Drawing.Point]::new(18,306);$command.Width=692;$command.ReadOnly=$true;$d.Controls.Add($command)

 $copyCommand=Tg-Button '연결 명령 복사' 18 341 200;$copyCommand.Enabled=$false

 $confirm=Tg-Button '연결 확인·저장' 454 341 256;$confirm.Enabled=$false

 $notice=Tg-Label '수신처 선택 → 연결 준비 → 텔레그램에 연결 명령 전송 → 연결 확인·저장. 코드는 10분간 유효합니다.' 18 386 692 78

 $repair=[Windows.Forms.CheckBox]::new();$repair.Text='오류 지속 시 Codex 분석·수정 및 검증된 수정본 자동 적용';$repair.Location=[Drawing.Point]::new(18,472);$repair.Size=[Drawing.Size]::new(692,28);$repair.Checked=$true;$d.Controls.Add($repair)

 $codexLabel=Tg-Label '자동 수정용 Codex 실행 경로 (텔레그램 연결 주소가 아닙니다)' 18 510 692 25

 $codex=[Windows.Forms.TextBox]::new();$codex.Location=[Drawing.Point]::new(18,537);$codex.Width=692;$codex.ReadOnly=$true;$codex.Text=Ops-FindCodex;$d.Controls.Add($codex)

 $disable=Tg-Button '알림·자동수정 끄기' 18 585 190

 $returnPrivate=Tg-Button '개인 알림으로 돌아가기' 230 585 230

 $state=@{Pair=$null;Root=$root;Input=$tokenInput;Mode=$mode;Link=$link;Command=$command;Copy=$copy;CopyCommand=$copyCommand;Prepare=$prepare;Confirm=$confirm;Repair=$repair;Codex=$codex;Notice=$notice;Current=$current;Form=$d}

 foreach($b in @($prepare,$copy,$copyCommand,$confirm,$disable,$returnPrivate,$mode,$tokenInput)){$b.Tag=$state}

 $existing=Tg-Load $root

 if($existing){$tokenInput.Text=$existing.Token;$repair.Checked=[bool]$existing.AutoRepair;$current.Text=Tg-ConnectionLabel $existing;if([string]$existing.ChatId -like '-*'){$mode.SelectedIndex=1}}

 $resetPair={

  $s=$this.Tag;$s.Pair=$null;$s.Link.Clear();$s.Command.Clear();$s.Copy.Enabled=$false;$s.CopyCommand.Enabled=$false;$s.Confirm.Enabled=$false

  $s.Notice.Text='선택한 수신처로 연결 준비를 누르세요. 저장하기 전까지 기존 알림 수신처가 유지됩니다.'

 }

 $mode.Add_SelectedIndexChanged($resetPair);$tokenInput.Add_TextChanged($resetPair)

 $prepare.Add_Click({

  $s=$this.Tag;$s.Pair=$null;$s.Link.Clear();$s.Command.Clear();$s.Copy.Enabled=$false;$s.CopyCommand.Enabled=$false;$s.Confirm.Enabled=$false;$s.Prepare.Enabled=$false

  try{

   $s.Notice.Text='텔레그램 연결 준비 중...';$s.Form.Refresh();$target=if($s.Mode.SelectedIndex -eq 1){'group'}else{'private'}

   $s.Pair=Tg-PreparePair $s.Root $s.Input.Text.Trim() $target;$s.Link.Text=$s.Pair.Link;$s.Command.Text=$s.Pair.Command

   $s.Copy.Enabled=$true;$s.CopyCommand.Enabled=$true;$s.Confirm.Enabled=$true

   $s.Notice.Text=if($target -eq 'group'){'단톡방에 가족과 봇을 초대하고, 본인 계정으로 연결 명령을 보내세요. 이어서 연결 확인·저장을 누르면 단톡방으로 테스트 알림을 보냅니다. (10분 이내)'}else{'연결 주소를 열고 시작을 누르거나, 봇과의 개인 채팅에 연결 명령을 보내세요. 이어서 연결 확인·저장을 누르세요. (10분 이내)'}

  }catch{$s.Notice.Text=Tg-PairError $_.Exception.Message}finally{$s.Prepare.Enabled=$true}

 })

 $copy.Add_Click({if($this.Tag.Pair){[Windows.Forms.Clipboard]::SetText($this.Tag.Pair.Link)}})

 $copyCommand.Add_Click({if($this.Tag.Pair){[Windows.Forms.Clipboard]::SetText($this.Tag.Pair.Command)}})

 $confirm.Add_Click({

  $s=$this.Tag;$s.Confirm.Enabled=$false;$s.Prepare.Enabled=$false

  try{$s.Notice.Text='연결 메시지 확인 및 테스트 알림 전송 중...';$s.Form.Refresh();$c=Tg-CompletePair $s.Root $s.Pair $s.Repair.Checked $s.Codex.Text;$s.Current.Text=Tg-ConnectionLabel $c;$s.Pair=$null;$s.Link.Clear();$s.Command.Clear();$s.Copy.Enabled=$false;$s.CopyCommand.Enabled=$false;$s.Notice.Text='저장 완료. 표시된 수신처로 테스트 알림을 보냈습니다. 단톡방은 참여한 가족이 함께 받으며, 개인 채팅에 중복 전송하지 않습니다.'}

  catch{$s.Notice.Text=Tg-PairError $_.Exception.Message}

  finally{$s.Prepare.Enabled=$true;$s.Confirm.Enabled=($null -ne $s.Pair)}

 })

 $returnPrivate.Add_Click({

  $s=$this.Tag

  try{$c=Tg-UsePrivate $s.Root;$s.Pair=$null;$s.Mode.SelectedIndex=0;$s.Link.Clear();$s.Command.Clear();$s.Copy.Enabled=$false;$s.CopyCommand.Enabled=$false;$s.Confirm.Enabled=$false;$s.Current.Text=Tg-ConnectionLabel $c;$s.Notice.Text='저장 완료. 기존 개인 채팅으로 알림 수신처를 되돌렸습니다.'}catch{$s.Notice.Text=Tg-PairError $_.Exception.Message}

 })

 $disable.Add_Click({

  $s=$this.Tag

  try{$c=Tg-Load $s.Root;if($c){$c.Enabled=$false;$c.AutoRepair=$false;Tg-Save $s.Root $c};$s.Current.Text=Tg-ConnectionLabel $c;$s.Notice.Text='알림·자동수정을 껐습니다. 프로그램 자체 조회와 기본 재시도는 계속됩니다.'}catch{$s.Notice.Text=Tg-PairError $_.Exception.Message}

 })

 try{[void]$d.ShowDialog($owner)}finally{$tokenInput.Clear();$state.Pair=$null;$d.Dispose()}

}


# Telegram start decisions are ephemeral and belong to one running UI process.
# No command file, persistent auto-start preference or broker transport is used here.
function TgC-NewState {
 return @{Prompt=$null;OfferedKey='';Offset=$null;ConfigHash='';ActiveNotified=$false;Code='WAITING';NextOffer=[datetime]::MinValue;OfferAttempts=0}
}
function TgC-ViewValid($view,[datetime]$now){
 try{return ($view -and $view.RunId -cmatch '^[a-fA-F0-9-]{36}$' -and $view.Scope -cmatch '^[a-f0-9]{64}$' -and $view.SourceHash -cmatch '^[a-f0-9]{64}$' -and $view.Ready -is [bool] -and $view.Active -is [bool] -and $view.AutoEnabled -is [bool] -and $view.Blocked -is [bool] -and ($now-(Ops-Utc $view.Utc)).TotalSeconds -ge -2 -and ($now-(Ops-Utc $view.Utc)).TotalSeconds -le 15)}catch{return $false}
}
function TgC-Key($view,[string]$configHash){return (Ops-Key ($view.RunId+'|'+$view.Scope+'|'+$view.SourceHash+'|'+$configHash))}
function TgC-CanOffer($view,[datetime]$now){return ((TgC-ViewValid $view $now) -and $view.Ready -and !$view.AutoEnabled -and !$view.Blocked -and !$view.Active)}
function TgC-NewPrompt($view,$config,[string]$configHash,[datetime]$now){
 if(!(TgC-CanOffer $view $now) -or !(Tg-OwnerId $config) -or !(Ops-Get $config 'Enabled' $false)){throw 'TG_START_NOT_READY'}
 return @{Nonce=[guid]::NewGuid().ToString('N');RunId=$view.RunId;Scope=$view.Scope;SourceHash=$view.SourceHash;ConfigHash=$configHash;OwnerId=(Tg-OwnerId $config);ChatId=[string]$config.ChatId;ThreadId=[long](Ops-Get $config 'MessageThreadId' 0);MessageId=0L;ExpiresUtc=$now.AddMinutes(10).ToString('o');State='SENDING';Key=(TgC-Key $view $configHash)}
}
function TgC-PromptBody($prompt,$view){
 $device='메인PC'
 $text='실주문 시작하시겠습니까?'+[Environment]::NewLine+'기기: '+$device+' / 종목: '+$view.Symbol+[Environment]::NewLine+'기존 30분할 전략 · 하루 새 매수 차수 최대 3개'+[Environment]::NewLine+'이번 실행의 시작 승인입니다. 버튼은 10분 동안 유효합니다.'
 $row=@(@{text='Yes';callback_data=('avstart:Y:'+$prompt.Nonce)},@{text='No';callback_data=('avstart:N:'+$prompt.Nonce)})
 $body=@{chat_id=$prompt.ChatId;text=$text;protect_content=$true;reply_markup=@{inline_keyboard=@(,$row)}}
 if($prompt.ThreadId -gt 0){$body.message_thread_id=$prompt.ThreadId};return $body
}
function TgC-Callback($prompt,$callback,$view,[string]$configHash,[datetime]$now){
 if(!$prompt -or !$callback){return 'IGNORE'}
 $from=Ops-Get $callback 'from';$message=Ops-Get $callback 'message';$chat=Ops-Get $message 'chat'
 if([string](Ops-Get $from 'id') -cne $prompt.OwnerId -or (Ops-Get $from 'is_bot' $true)){return 'UNAUTHORIZED'}
 if(!$message -or (Ops-Get $callback 'inline_message_id') -or [string](Ops-Get $chat 'id') -cne $prompt.ChatId -or [long](Ops-Get $message 'message_thread_id' 0) -ne $prompt.ThreadId -or [long](Ops-Get $message 'message_id' 0) -ne $prompt.MessageId -or $prompt.MessageId -le 0){return 'IGNORE'}
 $data=[string](Ops-Get $callback 'data' '');if($data -cnotin @(('avstart:Y:'+$prompt.Nonce),('avstart:N:'+$prompt.Nonce),('avstart:R:'+$prompt.Nonce))){return 'IGNORE'}
 if($data -ceq ('avstart:R:'+$prompt.Nonce)){
  if($prompt.State -cin @('DECLINED','EXPIRED','FAILED') -and (TgC-CanOffer $view $now) -and $prompt.Key -ceq (TgC-Key $view $configHash)){return 'REFRESH'};return 'USED'
 }
 if($prompt.State -cne 'PENDING'){return 'USED'}
 if($now -ge (Ops-Utc $prompt.ExpiresUtc)){return 'EXPIRED'}
 if(!(TgC-CanOffer $view $now) -or $prompt.Key -cne (TgC-Key $view $configHash)){return 'NOT_READY'}
 if($data -ceq ('avstart:N:'+$prompt.Nonce)){return 'NO'};return 'YES'
}
function TgC-Decision($prompt,[datetime]$now){
 if($prompt.State -cne 'PENDING'){throw 'TG_START_USED'}
 # Consume before any network acknowledgement or cross-thread publication.
 $prompt.State='ACCEPTED';$prompt.ResultDeadline=$now.AddSeconds(30).ToString('o')
 return [pscustomobject]@{Nonce=$prompt.Nonce;RunId=$prompt.RunId;Scope=$prompt.Scope;SourceHash=$prompt.SourceHash;ConfigHash=$prompt.ConfigHash;ExpiresUtc=$now.AddSeconds(20).ToString('o')}
}
function TgC-Edit($config,$prompt,[string]$text,[bool]$retry=$false){
 $markup=@{inline_keyboard=@()}
 if($retry){$row=@(@{text='준비 상태 다시 확인';callback_data=('avstart:R:'+$prompt.Nonce)});$markup.inline_keyboard=@(,$row)}
 if($prompt -and $prompt.MessageId -gt 0){$null=Tg-Call $config.Token 'editMessageText' @{chat_id=$prompt.ChatId;message_id=$prompt.MessageId;text=$text;reply_markup=$markup}}
}
function TgC-Answer($config,$callback,[string]$text){
 if($callback -and (Ops-Get $callback 'id')){$null=Tg-Call $config.Token 'answerCallbackQuery' @{callback_query_id=$callback.id;text=$text;show_alert=$false}}
}
function TgC-Invalidate($state,$config,[string]$text){
 $p=$state.Prompt
 if($p -and $p.State -ceq 'PENDING'){$p.State='INVALID';$state.Prompt=$null;$state.OfferedKey='';try{TgC-Edit $config $p $text}catch{}}
}
function TgC-Step($state,$pipe,$config,[string]$configHash,[datetime]$now){
 $v=$pipe.View
 if(!(TgC-ViewValid $v $now)){$state.Code='WAIT_UI';TgC-Invalidate $state $config '실주문 시작 안내가 만료되었습니다. 프로그램 상태를 확인해 주세요.';return}
 if($state.ConfigHash -cne $configHash){
  # A re-pairing invalidates all old buttons. Never edit another bot's message.
  $state.Prompt=$null;$state.OfferedKey='';$state.Offset=$null;$state.ConfigHash=$configHash;$state.ActiveNotified=$false;$state.OfferAttempts=0
 }
 if($v.Active){
  TgC-Invalidate $state $config '실주문 시작이 확인되었습니다.'
  # Daily market notices are owned by the persistent manager outbox.
  $state.ActiveNotified=$true
  $state.Code='ACTIVE';return
 }
 if((Ops-Get $v 'ArmState' '') -cne 'ARMED'){$state.ActiveNotified=$false}
 $pending=$state.Prompt
 if($pending -and $pending.State -ceq 'ACCEPTED'){
  $failed=$pipe['RejectedNonce'] -ceq $pending.Nonce -or [bool](Ops-Get $v 'CommandError' '') -or $now -ge (Ops-Utc $pending.ResultDeadline)
  if($failed){Tg-Notify $config '실주문 시작을 완료하지 못했습니다. 준비 상태가 바뀌었거나 요청 확인 시간이 지났습니다. 자동으로 재시도하지 않습니다.';$pending.State='FAILED';try{TgC-Edit $config $pending '실주문 시작을 완료하지 못했습니다. 준비 상태를 다시 확인할 수 있습니다.' $true}catch{}}
 }
 if(!(TgC-CanOffer $v $now)){$state.Code='WAIT_READY';TgC-Invalidate $state $config '준비 상태가 바뀌어 이 시작 버튼을 해제했습니다.';return}
 if(!(Tg-OwnerId $config)){$state.Code='OWNER_PAIR_REQUIRED';return}
 $key=TgC-Key $v $configHash
 if($state.OfferedKey -cne $key){
  TgC-Invalidate $state $config '실행 정보가 바뀌어 이 시작 버튼을 해제했습니다.'
  $state.Prompt=$null;$state.OfferedKey=$key;$state.OfferAttempts=0;$state.NextOffer=[datetime]::MinValue
 }
 if(!$state.Prompt -and $state.OfferAttempts -lt 3 -and $now -ge $state.NextOffer){
  $p=TgC-NewPrompt $v $config $configHash $now;$state.OfferAttempts++;$state.NextOffer=$now.AddMinutes(1)
  $sent=Tg-Call $config.Token 'sendMessage' (TgC-PromptBody $p $v)
  if([string](Ops-Get (Ops-Get $sent 'chat') 'id') -cne $p.ChatId -or [long](Ops-Get $sent 'message_id' 0) -le 0){throw 'TG_PROMPT_RESPONSE'}
  $p.MessageId=[long]$sent.message_id;$p.State='PENDING';$state.Prompt=$p
 }
 $p=$state.Prompt
 if(!$p){$state.Code='SEND_WAIT';return}
 if($p.State -ceq 'PENDING' -and $now -ge (Ops-Utc $p.ExpiresUtc)){
  $p.State='EXPIRED';try{TgC-Edit $config $p '실주문 시작 안내가 만료되었습니다. 자동으로 시작하지 않았습니다.' $true}catch{}
 }
 if($p.State -cnotin @('PENDING','DECLINED','EXPIRED','FAILED')){$state.Code=$p.State;return}
 $body=@{timeout=3;limit=100;allowed_updates=@('callback_query')};if($null -ne $state.Offset){$body.offset=$state.Offset}
 $updates=@(Tg-Call $config.Token 'getUpdates' $body)
 foreach($update in $updates){
  $id=Ops-Get $update 'update_id';if($null -ne $id){$state.Offset=[math]::Max([long]$state.Offset,[long]$id+1)}
  $cb=Ops-Get $update 'callback_query';if(!$cb){continue}
  # The request may have taken seconds: never approve against the pre-request view.
  $decision=TgC-Callback $p $cb $pipe.View $configHash (Ops-Now)
  $answer='이 버튼은 현재 사용할 수 없습니다.'
  if($decision -ceq 'YES'){
   $approval=TgC-Decision $p (Ops-Now)
   [Threading.Monitor]::Enter($pipe.SyncRoot)
   try{if(!$pipe.Stop -and !$pipe.Paused -and !$pipe.Decision){$pipe.Decision=$approval;$answer='최신 준비 상태를 다시 확인합니다.'}}finally{[Threading.Monitor]::Exit($pipe.SyncRoot)}
   try{TgC-Edit $config $p '시작 요청을 확인했습니다. 실제 시작 결과를 다시 알려드립니다.'}catch{}
  }elseif($decision -ceq 'NO'){$p.State='DECLINED';$answer='실주문을 시작하지 않습니다.';try{TgC-Edit $config $p '실주문 시작을 보류했습니다. 자동으로 시작하지 않습니다.' $true}catch{}}
  elseif($decision -ceq 'REFRESH'){$p.State='REFRESHED';$state.Prompt=$null;$state.OfferedKey='';$answer='최신 준비 상태로 다시 안내합니다.';try{TgC-Edit $config $p '새 준비 알림을 요청했습니다. 새 알림에서 선택해 주세요.'}catch{}}
  elseif($decision -ceq 'UNAUTHORIZED'){$answer='텔레그램을 연결한 사용자만 선택할 수 있습니다.'}
  elseif($decision -cin @('NOT_READY','EXPIRED')){$p.State='INVALID';try{TgC-Edit $config $p '준비 상태가 바뀌거나 유효시간이 지나 시작하지 않았습니다.'}catch{}}
  try{TgC-Answer $config $cb $answer}catch{}
 }
 $state.Code=$p.State
}
function TgC-Run($pipe,[string]$management){
 $state=TgC-NewState;$next=[datetime]::MinValue;$config=$null
 try{
  while(!$pipe.Stop){
   if($pipe.Paused){TgC-Invalidate $state $config '설정 변경으로 이 시작 버튼을 해제했습니다.';Start-Sleep -Milliseconds 250;continue}
   if((Ops-Now) -lt $next){Start-Sleep -Milliseconds 200;continue}
   try{
    $config=Tg-Load $management
    if(!$config -or !(Ops-Get $config 'Enabled' $false)){$state.Prompt=$null;$state.ConfigHash='';$state.Code='DISABLED';$next=(Ops-Now).AddSeconds(5)}
    else{
     $fingerprint=Ops-Hash (Join-Path $management 'telegram.dpapi')
     if($state.ConfigHash -cne $fingerprint){$web=Tg-Call $config.Token 'getWebhookInfo' @{};if(Ops-Get $web 'url'){throw 'TG_WEBHOOK_IN_USE'}}
     TgC-Step $state $pipe $config $fingerprint (Ops-Now);$next=(Ops-Now).AddSeconds(2)
    }
   }catch{$state.Code='CONNECTION_WAIT';$next=(Ops-Now).AddSeconds([math]::Max(10,[math]::Min(300,[int]$_.Exception.Data['RetryAfter'])))}
   # Bounded diagnostics; no token, chat/user ID, callback data or account identity.
   try{Ops-WriteJson (Join-Path $management 'telegram-control-status.json') @{Schema='AT-TG-CONTROL-1';Utc=(Ops-Now).ToString('o');State=$state.Code}}catch{}
  }
 }finally{TgC-Invalidate $state $config '프로그램이 종료되어 이 시작 버튼을 해제했습니다.'}
}
