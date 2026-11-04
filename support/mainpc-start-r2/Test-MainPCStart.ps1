#requires -Version 5.1
param([string]$Root=$PSScriptRoot)
$ErrorActionPreference='Stop'
. (Join-Path $Root 'MainPC-Start.ps1')
$original=Join-Path (Split-Path $Root -Parent) 'repair_111_20261104/tests/original'
. (Join-Path $original 'At58.Ops.ps1')
$script:checks=0;$script:launches=0
function Check($ok,[string]$name){if(!$ok){throw ('FAILED: '+$name)};$script:checks++;Write-Output ('PASS '+$name)}
function Reject($body,[string]$expected,[string]$name){$code='';try{& $body|Out-Null}catch{$code=$_.Exception.Message};Check ($code -ceq $expected) $name}
$work=Join-Path ([IO.Path]::GetTempPath()) ('Avata Main Start '+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
function Fixture([string]$name,[bool]$redirected=$false){
 $profile=Join-Path $work $name;$local=Join-Path $profile $(if($redirected){'redirected-local'}else{'AppData/Local'})
 $hostRoot=Join-Path $local 'esbada_AT_host';$data=Join-Path $local 'esbada_AT_direct';$manage=Join-Path $local 'esbada_AT_manage'
 foreach($p in @($hostRoot,$data,$manage)){[void][IO.Directory]::CreateDirectory($p)}
 foreach($n in @('At58.Host.ps1','At58.Ops.ps1','At58.Update.ps1')){Copy-Item -LiteralPath (Join-Path $original $n) -Destination (Join-Path $hostRoot $n)}
 $offer=Ops-ReadJson (Join-Path $original 'channel/ready.json');$bundles=Join-Path $hostRoot 'bundles';[void][IO.Directory]::CreateDirectory($bundles)
 Copy-Item -LiteralPath (Join-Path $original ('channel/releases/'+$offer.Id)) -Destination (Join-Path $bundles $offer.Id) -Recurse
 Ops-WriteJson (Join-Path $hostRoot 'active.json') $offer
 Ops-WriteJson (Join-Path $hostRoot 'settings.json') @{Schema='AT58-HOST-1';HostProtocol=2;Enabled=$true;DataRoot=$data;ManagementRoot=$manage;ChannelRoot=(Join-Path $hostRoot 'remote-channel');FeedUrl='https://github.com/crosnuu12/Avata-kor-releases/releases/latest/download/avata-update.json';ResumeOnce=$false}
 return [pscustomobject]@{ProfileRoot=$profile;LocalRoot=$local;HostRoot=$hostRoot;DataRoot=$data;ManagementRoot=$manage}
}
$f=Fixture 'normal';$resolved=MP-Resolve $f.ProfileRoot $f.LocalRoot
Check ($resolved.Code -ceq 'OK' -and !$resolved.Candidates[0].LauncherExists) 'complete existing host resolves without Avata_kor.exe'
$before=Get-FileHash -LiteralPath (Join-Path $f.HostRoot 'settings.json')
$r=MP-Start $resolved.Installation $true
Check ($r.Code -ceq 'INSPECTED' -and $r.InstalledVersion -ceq '58.17.0') 'original bootstrap verifies actual bundle in a path containing spaces'
Check ($before.Hash -ceq (Get-FileHash -LiteralPath (Join-Path $f.HostRoot 'settings.json')).Hash -and ![IO.File]::Exists((Join-Path $f.DataRoot 'window-preferences.json'))) 'inspection changes no installed settings or window preferences'
$f2=Fixture 'redirected' $true;$r=MP-Resolve $f2.ProfileRoot $f2.LocalRoot
Check ($r.Code -ceq 'OK' -and $r.Installation.LocalRoot -ceq $f2.LocalRoot) 'current-user redirected local data is discovered'
$r=MP-Resolve $f.ProfileRoot (Join-Path $f.ProfileRoot 'empty-redirect')
Check ($r.Code -ceq 'OK' -and $r.Installation.LocalRoot -ceq $f.LocalRoot) 'empty redirected folder falls back to the same user profile'
$r=MP-Resolve $f.ProfileRoot $f.LocalRoot.ToUpperInvariant()
Check ($r.Code -ceq 'OK') 'case variants of one installation are deduplicated'
$r=MP-Resolve $f.ProfileRoot $f2.LocalRoot
Check ($r.Code -ceq 'AVATA_MULTIPLE_INSTALLATIONS') 'two complete installations require explicit resolution'
$r=MP-Resolve (Join-Path $work 'uninstalled') (Join-Path $work 'uninstalled/local')
Check ($r.Code -ceq 'AVATA_HOST_INSTALLATION_MISSING' -and $r.Candidates.Count -eq 2 -and $r.Candidates[0].Missing.Count -eq 5) 'missing installation reports checked roots and missing components'
$cross=[pscustomobject]@{ProfileRoot=(Join-Path $work 'different-user');LocalRoot=$f.LocalRoot;HostRoot=$f.HostRoot}
Reject {MP-Validate $cross} 'AVATA_INSTALLATION_PATH' 'another user profile is not adopted'
$cfg=Ops-ReadJson (Join-Path $f.HostRoot 'settings.json');$cfg.Enabled=$false;Ops-WriteJson (Join-Path $f.HostRoot 'settings.json') $cfg
Reject {MP-Validate $resolved.Installation} 'AVATA_UPDATE_SETTINGS_CHECK' 'disabled signed updates are not silently enabled'
$cfg.Enabled=$true;Ops-WriteJson (Join-Path $f.HostRoot 'settings.json') $cfg
$active=Ops-ReadJson (Join-Path $f.HostRoot 'active.json');$hash=$active.ManifestHash;$active.ManifestHash=('0'*64);Ops-WriteJson (Join-Path $f.HostRoot 'active.json') $active
$failed=$false;try{MP-Start $resolved.Installation $true|Out-Null}catch{$failed=$true}
Check ($failed -and ![IO.File]::Exists((Join-Path $f.DataRoot 'window-preferences.json'))) 'tampered installed bundle is rejected before preferences or launch'
$active.ManifestHash=$hash;Ops-WriteJson (Join-Path $f.HostRoot 'active.json') $active
# All launch-path checks below replace the process starter with a local mock.
function MP-Bootstrap([string]$hostRoot,[bool]$inspectOnly){if($inspectOnly){return [pscustomobject]@{Code='INSPECTED'}};$script:launches++;if($script:failStart){throw 'SYNTHETIC_START_FAILED'};return [pscustomobject]@{Code='STARTED';InstalledVersion='58.17.0'}}
$script:failStart=$false
$m=[Threading.Mutex]::new($true,('Local\esbada-AT-host-'+(MP-Hash $f.HostRoot.ToLowerInvariant()).Substring(0,24)))
try{Reject {MP-Start $resolved.Installation $false} 'AVATA_CLOSE_FIRST' 'running installation is not replaced or duplicated'}finally{$m.ReleaseMutex();$m.Dispose()}
Check ($script:launches -eq 0) 'running guard submits no start request'
$consent=Join-Path $f.DataRoot 'auto-start.dpapi';[IO.File]::WriteAllText($consent,'synthetic-consent-marker')
$ledger=Join-Path $f.DataRoot 'ledger.dpapi';[IO.File]::WriteAllText($ledger,'synthetic-ledger-marker')
$r=MP-Start $resolved.Installation $false
$pref=Join-Path $f.DataRoot 'window-preferences.json';$w=Ops-ReadJson $pref
Check ($r.Code -ceq 'STARTED' -and $script:launches -eq 1 -and !$w.UseTray -and !$w.StartInTray) 'requested main-PC start sets visible desktop mode and invokes bootstrap once'
Check ([IO.File]::ReadAllText($consent) -ceq 'synthetic-consent-marker' -and [IO.File]::ReadAllText($ledger) -ceq 'synthetic-ledger-marker') 'window setup leaves consent and ledger files unchanged'
[IO.File]::WriteAllText($pref,'{"Schema":"AT-WINDOW-2","UseTray":true,"StartInTray":true}')
$prefBefore=[IO.File]::ReadAllText($pref);$script:failStart=$true
Reject {MP-Start $resolved.Installation $false} 'SYNTHETIC_START_FAILED' 'bootstrap failure is surfaced'
Check ([IO.File]::ReadAllText($pref) -ceq $prefBefore) 'failed startup restores existing window preference bytes'
[IO.File]::Delete($pref)
Reject {MP-Start $resolved.Installation $false} 'SYNTHETIC_START_FAILED' 'failure is surfaced when no original preference exists'
Check (![IO.File]::Exists($pref)) 'failed startup removes only its newly created preference'
Write-Output ('MAIN PC START TESTS COMPLETE: '+$script:checks+' passed; isolated fixtures; no real app start, broker calls or orders.')
