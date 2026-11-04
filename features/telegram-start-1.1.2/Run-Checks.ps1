#requires -Version 5.1
param([string]$Root=$PSScriptRoot)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){throw 'WINDOWS_POWERSHELL_51_REQUIRED'}
$before=@(Get-ChildItem -LiteralPath (Join-Path $Root 'bundle') -Filter '*.ps1' -Recurse | Sort-Object FullName | ForEach-Object { [pscustomobject]@{Name=$_.FullName.Substring((Join-Path $Root 'bundle').Length+1).Replace('\','/');Hash=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant();Size=$_.Length} })
foreach($file in Get-ChildItem -LiteralPath (Join-Path $Root 'bundle') -Filter '*.ps1' -Recurse){$tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors);if($errors.Count){throw ('SYNTAX: '+$file.Name)}}
foreach($path in @('bundle/payload/Test-AT58.ps1','bundle/payload/Test-AT58LogViewer.ps1','Test-Rollover.ps1','Test-CashInterest.ps1','Test-AutoStartTray.ps1','Test-HiddenStartup.ps1','Test-HiddenAutoRead.ps1','Test-Alerts.ps1','Test-WindowPreferences.ps1','Test-DayTransition.ps1','Test-HostRepair.ps1','Test-ApiDiagnostics.ps1','Test-TelegramStart.ps1','Test-TelegramWorker.ps1','Test-InputDiagnostics.ps1','Test-JournalGrouping.ps1')){
 Write-Output ('RUN '+$path)
 & (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -NoProfile -NonInteractive -STA -ExecutionPolicy RemoteSigned -File (Join-Path $Root $path)
 if($LASTEXITCODE -ne 0){throw ('TEST_FAILED: '+$path)}
}
Write-Output 'ALL CHECKS PASSED on Windows PowerShell 5.1'
$after=@(Get-ChildItem -LiteralPath (Join-Path $Root 'bundle') -Filter '*.ps1' -Recurse | Sort-Object FullName | ForEach-Object { [pscustomobject]@{Name=$_.FullName.Substring((Join-Path $Root 'bundle').Length+1).Replace('\','/');Hash=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant();Size=$_.Length} })
if(($before|ConvertTo-Json -Compress) -cne ($after|ConvertTo-Json -Compress)){throw 'SOURCE_CHANGED_DURING_CHECK'}
$receipt=@{Schema='AVATA-VALIDATION-1';Version='58.17.8';Result='PASSED';Engine='WindowsPowerShell-5.1';Checks=510;Utc=[datetime]::UtcNow.ToString('o');Files=$before}
[IO.File]::WriteAllText((Join-Path $Root 'validation.json'),($receipt|ConvertTo-Json -Depth 5 -Compress),[Text.UTF8Encoding]::new($false))
