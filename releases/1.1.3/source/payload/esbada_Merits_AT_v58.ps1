param(

 [switch]$Once,

 [string]$DataRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'esbada_AT_direct'),

 [string]$ImportMtCredentialPath,

 [string]$Symbol='0210A0',

 [switch]$AutoStart,

 [string]$RunId=([guid]::NewGuid().ToString()),

 [string]$OperationsRoot,

 [string]$ManagementRoot,

 [int]$HostProtocol=1

)

$ErrorActionPreference='Stop'

. (Join-Path $PSScriptRoot 'At58.Core.ps1')

$managed=![string]::IsNullOrWhiteSpace($OperationsRoot)

if($managed){. (Join-Path $OperationsRoot 'At58.Ops.ps1');. (Join-Path $OperationsRoot 'At58.Telegram.ps1');. (Join-Path $OperationsRoot 'At58.Sheets.ps1')}

$DataRoot=[IO.Path]::GetFullPath($DataRoot)

# Every process sharing this state directory uses one lock, including -Once.

$created=$false;$mutex=[Threading.Mutex]::new($true,('Local\esbada-AT-direct-'+(At58-Hash $DataRoot.ToLowerInvariant()).Substring(0,24)),[ref]$created)

if(!$created){$mutex.Dispose();throw '이 상태 폴더의 AT 직접 조회가 이미 실행 중입니다.'}

try{

 if($ImportMtCredentialPath){At58-ImportMtCredential $DataRoot $ImportMtCredentialPath}

 if($Once){

  try{$ctx=At58-Context $DataRoot $Symbol;$r=At58-Cycle $ctx;$r.Status|ConvertTo-Json -Compress;if(!$r.Ok){exit 1}}catch{$e=At58-Error $_;[pscustomobject]@{State='STOPPED';Code=$e.Code;Stage=$e.Stage;ExecutionEnabled=$false}|ConvertTo-Json -Compress;exit 1}finally{if(Get-Variable ctx -ErrorAction SilentlyContinue){$ctx=$null}}

  exit

 }

 Add-Type -AssemblyName System.Windows.Forms

 Add-Type -AssemblyName System.Drawing

 [Windows.Forms.Application]::EnableVisualStyles()

 . (Join-Path $PSScriptRoot 'At58.Log.ps1')

 At58Window-Native
 $script:At58TrayEnabled=At58Window-UseTray $DataRoot
 $script:At58WindowChanging=$false
 $form=[AvataTrayWindow]::new();$form.TrayHidden=At58Window-LoadTray $DataRoot;$form.ShowInTaskbar=!$form.TrayHidden;$form.Text='Avata 1.1.3 — 계좌 조회·실전 제어';$form.Size=[Drawing.Size]::new(1120,870);$form.MinimumSize=[Drawing.Size]::new(1000,760);$form.StartPosition='CenterScreen'

 $layout=[Windows.Forms.TableLayoutPanel]::new();$layout.Dock='Fill';$layout.ColumnCount=1;$layout.RowCount=8;$layout.Padding=[Windows.Forms.Padding]::new(12)

 foreach($h in @(42,40,48,78)){[void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute',$h))}

 foreach($weight in @(20,40,40)){[void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent',$weight))};[void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute',42));$form.Controls.Add($layout)

 $font=[Drawing.Font]::new('Malgun Gothic',10);$form.Font=$font

 $intro=[Windows.Forms.Label]::new();$intro.Dock='Fill';$intro.Text='실계좌 직접 조회 · 30분할 전략 · 주문·체결 관리'+[Environment]::NewLine+'실전 제어 탭에서 원장 준비와 사용자 시작을 구분합니다. 자동 시작 설정 계좌는 준비 완료 후 실주문을 시작합니다.';$layout.Controls.Add($intro,0,0)

 $bar=[Windows.Forms.FlowLayoutPanel]::new();$bar.Dock='Fill';$bar.WrapContents=$false

 $import=[Windows.Forms.Button]::new();$import.Text='기존 메리츠 키 가져오기';$import.Width=190

 $manual=[Windows.Forms.Button]::new();$manual.Text='키 직접 입력';$manual.Width=110

 $start=[Windows.Forms.Button]::new();$start.Text='직접 조회 시작';$start.Width=130

 $stop=[Windows.Forms.Button]::new();$stop.Text='일시정지';$stop.Width=100

 $settings=[Windows.Forms.Button]::new();$settings.Text='텔레그램·자동관리';$settings.Width=170;$settings.Enabled=$managed;$settings.Add_Click({$script:At58TelegramSettings=$true;if($script:At58Telegram){$script:At58Telegram.Pipe.Paused=$true};try{Tg-ShowSettings $form $ManagementRoot}finally{$script:At58TelegramSettings=$false}})

 $sheetSettings=[Windows.Forms.Button]::new();$sheetSettings.Text='시트 연동';$sheetSettings.Width=110;$sheetSettings.Enabled=$managed;$sheetSettings.Add_Click({Sheet-ShowSettings $form $ManagementRoot})

 $trayMode=[Windows.Forms.CheckBox]::new();$trayMode.Text='트레이 사용';$trayMode.Width=100;$trayMode.Height=26;$trayMode.Checked=$script:At58TrayEnabled
 $bar.Controls.AddRange(@($import,$manual,$start,$stop,$settings,$sheetSettings,$trayMode));$layout.Controls.Add($bar,0,1)

 $status=[Windows.Forms.Label]::new();$status.Dock='Fill';$status.Font=[Drawing.Font]::new('Malgun Gothic',12,[Drawing.FontStyle]::Bold);$status.Text='연결 준비 · 저장된 메리츠 키를 가져오거나 직접 입력하세요.';$layout.Controls.Add($status,0,2)

 $summary=[Windows.Forms.Label]::new();$summary.Dock='Fill';$summary.Text='이번 실행에서 조회한 값이 없습니다.';$layout.Controls.Add($summary,0,3)

 function New-At58Grid($labels){$g=[Windows.Forms.DataGridView]::new();$g.Dock='Fill';$g.ReadOnly=$true;$g.AllowUserToAddRows=$false;$g.AllowUserToDeleteRows=$false;$g.RowHeadersVisible=$false;$g.AutoSizeColumnsMode='Fill';foreach($x in $labels){[void]$g.Columns.Add($x,$x)};return $g}

 $holdGrid=New-At58Grid @('보유 종목','구분','수량','매입단가','현재가','평가금액(원)','평가손익(원)');$layout.Controls.Add($holdGrid,0,4)

 $orderGrid=New-At58Grid @('주문일','범위','종목','주문번호','매매','주문수량','체결','남은수량','주문가격');$orderTabs=[Windows.Forms.TabControl]::new();$orderTabs.Dock='Fill'

 $accountTab=[Windows.Forms.TabPage]::new('계좌 미체결');$accountTab.Controls.Add($orderGrid)

 $paperTab=[Windows.Forms.TabPage]::new('통합 모의 주문');$paperGrid=New-At58Grid @('주문일','차수','매매','지정가','수량','모의체결','잔량','상태');$paperTab.Controls.Add($paperGrid)

 $planTab=[Windows.Forms.TabPage]::new('30차수 계획');$planGrid=New-At58Grid @('차수','매수가','매수수량','매도가','매도수량','보유 상태');$planTab.Controls.Add($planGrid)

 $receiptTab=[Windows.Forms.TabPage]::new('실제 접수·체결 통보');$receiptGrid=New-At58Grid @('일자','시각','주문번호','종류','매매','종목','수량','가격','대조 상태','출처');$receiptTab.Controls.Add($receiptGrid)

 $receiptGrid.Columns[8].FillWeight=240;$receiptGrid.Columns[6].FillWeight=60;$receiptGrid.Columns[4].FillWeight=60

 $receiptLabel=[Windows.Forms.Label]::new();$receiptLabel.Dock='Top';$receiptLabel.Height=44;$receiptLabel.Text='통보 연결 대기 · 수수료 미확정 / 기존 수동매매 기록은 그대로 유지';$receiptTab.Controls.Add($receiptLabel)

 $tradeTab=[Windows.Forms.TabPage]::new('주문 관리');$tradeGrid=New-At58Grid @('주문일','작업','주문번호','대상 주문','매매','수량','체결','잔량','상태');$tradeTab.Controls.Add($tradeGrid);$tradeGrid.Columns[8].FillWeight=240

 $tradeLabel=[Windows.Forms.Label]::new();$tradeLabel.Dock='Top';$tradeLabel.Height=44;$tradeLabel.Text='주문 관리 준비 · 실제 전송 꺼짐';$tradeTab.Controls.Add($tradeLabel)

   $readinessTab=[Windows.Forms.TabPage]::new('실전 준비 점검');$readinessGrid=New-At58Grid @('점검 항목','상태','내용');$readinessGrid.Columns[2].FillWeight=330;$readinessTab.Controls.Add($readinessGrid)

  $readinessLabel=[Windows.Forms.Label]::new();$readinessLabel.Dock='Top';$readinessLabel.Height=44;$readinessLabel.Text='실주문 실행 미연결 · 현재 버전은 모의 운용 / 시트의 허용은 실주문 스위치가 아닙니다.';$readinessTab.Controls.Add($readinessLabel)

  $orderTabs.TabPages.AddRange(@($accountTab,$paperTab,$planTab,$receiptTab,$tradeTab,$readinessTab));$orderTabs.SelectedIndex=1;$layout.Controls.Add($orderTabs,0,5)

 $script:At58LiveBox=At58X-Mailbox $RunId

 $liveTab=[Windows.Forms.TabPage]::new('실전 제어')

 $liveGrid=New-At58Grid @('주문일','차수','매매','주문번호','작업','주문량','체결량','잔량','상태')

 $liveTab.Controls.Add($liveGrid)

 $liveBar=[Windows.Forms.FlowLayoutPanel]::new();$liveBar.Dock='Top';$liveBar.Height=38;$liveBar.WrapContents=$false

 $livePrepare=[Windows.Forms.Button]::new();$livePrepare.Text='실계좌 원장 준비';$livePrepare.Width=155

 $liveArm=[Windows.Forms.Button]::new();$liveArm.Text='실주문 시작';$liveArm.Width=130;$liveArm.Enabled=$false

 $liveStop=[Windows.Forms.Button]::new();$liveStop.Text='정지·AT 잔량취소';$liveStop.Width=165

 $liveAuto=[Windows.Forms.CheckBox]::new();$liveAuto.Text='실행 후 준비되면 자동 시작';$liveAuto.Width=250;$liveAuto.Height=30;$liveAuto.Enabled=$false
 $autoStatus=[Windows.Forms.Label]::new();$autoStatus.Dock='Top';$autoStatus.Height=24;$autoStatus.Text='실행 후 자동 시작: 꺼짐';$liveTab.Controls.Add($autoStatus)
 $liveBar.Controls.AddRange(@($livePrepare,$liveArm,$liveStop,$liveAuto));$liveTab.Controls.Add($liveBar)

 $liveLabel=[Windows.Forms.Label]::new();$liveLabel.Dock='Top';$liveLabel.Height=84

 $liveLabel.Text=if($HostProtocol -eq 2){'실주문 꺼짐 · 원장 준비 → 계좌 대조 → 하루 3차수 · 사용자 시작'+[Environment]::NewLine+'자동 시작을 설정한 계좌는 재시작·업데이트 뒤 준비 완료 시 실주문을 시작합니다.'}else{'실전 관리자 연결 전 · 새 Start_AT58.cmd로 관리자 교체가 필요합니다.'}

 $liveTab.Controls.Add($liveLabel);$orderTabs.TabPages.Add($liveTab)

 $livePrepare.Enabled=$managed -and $HostProtocol -eq 2;$liveStop.Enabled=$false

 $updateButton=[Windows.Forms.Button]::new();$updateButton.Text='업데이트 확인 중';$updateButton.Width=188;$updateButton.Dock='Right';$updateButton.Enabled=$false
 $header=[Windows.Forms.Panel]::new();$header.Dock='Fill';$layout.Controls.Remove($intro);$header.Controls.Add($intro);$header.Controls.Add($updateButton);$intro.Padding=[Windows.Forms.Padding]::new(0,0,198,0);$layout.Controls.Add($header,0,0)
 $script:At58Update=$null;$script:At58UpdateQueued=$false
 function Update-Render {
  if(!$managed){$updateButton.Text='업데이트 관리자 필요';return}
  $u=Ops-ReadJson (Join-Path $ManagementRoot 'update-status.json');$manager=Ops-ReadJson (Join-Path $ManagementRoot 'manager-status.json');$script:At58Update=$null;$updateButton.Enabled=$false
  if(!$u -or $u.Schema -cne 'AVATA-UPDATE-STATUS-1' -or !$manager -or $u.HostSession -cne $manager.HostSession -or $u.RunId -cne $RunId){$updateButton.Text='업데이트 관리자 확인';return}
  $age=([datetime]::UtcNow-(Ops-Utc $u.Utc)).TotalSeconds
  if($age -lt -5 -or $age -gt 20){$updateButton.Text='업데이트 연결 확인';return}
  $script:At58Update=$u
  $labels=@{REJECTED='업데이트 검증 확인';AVAILABLE='업데이트 확인 필요';CURRENT='최신 버전 확인됨';CHECKING='업데이트 확인 중';CHECK_FAILED='업데이트 연결 확인';UNCONFIGURED='업데이트 주소 미설정';WAITING_FOR_ORDERS='주문 정리 후 업데이트';APPLYING='업데이트 적용 중'}
  $updateButton.Text=$labels[[string]$u.State];if(!$updateButton.Text){$updateButton.Text='업데이트 상태 확인'}
  $updateButton.Enabled=($u.State -ceq 'AVAILABLE' -and !$script:At58UpdateQueued)
  $updateButton.BackColor=if($u.State -ceq 'AVAILABLE'){[Drawing.Color]::LightGoldenrodYellow}else{[Drawing.SystemColors]::Control}
 }
 $updateButton.Add_Click({
  try{
   Update-Render;$u=$script:At58Update;if(!$u -or $u.State -cne 'AVAILABLE' -or !$u.Available){return}
   $message=$u.Available.Version+' 버전으로 업데이트합니다.'+[Environment]::NewLine+'실주문과 AT 미체결 잔량을 정리한 뒤 프로그램이 자동으로 다시 열립니다.'+[Environment]::NewLine+'PC 재부팅은 필요 없습니다. 자동 시작 설정이 켜져 있으면 업데이트 검증 후 실주문을 다시 시작합니다.'
   if([Windows.Forms.MessageBox]::Show($message,'업데이트 확인 필요','OKCancel','Information') -ne 'OK'){return}
   Live-AutoSuspend 'STOPPED'
   if($script:At58LiveBox.Mode -ceq 'LIVE'){At58X-Queue $script:At58LiveBox 'STOP';Live-RequestRead}
   Ops-WriteJson (Join-Path $ManagementRoot 'update-request.json') @{Schema='AVATA-UPDATE-REQUEST-1';Action='APPLY';Utc=[datetime]::UtcNow.ToString('o');HostSession=$u.HostSession;RunId=$RunId;Id=$u.Available.Id;ManifestHash=$u.Available.ManifestHash}
   $script:At58UpdateQueued=$true;$script:At58UpdateQueuedAt=[datetime]::UtcNow;$updateButton.Enabled=$false;$updateButton.Text='주문 정리 후 업데이트';$liveArm.Enabled=$false
   # A paused reader must complete its existing account reconciliation before switching.
   if($script:At58Ui.CredentialReady){$script:At58Ui.RequestedRunning=$true;$script:At58Ui.Running=$true;$script:At58Ui.Next=[datetime]::MinValue}
  }catch{$updateButton.Text='업데이트 요청 확인 필요';$script:At58UpdateQueued=$false}
 })

 function Live-RequestRead {

  $script:At58Ui.RequestedRunning=$true;$script:At58Ui.Running=$true;$script:At58Ui.Fault='';$script:At58Ui.Next=[datetime]::MinValue

  $start.Enabled=$false;$import.Enabled=$false;$manual.Enabled=$false;Save-At58Runtime

 }

 $script:At58Telegram=$null;$script:At58TelegramSettings=$false
 function Live-TelegramTick {
  if(!$managed -or $HostProtocol -ne 2){return}
  if(!$script:At58Telegram){
   $pipe=[hashtable]::Synchronized(@{Stop=$false;Paused=$false;View=$null;Decision=$null;RejectedNonce=''})
   $worker=[PowerShell]::Create()
   [void]$worker.AddScript('param($ops,$telegram,$pipe,$management); . $ops; . $telegram; TgC-Run $pipe $management').AddArgument((Join-Path $OperationsRoot 'At58.Ops.ps1')).AddArgument((Join-Path $OperationsRoot 'At58.Telegram.ps1')).AddArgument($pipe).AddArgument($ManagementRoot)
   $script:At58Telegram=@{Pipe=$pipe;Worker=$worker;Handle=$worker.BeginInvoke()}
  }
  $t=$script:At58Telegram;$pipe=$t.Pipe;$pipe.Paused=$script:At58TelegramSettings
  $u=$script:At58Ui;$box=$script:At58LiveBox;$a=$script:At58Auto;$now=[datetime]::UtcNow
  $blocked=$script:At58TelegramSettings -or $script:At58UpdateQueued -or !$u.Running -or $u.Failed -or [bool]$u.Fault -or [bool]$u.ExitReason -or $u.PauseAfterLiveStop -or !$script:At58AutoOwner -or !$a -or $a.Code -ceq 'PREFERENCE_INVALID'
  $bundle=Ops-ReadJson (Join-Path $ManagementRoot 'bundle-status.json');$manager=Ops-ReadJson (Join-Path $ManagementRoot 'manager-status.json')
  $ready=!$blocked -and (At58AS-Ready $box $bundle $manager $now '58.17.9' $true) -ceq 'READY'
  $active=$false;$activeUtc=''
  if($box.Last -and $box.Last.RunId -ceq $RunId -and $box.State -ceq 'ARMED' -and $box.Last.State -ceq 'ARMED' -and $box.Last.ExecutionEnabled -eq $true -and $box.Last.TestOnly -eq $false){
   try{$age=($now-(Ops-Utc $box.Last.Utc)).TotalSeconds;if($age -ge -2 -and $age -le 30){$active=$true;$activeUtc=$box.Last.Utc}}catch{}
  }
  $scope=if($script:At58AutoOwner){$script:At58AutoOwner.Scope}else{''}
  $pipe.View=[pscustomobject]@{Utc=$now.ToString('o');RunId=$RunId;Scope=$scope;SourceHash=$box.SourceHash;Symbol=$Symbol;Device=$(if($script:At58TrayEnabled){'MINI'}else{'MAIN'});Ready=[bool]$ready;Active=$active;ActiveUtc=$activeUtc;ArmState=$box.State;CommandError=$box.CommandError;AutoEnabled=[bool]($a -and $a.Enabled);Blocked=[bool]$blocked}
  [Threading.Monitor]::Enter($pipe.SyncRoot);try{$decision=$pipe.Decision;$pipe.Decision=$null}finally{[Threading.Monitor]::Exit($pipe.SyncRoot)}
  if($decision){
   $accepted=$false
   if(!$blocked -and !$a.Enabled){$script:At58AutoOwner.RunId=$RunId;$script:At58AutoOwner.Version='58.17.9';$script:At58AutoOwner.ManagementRoot=$ManagementRoot;$accepted=At58TG-TryQueue $script:At58AutoOwner $box $decision $bundle $manager $now}
   if($accepted){Live-RequestRead;$liveArm.Enabled=$false;$liveLabel.Text='텔레그램 시작 요청 확인 중 · 최신 계좌와 주문 조건을 대조합니다.'}
   else{$pipe.RejectedNonce=$decision.Nonce;$liveLabel.Text='텔레그램 시작 보류 · 준비 상태가 변경되었습니다.'}
  }
 }
 function Live-TelegramClose {
  if($script:At58Telegram){$script:At58Telegram.Pipe.Stop=$true;try{$null=$script:At58Telegram.Worker.BeginStop($null,$null)}catch{}}
 }

 $script:At58Auto=$null;$script:At58AutoOwner=$null;$script:At58AutoLoading=$false
 function Live-AutoCheck([bool]$value){$script:At58AutoLoading=$true;try{$liveAuto.Checked=$value}finally{$script:At58AutoLoading=$false}}
 function Live-AutoLoad {
  try{
   if(!$managed -or $HostProtocol -ne 2 -or !$script:At58Ui.CredentialReady){$liveAuto.Enabled=$false;return}
   $script:At58AutoOwner=At58-Context $DataRoot $Symbol
   $pref=At58AS-Load $script:At58AutoOwner;$script:At58Auto=At58AS-NewRun $pref $RunId
   Live-AutoCheck $pref.Enabled;$liveAuto.Enabled=$true
   if($pref.Enabled){Live-RequestRead}
  }catch{$autoStatus.Text='자동 시작 설정 확인 필요';$liveAuto.Enabled=$false}
 }
 function Live-AutoSuspend([string]$reason){if($script:At58Auto){$script:At58Auto.Suspended=$true;$script:At58Auto.Code=$reason}}
 function Live-AutoDisable {
  Live-AutoSuspend 'STOPPED'
  if(!$script:At58Auto -or !$script:At58Auto.Enabled){return}
  $script:At58Auto.Enabled=$false;Live-AutoCheck $false
  try{$null=At58AS-Save $script:At58AutoOwner $false;$autoStatus.Text='자동 시작 꺼짐 · 직접 중지함'}catch{[void][Windows.Forms.MessageBox]::Show('자동 시작 설정을 저장하지 못했습니다. 현재 실행에서는 중지했지만 다음 실행 전에 설정을 확인하세요.','설정 저장 확인','OK','Warning')}
 }
 function Live-AutoTick {
  if(!$script:At58Auto){return}
  $a=$script:At58Auto;$u=$script:At58Ui;$box=$script:At58LiveBox
  if($script:At58UpdateQueued -or $u.ExitReason -or $u.PauseAfterLiveStop){Live-AutoSuspend 'STOPPED'}
  if($a.Enabled -and !$a.Suspended -and !$a.Attempted -and $u.Running -and !$u.Handle -and !$u.Failed -and !$u.Fault){
   $b=Ops-ReadJson (Join-Path $ManagementRoot 'bundle-status.json');$m=Ops-ReadJson (Join-Path $ManagementRoot 'manager-status.json')
   if(At58AS-TryQueue $a $box $b $m ([datetime]::UtcNow) '58.17.9'){Live-RequestRead;$liveArm.Enabled=$false}
  }
  $labels=@{OFF='꺼짐';PREFERENCE_INVALID='저장 설정 확인 필요 · 자동 시작 차단';WAITING='준비 확인 중';WAIT_LEDGER='실계좌 원장 준비 필요';WAIT_COMMAND='조회·요청 처리 대기';WAIT_ACCOUNT='최신 계좌 조회 대기';WAIT_RECONCILE='계좌 대조·주문 확인 대기';WAIT_INSTALL='새 버전 검증 완료 대기';WAIT_MANAGER='관리 상태 확인 대기';WAIT_INVALID_STATUS='상태 확인 대기';READY='시작 준비 완료';QUEUED='시작 요청 확인 중';STOPPED='직접 중지됨';ALREADY_STARTED='이번 실행의 시작 처리 완료';COMMAND_REVIEW='시작 보류 · 수동 확인 필요';RUN_CHANGED='실행 정보 변경 · 시작 보류';MANUAL_START='수동 시작 선택'}
  $text=$labels[[string]$a.Code];if(!$text){$text='상태 확인 중'}
  if($a.Attempted -and $box.State -ceq 'ARMED'){$text='시작 완료 · 기존 전략 조건에 따라 운용'}
  elseif($a.Attempted -and $box.CommandError){$text='시작 보류: '+$box.CommandError+' · 자동 재시도 안 함'}
  $autoStatus.Text='실행 후 자동 시작: '+$text
 }
 $liveAuto.Add_CheckedChanged({
  if($script:At58AutoLoading){return}
  if(!$liveAuto.Checked){Live-AutoDisable;return}
  try{
   if(!$script:At58Ui.CredentialReady -or !$managed -or $HostProtocol -ne 2){throw 'AUTO_NOT_READY'}
   $message='이 PC의 현재 등록 계좌와 종목에 자동 시작을 설정합니다.'+[Environment]::NewLine+'앞으로 실행·재시작·업데이트 후 계좌 대조와 설치 검증이 끝나면 실주문을 자동 승인합니다.'+[Environment]::NewLine+'장중에는 기존 30분할 전략에 따라 실제 주문이 나갈 수 있습니다. 하루 새 매수 차수는 최대 3개입니다.'+[Environment]::NewLine+'정지 또는 일시정지를 누르면 자동 시작 설정도 꺼집니다. 계좌를 바꾸면 다시 설정해야 합니다.'+[Environment]::NewLine+'현재 실행부터 자동 시작을 켤까요?'
   if([Windows.Forms.MessageBox]::Show($message,'실행 후 자동 시작 설정','YesNo','Warning') -ne 'Yes'){Live-AutoCheck $false;return}
   $script:At58AutoOwner=At58-Context $DataRoot $Symbol
   $pref=At58AS-Save $script:At58AutoOwner $true;$pref|Add-Member Code 'WAITING' -Force
   $script:At58Auto=At58AS-NewRun $pref $RunId
   Live-RequestRead
  }catch{Live-AutoCheck $false;Live-AutoSuspend 'COMMAND_REVIEW';$autoStatus.Text='자동 시작 설정 실패 · 수동 확인 필요'}
 })

 function Live-StartConfirm {
  $message='하루에 새로 매수할 차수는 최대 3개입니다.'+[Environment]::NewLine+'같은 차수의 매도 후 재매수는 추가로 세지 않습니다.'+[Environment]::NewLine+'가격·수량은 기존 30분할 전략과 주문가능현금으로 계산합니다.'+[Environment]::NewLine+'실제 계좌 자동매매를 시작할까요?'
  if([Windows.Forms.MessageBox]::Show($message,'실주문 시작 · 하루 3차수','YesNo','Question') -ne 'Yes'){return $null}
  return (At58D-Limits)
 }
 $livePrepare.Add_Click({

  try{

   if(!$script:At58Ui.CredentialReady){$liveLabel.Text='먼저 인증 정보를 등록하세요.';return}

   At58X-Queue $script:At58LiveBox 'PREPARE';Live-RequestRead;$orderTabs.SelectedTab=$liveTab

  }catch{$liveLabel.Text='준비 대기: '+(At58-Error $_).Code}

 })

 $liveArm.Add_Click({

  try{

   if($script:At58UpdateQueued){return}; $box=$script:At58LiveBox;$b=Ops-ReadJson (Join-Path $ManagementRoot 'bundle-status.json')

   if(!$b -or $b.Version -cne '58.17.9' -or $b.State -cnotin @('CURRENT','DISABLED','REJECTED') -or ([datetime]::UtcNow-(Ops-Utc $b.Utc)).TotalSeconds -gt 20){$liveLabel.Text='현재 버전의 설치 검증 완료를 기다리고 있습니다.';return}

   if($box.Command -or $box.Busy -or !$box.Last -or !$box.Last.Reconciled -or $box.Last.State -cne 'DISARMED' -or $box.Last.UncertainOrders){$liveLabel.Text='최신 계좌 대조와 주문 확인을 먼저 완료해야 합니다.';return}

   $limits=Live-StartConfirm;if(!$limits){return};Live-AutoSuspend 'MANUAL_START'

   At58X-Queue $box 'ARM' $box.SourceHash $limits;Live-RequestRead;$liveArm.Enabled=$false;$liveLabel.Text='사용자 시작 요청 확인 중 · 하루 3차수와 주문 조건을 대조합니다.'

  }catch{$liveLabel.Text='시작 보류: '+(At58-Error $_).Code}

 })

 $liveStop.Add_Click({try{Live-AutoDisable;At58X-Queue $script:At58LiveBox 'STOP';Live-RequestRead;$liveArm.Enabled=$false;$liveLabel.Text='신규 주문 중지 · AT 미체결 잔량 확인 및 취소 중'}catch{$liveLabel.Text='정지 요청 확인 필요: '+(At58-Error $_).Code}})

 function Live-Render($s,$r){

  $box=$script:At58LiveBox;$l=At58-Value $s 'Live';if(!$l){return}

  $labels=@{DISARMED='실주문 꺼짐';ARMED='실주문 실행 중';STOPPING='신규 중지·잔량취소 중';REVIEW='주문 확인 필요·신규 중지'}
  if($l.State -ceq 'ARMED'){
   if($l.Code -ceq 'LIVE_MARKET_WAIT'){$labels.ARMED='실주문 승인 유지 · 다음 장 대기'}
   elseif($l.Code -ceq 'LIVE_CLOSE_WAIT'){$labels.ARMED='실주문 승인 유지 · 마감 전 신규 주문 대기'}
   elseif(!$l.Reconciled){$labels.ARMED='실주문 승인 유지 · 계좌 대조 대기'}
  }

  $liveLabel.Text=$labels[$l.State]+' / '+$l.Code+' / '+$(if($l.Reconciled){'계좌 대조 완료'}else{'계좌 대조 대기'})+' / 실제 주문 전송 '+$l.OrdersSent+'건'

  $p=At58-Value $l 'Portfolio'

  if($p){$liveLabel.Text+=[Environment]::NewLine+'전략 원장 '+$p.Qty+'주 / 현금 '+([decimal]$p.Cash).ToString('N0')+'원 / 신규 체결 비용 '+$p.ActualCosts+'원 · 일별 합계 대조'}

  $daily=At58-Value $l 'DailyStages';if($daily){$liveLabel.Text+=[Environment]::NewLine+$daily.Text}
  if($box.CommandError){$liveLabel.Text+=[Environment]::NewLine+'사용자 요청 보류: '+$box.CommandError}

  $liveGrid.Rows.Clear();foreach($o in $l.Orders){[void]$liveGrid.Rows.Add($o.Day,$o.Intent.Stage,$o.Intent.Side,$o.BrokerId,$o.Action,$o.Intent.Qty,$o.Filled,$o.Remaining,(At58T-Label $o.State))}

  $planGrid.Rows.Clear();if($l.Plan){foreach($p in $l.Plan.Rows){[void]$planGrid.Rows.Add($p.Stage,$p.BuyPrice,$p.BuyQty,$p.SellPrice,$p.SellQty,$(if($p.Held){'보유'}else{'미보유'}))}}

  $paperGrid.Rows.Clear();$paperTab.Text='모의 주문 (중지)';$tradeLabel.Text='실제 주문은 실전 제어 탭에서 확인합니다.';$tradeGrid.Rows.Clear()

  $receiptLabel.Text=$s.Execution.Text+' / 계좌 접수·체결 통보 / 비용은 실전 원장의 일별 합계로 대조'

  $readinessLabel.Text='실전 실행 경로 연결 / 현재 상태: '+$labels[$l.State];$readinessGrid.Rows.Clear()

  [void]$readinessGrid.Rows.Add('실전 관리자','연결','프로토콜 '+$HostProtocol)

  [void]$readinessGrid.Rows.Add('실계좌 원장',$(if($l.Reconciled){'대조 완료'}else{'대기'}),$l.Code)

  [void]$readinessGrid.Rows.Add('사용자 시작',$labels[$l.State],'자동 시작 설정 여부는 실전 제어 탭에서 확인합니다.')

  $status.Text='계좌 조회 / '+$labels[$l.State]+' / '+$l.Code

  $livePrepare.Enabled=$false

  $liveStop.Enabled=$managed -and $HostProtocol -eq 2

  $liveArm.Enabled=$HostProtocol -eq 2 -and $l.State -ceq 'DISARMED' -and $l.Reconciled -and !$box.Command -and !$box.Busy -and !$script:At58UpdateQueued

  if($script:At58Ui.PauseAfterLiveStop -and $l.State -ceq 'DISARMED' -and !$box.Last.OpenOrders -and !$box.Last.UncertainOrders){$script:At58Ui.PauseAfterLiveStop=$false;$script:At58Ui.RequestedRunning=$false;$script:At58Ui.Running=$false;Save-At58Runtime}

 }

 function Live-RenderUnavailable {

  if($script:At58LiveBox.Mode -cne 'LIVE'){return}

  $liveArm.Enabled=$false

  $liveLabel.Text='실전 상태 확인 대기 / '+$script:At58LiveBox.State+' / '+$script:At58LiveBox.CommandError+[Environment]::NewLine+'아래 주문은 이전 조회 결과입니다. 최신 계좌 대조가 필요합니다.'

 }



 $logView=New-At58LogPanel $DataRoot;$layout.Controls.Add($logView.Panel,0,6)

 $foot=[Windows.Forms.Label]::new();$foot.Dock='Fill';$foot.Text='국내 당일 미체결 + 휴장 시 최근 영업일 잔량을 구분합니다. 해외·예약주문은 포함하지 않습니다.'+[Environment]::NewLine+'보유표 해외종목 단가는 해당 통화 기준 / 진단: '+$DataRoot;$layout.Controls.Add($foot,0,7)

 $script:At58Ui=@{PauseAfterLiveStop=$false;RequestedRunning=$false;Fault='';ExitReason='';HeartbeatNext=[datetime]::MinValue;Running=$false;Worker=$null;Handle=$null;Next=[datetime]::MinValue;Last=$null;Failed=$false;CredentialReady=([IO.File]::Exists((Join-Path $DataRoot 'credentials.dpapi')))}

 if($script:At58Ui.CredentialReady){$status.Text='AT 전용 인증정보 준비됨 · 직접 조회 시작을 누르세요.'}

 function Save-At58Runtime {

  if(!$managed){return}

  $u=$script:At58Ui;$box=$script:At58LiveBox;$box.UiUtc=[datetime]::UtcNow.ToString('o')

  $auto=Get-Variable -Name At58Auto -Scope Script -ValueOnly -ErrorAction SilentlyContinue
  try{Ops-WriteJson (Join-Path $ManagementRoot 'runtime.json') ([ordered]@{RunId=$RunId;Pid=$PID;Utc=[datetime]::UtcNow.ToString('o');DesiredRunning=$u.RequestedRunning;Running=$u.Running;Busy=($null -ne $u.Handle);Fault=$u.Fault;ExitReason=$u.ExitReason;ExecutionEnabled=($box.State -cin @('ARMED','STOPPING'));HostProtocol=$HostProtocol;LiveMode=$box.Mode;LiveState=$box.State;LiveCommandPending=($null -ne $box.Command);CommandError=[string]$box.CommandError;AutoStartCode=[string](Ops-Get $auto 'Code' '');AutoStartEnabled=[bool](Ops-Get $auto 'Enabled' $false);AutoStartAttempted=[bool](Ops-Get $auto 'Attempted' $false);AutoStartSuspended=[bool](Ops-Get $auto 'Suspended' $false)})}catch{}

 }

 function Reset-At58Worker {

  if('At58ReceiptFeed' -as [type]){[At58ReceiptFeed]::Stop($DataRoot)}

  if($script:At58Ui.Worker){$script:At58Ui.Worker.Dispose();$script:At58Ui.Worker=$null}

 }

 $import.Add_Click({

  try{

   $path=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'esbada\connection.dpapi'

   At58-ImportMtCredential $DataRoot $path;Reset-At58Worker;$script:At58Ui.CredentialReady=$true;Live-AutoLoad;$status.Text='메리츠 키를 AT 전용 저장소에 가져왔습니다. 직접 조회 시작을 누르세요.'

  }catch{$status.Text='저장된 키를 가져오지 못했습니다. 동일 Windows 계정인지 확인하거나 키 직접 입력을 사용하세요.'}

 })

 $manual.Add_Click({

  $d=[Windows.Forms.Form]::new();$d.Text='메리츠 연결 정보';$d.Size=[Drawing.Size]::new(520,230);$d.StartPosition='CenterParent';$d.Font=$font

  $l1=[Windows.Forms.Label]::new();$l1.Text='APP KEY';$l1.Location=[Drawing.Point]::new(15,22)

  $l2=[Windows.Forms.Label]::new();$l2.Text='APP SECRET';$l2.Location=[Drawing.Point]::new(15,70)

  $a=[Windows.Forms.TextBox]::new();$a.Location=[Drawing.Point]::new(125,20);$a.Width=355;$a.UseSystemPasswordChar=$true

  $b=[Windows.Forms.TextBox]::new();$b.Location=[Drawing.Point]::new(125,68);$b.Width=355;$b.UseSystemPasswordChar=$true

  $save=[Windows.Forms.Button]::new();$save.Text='암호화 저장';$save.Location=[Drawing.Point]::new(350,118);$save.Width=130;$save.DialogResult='OK';$d.AcceptButton=$save;$d.Controls.AddRange(@($l1,$l2,$a,$b,$save))

  try{if($d.ShowDialog($form) -eq 'OK'){At58-SaveCredential $DataRoot $a.Text $b.Text;Reset-At58Worker;$script:At58Ui.CredentialReady=$true;Live-AutoLoad;$status.Text='AT 인증정보 저장 완료 · 직접 조회 시작을 누르세요.'}}catch{$status.Text='키 저장 실패 · 입력 값과 Windows 사용자 저장소를 확인하세요.'}finally{$a.Clear();$b.Clear();$d.Dispose()}

 })

 $start.Add_Click({

  if(!$script:At58Ui.CredentialReady){$status.Text='먼저 기존 키 가져오기 또는 키 직접 입력을 완료하세요.';return}

  $script:At58Ui.RequestedRunning=$true;$script:At58Ui.Fault='';$script:At58Ui.Running=$true;$script:At58Ui.Next=[datetime]::MinValue;$start.Enabled=$false;$import.Enabled=$false;$manual.Enabled=$false;$status.Text='메리츠 직접 조회 시작 · 첫 결과 확인 중'

 })

 $stop.Add_Click({Live-AutoDisable;if($script:At58LiveBox.Mode -ceq 'LIVE'){$script:At58Ui.PauseAfterLiveStop=$true;At58X-Queue $script:At58LiveBox 'STOP';Live-RequestRead;$status.Text='신규 주문 중지 · AT 잔량취소 확인 후 일시정지';return};$null=At58A-Pause $DataRoot;if('At58ReceiptFeed' -as [type]){[At58ReceiptFeed]::Stop($DataRoot)};$script:At58Ui.RequestedRunning=$false;$script:At58Ui.Running=$false;Save-At58Runtime;$status.Text='일시정지 · 표시 값은 마지막 조회 결과입니다.';$start.Enabled=($null -eq $script:At58Ui.Handle);$import.Enabled=$start.Enabled;$manual.Enabled=$start.Enabled})

 $script:At58TrayClosePending=$false
 $trayMenu=[Windows.Forms.ContextMenuStrip]::new()
 $trayOpen=$trayMenu.Items.Add('아바타 열기')
 $trayExit=$trayMenu.Items.Add('아바타 종료')
 $tray=[Windows.Forms.NotifyIcon]::new();$tray.Icon=[Drawing.SystemIcons]::Application;$tray.Text='아바타 1.1.3';$tray.ContextMenuStrip=$trayMenu;$tray.Visible=$script:At58TrayEnabled
 function Tray-Restore {$script:At58TrayClosePending=$false;$form.RestoreFromTray()}
 function Tray-Minimize {
  if(!$script:At58TrayEnabled){return}
  $form.EnterTray()
  try{At58Window-SaveTray $DataRoot}catch{$tray.Text='아바타 · 트레이 시작 설정 저장 확인 필요'}
 }
 function Tray-SetMode([bool]$enabled){
  At58Window-SaveMode $DataRoot $enabled
  $script:At58TrayEnabled=$enabled;$tray.Visible=$enabled
  if(!$enabled){Tray-Restore}
 }
 $trayMode.Add_CheckedChanged({if($script:At58WindowChanging){return};try{Tray-SetMode ([bool]$trayMode.Checked)}catch{$script:At58WindowChanging=$true;$trayMode.Checked=$script:At58TrayEnabled;$script:At58WindowChanging=$false;[void][Windows.Forms.MessageBox]::Show('창 표시 설정을 저장하지 못했습니다. 기존 설정을 유지합니다.','아바타','OK','Warning')}})
 $trayOpen.Add_Click({Tray-Restore})
 $tray.Add_MouseDoubleClick({param($sender,$e) if($e.Button -eq [Windows.Forms.MouseButtons]::Left){Tray-Restore}})
 $trayExit.Add_Click({$script:At58TrayClosePending=$true;$form.Close()})
 $form.Add_Resize({if($script:At58TrayEnabled -and $form.WindowState -eq [Windows.Forms.FormWindowState]::Minimized){Tray-Minimize}})
 function Tray-Tick {
  $box=$script:At58LiveBox
  $state=if($box.State -ceq 'ARMED'){'실주문 승인 · 운용 중'}elseif($box.State -ceq 'REVIEW'){'주문 확인 필요'}elseif($box.State -ceq 'STOPPING'){'주문 정리 중'}else{'실주문 꺼짐'}
  $tray.Text='아바타 1.1.3 · '+$state
  if($script:At58TrayClosePending -and !$box.Busy -and !$box.Command -and $box.State -ceq 'DISARMED' -and (!$box.Last -or (!$box.Last.OpenOrders -and !$box.Last.UncertainOrders))){$form.Close()}
 }

 $timer=[Windows.Forms.Timer]::new();$timer.Interval=500

 $timer.Add_Tick({

  if($managed -and [datetime]::UtcNow -ge $script:At58Ui.HeartbeatNext){

   Update-Render; if($script:At58UpdateQueued -and ([datetime]::UtcNow-$script:At58UpdateQueuedAt).TotalSeconds -gt 600){$script:At58UpdateQueued=$false}; Save-At58Runtime;$script:At58Ui.HeartbeatNext=[datetime]::UtcNow.AddSeconds(5)

   $manager=Ops-ReadJson (Join-Path $ManagementRoot 'manager-status.json')

   $managerText='관리 기능 확인 중'

   if($manager){$managerText='관리: '+$manager.State+' / 텔레그램 '+$(if($manager.TelegramReady){'연결됨'}else{'미연결'})+' / 자동수정 '+$(if($manager.AutoRepair){'설정됨'}else{'꺼짐'});if(([datetime]::UtcNow-(Ops-Utc $manager.Utc)).TotalSeconds -gt 25){$managerText='관리 기능 기록이 멈췄습니다. 자동 복구 상태 확인 필요'}}

   $bundle=Ops-ReadJson (Join-Path $ManagementRoot 'bundle-status.json')

  if($bundle){

   $labels=@{LIVE_HOLD='주문 확인·종료까지 업데이트 보류';CURRENT='자동 업데이트 대기';SWITCHING='새 버전 전환';VERIFYING='새 버전 조회 검증';ROLLBACK_CHECK='이전 버전 복구 확인';UPDATE_WAITING='업데이트 대기';WAITING_FOR_QUERY='조회 재개 대기';DISABLED='자동 업데이트 중지';REJECTED='배포본 검증 실패';HOST_ERROR='업데이트 관리 오류';ROLLBACK_UNCONFIRMED='복구 후 확인 필요';STOPPED='종료됨'}

   $label=$labels[[string]$bundle.State];if(!$label){$label='상태 확인 필요'}

   if(([datetime]::UtcNow-(Ops-Utc $bundle.Utc)).TotalSeconds -gt 20){$label='업데이트 관리 기록 지연'}

   $managerText+=' / '+$label+' ('+$bundle.Version+')'

  }

  $foot.Text=$(if($script:At58LiveBox.Mode -ceq 'LIVE'){'실전 상태: '+$script:At58LiveBox.State+' / 주문·체결은 실전 제어 탭에서 확인'}else{'계좌 조회·모의 운용 / 실주문 꺼짐'})+[Environment]::NewLine+$managerText

   $control=Ops-ReadJson (Join-Path $ManagementRoot 'stop.request.json')

   if($control -and (Ops-Get $control 'RunId') -ceq $RunId -and (Ops-Get $control 'Action') -ceq 'RESTART'){$script:At58Ui.ExitReason='MANAGED_RESTART';$form.Close();return}

  }

  # Log display failures must never interrupt the asynchronous account reader.

  if([datetime]::UtcNow -ge $logView.Next){

   if(!$logView.Paused){try{Update-At58LogPanel $logView}catch{$logView.Headline.Text='로그 읽기 대기 · 다음 확인 때 다시 읽습니다.'}}

   $logView.Next=[datetime]::UtcNow.AddSeconds(1)

  }

  try{

   $u=$script:At58Ui

   if($u.Handle -and $u.Handle.IsCompleted){

    try{$results=@($u.Worker.EndInvoke($u.Handle));$r=$results[-1];if(!$r -or !$r.PSObject.Properties['Ok']){throw 'worker'}}catch{$script:At58Ui.Fault='WORKER_FAILED';$r=[pscustomobject]@{Ok=$false;Status=[pscustomobject]@{Code='WORKER_FAILED';State='STOPPED';Failures=0;At='';LastSuccessUtc=''};Snapshot=$null;RetrySeconds=60}}

    $u.Handle=$null;$u.Worker.Commands.Clear();$u.Next=[datetime]::UtcNow.AddSeconds($r.RetrySeconds)

    if($r.Ok){

     $u.Last=$r.Snapshot;$u.Failed=$false;$s=$r.Snapshot;$holdGrid.Rows.Clear();$orderGrid.Rows.Clear()

     foreach($h in $s.Holdings){[void]$holdGrid.Rows.Add(($h.Symbol+' '+$h.Name),$h.Class,$h.Qty,$h.Average,$h.Price,$h.ValueKRW,$h.ProfitKRW)}

     foreach($o in $s.OpenOrdersToday){[void]$orderGrid.Rows.Add($o.Day,'당일',$o.Symbol,$o.Id,$(if($o.Side -eq '2'){'매수'}else{'매도'}),$o.Qty,$o.Filled,$o.Remaining,$o.Price)}

     foreach($o in $s.PriorUnresolved){[void]$orderGrid.Rows.Add($o.Day,'과거 잔량 확인',$o.Symbol,$o.Id,$(if($o.Side -eq '2'){'매수'}else{'매도'}),$o.Qty,$o.Filled,$o.Remaining,$o.Price)}

     $caption=if($s.Quote.Mode -eq 'CLOSED_DAILY'){'장외 확정 종가 / 기준일 '+$s.Quote.BasisDay}else{'장중 REST 조회가'}

     $summary.Text=$Symbol+' '+$s.Quote.Name+' / '+$caption+' / '+$s.Quote.Price+'원 / 보유 '+$s.TargetQty+'주'+[Environment]::NewLine+'예수금 '+$s.Cash.Deposit+'원 / D+2 '+$s.Cash.D2+'원 / 주문가능현금 '+$s.Cash.Orderable+'원 / 총자산 '+$s.Valuation.Total+'원'+[Environment]::NewLine+'당일 미체결 '+@($s.OpenOrdersToday).Count+'건 / 최근 영업일 잔량 '+@($s.PriorUnresolved).Count+'건 / 조회 완료 '+(At58-Kst ([datetimeoffset]::Parse($s.CompletedUtc).UtcDateTime)).ToString('yyyy-MM-dd HH:mm:ss')

     $status.Text='직접 조회 완료 · '+$r.Status.At;$status.BackColor=[Drawing.Color]::Honeydew

     if($s.PSObject.Properties['Execution']){

      $x=$s.Execution;$receiptLabel.Text=$x.Text+' / 오늘 접수 '+$x.Receipts+' · 체결 통보 '+$x.Fills+' / 확인 필요 '+($x.Pending+$x.Gaps)+[Environment]::NewLine+'계좌 통보 관찰 · 수수료/세금 미확정 · 실주문 차단';$receiptGrid.Rows.Clear()

      foreach($e in $x.Events){[void]$receiptGrid.Rows.Add($e.Day,($e.Time.Substring(0,2)+':'+$e.Time.Substring(2,2)+':'+$e.Time.Substring(4,2)+'.'+$e.Time.Substring(6)),$e.Id,$(if($e.Kind -ceq 'FILL'){'체결'}else{'접수'}),$(if($e.Side -ceq '2'){'매수'}else{'매도'}),$e.Symbol,$e.Qty,$e.Price,(At58E-StateLabel $e.State),'계좌 통보')}

     }

     if($s.PSObject.Properties['Trading']){

      $t=$s.Trading;$tradeLabel.Text=$t.Text+[Environment]::NewLine+'신규·정정·취소 이력 / 실제 체결 '+$t.FillCount+'건 · 수수료 미확정';$tradeGrid.Rows.Clear()

      foreach($o in $t.Orders){[void]$tradeGrid.Rows.Add($o.Day,$o.Action,$o.BrokerId,$o.ParentId,$o.Intent.Side,$o.Intent.Qty,$o.Filled,$o.Remaining,(At58T-Label $o.State))}

      if($t.Candidate){$tradeLabel.Text+='/ 후보: '+$t.Candidate.Side+' '+$t.Candidate.Qty+'주 / '+$t.Candidate.Price+'원'}

     }

           if($s.PSObject.Properties['Readiness']){

       $ready=$s.Readiness;$readinessLabel.Text=$ready.Text+[Environment]::NewLine+'미완료·대기 '+$ready.Blockers+'항목 / 설정을 허용으로 바꾸어도 실주문이 실행되지 않습니다.';$readinessGrid.Rows.Clear()

       foreach($item in $ready.Rows){[void]$readinessGrid.Rows.Add($item.Label,$(if($item.State -ceq 'PASS'){'확인'}else{'미완료·대기'}),$item.Detail)}

      }

if($s.PSObject.Properties['Strategy']){

      $t=$(if($s.PSObject.Properties['Simulation']){$s.Simulation}else{$s.Strategy});$status.Text+=[Environment]::NewLine+$t.Text+' / 시장 '+$t.Market+' / 실주문 꺼짐';if($s.PSObject.Properties['Simulation'] -and $t.Cycle){$status.Text+=' / 모의 '+$t.Cycle.Id+'사이클 '+$t.Cycle.Phase};$paperGrid.Rows.Clear();$planGrid.Rows.Clear()

      foreach($o in $t.Orders){[void]$paperGrid.Rows.Add($o.Day,$o.Stage,$o.Side,$o.Price,$o.Qty,$o.Filled,($o.Qty-$o.Filled),$(if($o.State -ceq 'CANCEL_PENDING'){'부분 체결 · 잔량 대기'}else{At58T-Label $o.State}))}

      foreach($p in $t.Plan){[void]$planGrid.Rows.Add($p.Stage,$p.BuyPrice,$p.BuyQty,$p.SellPrice,$p.SellQty,$(if($p.Held){'보유'}else{'미보유'}))}

     }

     Live-Render $s $r

    }else{

     Live-RenderUnavailable

     $u.Failed=$true
     if($r.Status.Code -ceq 'LIVE_ROLLOVER_WAIT'){$status.Text='날짜 전환 중 · 오늘 입력 갱신 대기 / 주문 보류';$status.BackColor=[Drawing.Color]::LightGoldenrodYellow}
     else{$status.Text='갱신 실패 ['+$r.Status.Code+'] · '+$r.RetrySeconds+'초 후 재조회 / 표시 값은 이전 조회 결과';$status.BackColor=[Drawing.Color]::MistyRose}

     if($r.Status.State -eq 'STOPPED'){$u.Running=$false}

    }

    if(!$u.Running){if('At58ReceiptFeed' -as [type]){[At58ReceiptFeed]::Stop($DataRoot)};$status.Text='일시정지 · '+$status.Text;$start.Enabled=$true;$import.Enabled=$true;$manual.Enabled=$true}

   }

   if($u.Last -and !$u.Failed -and ([datetime]::UtcNow-[datetimeoffset]::Parse($u.Last.CompletedUtc).UtcDateTime).TotalSeconds -gt 60){$status.Text='마지막 조회 후 60초 경과 · 이전 값 표시 중';$status.BackColor=[Drawing.Color]::LightGoldenrodYellow}

   Live-AutoTick;Tray-Tick;try{Live-TelegramTick}catch{$liveLabel.Text="텔레그램 시작 확인 대기 · 계좌 조회는 계속됩니다."}

   if($u.Running -and !$u.Handle -and [datetime]::UtcNow -ge $u.Next){

    if(!$u.Worker){

     $u.Worker=[PowerShell]::Create()

     [void]$u.Worker.AddScript('param($core,$root,$symbol,$runId,$management,$hostProtocol,$box); . $core; $script:directContext=At58-Context $root $symbol; $script:directContext.RunId=$runId; $script:directContext.EnableStrategy=$true; $script:directContext.EnableExecutionFeed=$true; $script:directContext.ManagementRoot=$management; $script:directContext.LiveHostProtocol=$hostProtocol; $script:directContext.Version="58.17.9"; $script:liveBox=$box; At58X-ManagedCycle $script:directContext $script:liveBox').AddArgument((Join-Path $PSScriptRoot 'At58.Core.ps1')).AddArgument($DataRoot).AddArgument($Symbol).AddArgument($RunId).AddArgument($ManagementRoot).AddArgument($HostProtocol).AddArgument($script:At58LiveBox)

    }else{[void]$u.Worker.AddScript('At58X-ManagedCycle $script:directContext $script:liveBox')}

    $u.Handle=$u.Worker.BeginInvoke()

   }

  }catch{$script:At58Ui.Fault='UI_ERROR';Save-At58Runtime;$status.Text='화면 처리 오류 · 조회 일시정지';$script:At58Ui.Running=$false;$start.Enabled=$false}

 })

 # Startup runs before the message loop; a hidden tray form need not raise Shown.
 # Account reads are independent of control visibility; PerformClick cannot start a hidden form.
 function Start-At58Ui {Live-AutoLoad;if($AutoStart -and $script:At58Ui.CredentialReady){Live-RequestRead};Save-At58Runtime}

 # Hidden host consoles can apply SW_HIDE to the first native show. An explicit
 # visible-start preference gets its normal window after the message loop starts.
 # Tray startup never takes this path and remains hidden without activation.
 $form.Add_Shown({if(!$form.TrayHidden){[void]$form.BeginInvoke([Action]{if(!$form.IsDisposed -and !$form.TrayHidden){$form.RestoreFromTray()}})}})

 $form.Add_FormClosing({param($sender,$e)
  Live-AutoSuspend 'STOPPED'

  $box=$script:At58LiveBox

  if($box.Mode -ceq 'LIVE' -and ($box.Command -or $box.Busy -or $box.State -cin @('ARMED','STOPPING') -or ($box.Last -and $box.Last.OpenOrders -gt 0))){$e.Cancel=$true;if($script:At58Ui.ExitReason -ceq 'MANAGED_RESTART'){$script:At58Ui.ExitReason='';$status.Text='주문 처리 중 · 자동 업데이트 보류';return};At58X-Queue $box 'STOP';Live-RequestRead;$status.Text='정지·AT 잔량취소 확인 후 닫아주세요.';return}

  if($box.Mode -ceq 'LIVE' -and ($box.State -ceq 'REVIEW' -or ($box.Last -and $box.Last.UncertainOrders -gt 0))){if($script:At58Ui.ExitReason -ceq 'MANAGED_RESTART'){$e.Cancel=$true;$script:At58Ui.ExitReason='';return};if($form.TrayHidden){$e.Cancel=$true;$script:At58TrayClosePending=$false;$tray.Text='아바타 · 주문 확인 필요: 창을 열어 확인하세요';return};if([Windows.Forms.MessageBox]::Show('확인되지 않은 주문이 있습니다. 종료해도 증권사 주문은 남을 수 있습니다. 증권사 앱에서 확인해야 합니다. 종료할까요?','주문 확인 필요','YesNo','Warning') -ne 'Yes'){$e.Cancel=$true;return}}

  if(!$script:At58Ui.ExitReason){$script:At58Ui.ExitReason='USER_CLOSE'};Save-At58Runtime;$script:At58Ui.Running=$false;$timer.Stop();if($script:At58Ui.Worker -and $script:At58Ui.Handle){try{$null=$script:At58Ui.Worker.BeginStop($null,$null)}catch{}}})

 try{Start-At58Ui;$timer.Start();[Windows.Forms.Application]::Run($form)}finally{Live-TelegramClose;$timer.Stop();$timer.Dispose();$tray.Visible=$false;$tray.Dispose();$trayMenu.Dispose();Reset-At58Worker;$form.Dispose();$font.Dispose()}

}finally{$mutex.ReleaseMutex();$mutex.Dispose()}

