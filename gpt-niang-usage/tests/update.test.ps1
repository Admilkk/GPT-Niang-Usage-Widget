$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
# Dot source into this test scope; no task/shortcut/CLI installation is performed.
. (Join-Path $source 'runtime\update-helper.ps1') -FunctionsOnly
. ([ScriptBlock]::Create([IO.File]::ReadAllText((Join-Path $source 'runtime\update-ui.ps1'),[Text.Encoding]::UTF8)))
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('gpt-niang-updater-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot
$script:agent=Join-Path $testRoot 'agent'
function Get-WidgetUpdateAgentDir {return $script:agent}
function Get-FileHash {throw 'Get-FileHash module is unavailable in this fixture.'}
$script:jsonWriter=(Get-Command Write-WidgetSupervisorJson).ScriptBlock
function Write-WidgetSupervisorJson([string]$File,$Value) {
  if($script:failureMode-eq 'status' -and $Value.phase-eq 'updated'){throw 'Simulated committed status write failure.'}
  & $script:jsonWriter $File $Value
}
function Get-ScheduledTask {return @()}
$startup=Join-Path ([Environment]::GetFolderPath('Startup')) 'GPT Niang Usage.lnk'
function Test-Path {
  [CmdletBinding(DefaultParameterSetName='Path')]
  param([Parameter(Position=0,ParameterSetName='Path')][string[]]$Path,[Parameter(ParameterSetName='LiteralPath')][string[]]$LiteralPath,[Microsoft.PowerShell.Commands.TestPathType]$PathType)
  if($LiteralPath.Count-eq 1 -and $LiteralPath[0]-eq $script:startup){return $false}
  Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
}
function Stop-WidgetSupervisorTask {$script:stops++}
function Stop-WidgetGui {$script:stops++}
function Wait-WidgetUpdateIdle {}
function Assert-WidgetCandidatePackage {}
function Assert-WidgetPluginRegistration([string]$Codex,[string]$Version){
  $catalog=Read-WidgetUpdateJson (Join-Path $testRoot 'catalog.json')
  if($catalog.version-ne $Version -or !$catalog.installed -or !$catalog.enabled){throw 'Isolated plugin registration mismatch.'}
}
function Get-CimInstance {
  return [pscustomobject]@{Name='powershell.exe';CommandLine=('powershell.exe -File "'+(Join-Path $script:agent 'update-agent.ps1')+'"')}
}
function Invoke-WidgetUpdateInstaller($Journal,[string]$Token) {
  $script:installerCalls++
  $manifest=Read-WidgetUpdateJson (Join-Path $Journal.appDir '.codex-plugin\plugin.json')
  if($script:failureMode-eq 'install' -and $manifest.version-eq '1.3.3'){throw 'Simulated plugin registration failure.'}
  $config=Read-WidgetUpdateJson (Join-Path $Journal.appDir 'installation.json');$config.version=$manifest.version
  Write-WidgetSupervisorJson (Join-Path $Journal.appDir 'installation.json') $config
  Write-WidgetSupervisorJson (Join-Path $testRoot 'catalog.json') @{version=$manifest.version;installed=$true;enabled=$true}
  Write-WidgetSupervisorJson (Join-Path $Journal.dataDir 'supervisor-status.json') @{pid=$PID;at=[DateTime]::UtcNow.ToString('o')}
}
$checks=0
function Assert($Condition,[string]$Label){if(!$Condition){throw ('Assertion failed: '+$Label)};$script:checks++;Write-Output ('PASS '+$Label)}
function Assert-Throws([scriptblock]$Action,[string]$Label){try{& $Action|Out-Null}catch{$script:checks++;Write-Output ('PASS '+$Label);return};throw ('Expected failure: '+$Label)}
function New-Fixture([string]$Name,[switch]$Embedded) {
  $case=Join-Path $testRoot $Name;$root=Join-Path $case 'install';$app=Join-Path $root 'gpt-niang-usage'
  $null=New-Item -ItemType Directory -Path $root -Force
  Copy-Item -LiteralPath $source -Destination $app -Recurse
  $metadata=Join-Path $root '.agents\plugins';$null=New-Item -ItemType Directory -Path $metadata -Force
  Copy-Item -LiteralPath (Join-Path (Split-Path $source -Parent) '.agents\plugins\marketplace.json') -Destination $metadata
  $data=if($Embedded){Join-Path $root 'state'}else{Join-Path $case 'state'}
  $null=New-Item -ItemType Directory -Path $data -Force
  Write-WidgetSupervisorJson (Join-Path $app 'installation.json') @{appDir=$app;dataDir=$data;version='1.3.2';codexPath='isolated-codex';updateAgent=$script:agent}
  Write-WidgetSupervisorJson (Join-Path $data 'settings.json') @{scale=1.4;soundOn=$false;desktopLeft=123;desktopTop=456}
  Write-WidgetSupervisorJson (Join-Path $data 'update-preferences.json') @{automatic=$false}
  [IO.File]::WriteAllText((Join-Path $data 'quotes.txt'),'custom quote')
  $token=[Guid]::NewGuid().ToString('D');$job=Join-Path $data ('updates\'+$token)
  $candidate=Join-Path $job 'package\bundle';$null=New-Item -ItemType Directory -Path $candidate -Force
  Copy-Item -LiteralPath $source -Destination (Join-Path $candidate 'gpt-niang-usage') -Recurse
  $candidateMetadata=Join-Path $candidate '.agents\plugins';$null=New-Item -ItemType Directory -Path $candidateMetadata -Force
  Copy-Item -LiteralPath (Join-Path (Split-Path $source -Parent) '.agents\plugins\marketplace.json') -Destination $candidateMetadata
  foreach($name in @('package.json','.codex-plugin\plugin.json')){
    $file=Join-Path $candidate ('gpt-niang-usage\'+$name);$value=Read-WidgetUpdateJson $file;$value.version='1.3.3';Write-WidgetSupervisorJson $file $value
  }
  $archive=Join-Path $job 'release.zip';[IO.File]::WriteAllText($archive,'already validated ZIP fixture')
  Write-WidgetSupervisorJson (Join-Path $script:agent 'binding.json') @{sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;appDir=$app;dataDir=$data}
  $script:stops=0;$script:installerCalls=0;$script:failureMode=''
  return [pscustomobject]@{schema=1;token=$token;phase='prepared';root=$root;appDir=$app;dataDir=$data;candidate=$candidate;archive=$archive;hash=(Get-WidgetFileHash $archive);version='1.3.3';oldVersion='1.3.2';mode='manual'}
}
try {
  $hashFile=Join-Path $testRoot 'sha-test.txt';[IO.File]::WriteAllText($hashFile,'abc')
  Assert ((Get-WidgetFileHash $hashFile)-eq 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD') 'SHA256 works without Get-FileHash module autoload'
  $journal=New-Fixture 'upgrade'
  Invoke-WidgetUpdateTransaction $journal $script:agent $journal.token
  Assert ($journal.phase-eq 'committed') 'upgrade commits after registration and real heartbeat validation'
  Assert ((Read-WidgetUpdateJson (Join-Path $journal.appDir 'installation.json')).version-eq '1.3.3') 'new plugin version registered'
  Assert (Test-Path -LiteralPath $journal.backup) 'complete previous program remains available'
  Assert ((Read-WidgetUpdateJson (Join-Path $journal.dataDir 'settings.json')).scale-eq 1.4) 'position and appearance preferences preserved'
  Assert (!(Read-WidgetUpdateJson (Join-Path $journal.dataDir 'update-preferences.json')).automatic) 'disabled automatic-update preference preserved'

  $journal=New-Fixture 'committed-status';$script:failureMode='status'
  Invoke-WidgetUpdateTransaction $journal $script:agent $journal.token
  Assert ($journal.phase-eq 'committed' -and $script:installerCalls-eq 1) 'status write failure after commit does not roll back a healthy upgrade'

  $journal=New-Fixture 'embedded-data' -Embedded
  Invoke-WidgetUpdateTransaction $journal $script:agent $journal.token
  Assert ($journal.phase-eq 'committed' -and [IO.File]::ReadAllText((Join-Path $journal.dataDir 'quotes.txt'))-eq 'custom quote') 'embedded data copied and verified before replacement'

  $journal=New-Fixture 'data-collision' -Embedded
  $null=New-Item -ItemType Directory -Path (Join-Path $journal.candidate 'state')
  Assert-Throws {Invoke-WidgetUpdateTransaction $journal $script:agent $journal.token} 'candidate cannot overwrite an embedded data directory'
  Assert ($script:stops-eq 0 -and $script:installerCalls-eq 0) 'data path collision is rejected before stopping the program'

  $journal=New-Fixture 'bad-hash';$journal.hash='0'*64
  Assert-Throws {Invoke-WidgetUpdateTransaction $journal $script:agent $journal.token} 'changed archive rejected'
  Assert ($script:stops-eq 0 -and $script:installerCalls-eq 0) 'failed validation never stops or runs installer'

  $journal=New-Fixture 'failed-install';$script:failureMode='install'
  Assert-Throws {Invoke-WidgetUpdateTransaction $journal $script:agent $journal.token} 'installation failure triggers rollback'
  Assert ($journal.phase-eq 'rolled-back' -and (Read-WidgetUpdateJson (Join-Path $journal.appDir 'installation.json')).version-eq '1.3.2') 'failed new registration restores and registers old plugin'
  Assert (Test-Path -LiteralPath $journal.failedRoot) 'failed replacement is retained for diagnosis'

  $journal=New-Fixture 'interrupted-rename'
  Assert-WidgetUpdateTransaction $journal $script:agent
  Set-WidgetUpdatePhase $journal 'moving-new' $script:agent
  [IO.Directory]::Move($journal.root,$journal.backup)
  Invoke-WidgetUpdateTransaction $journal $script:agent $journal.token -Recover
  Assert ($journal.phase-eq 'rolled-back' -and (Test-Path -LiteralPath $journal.appDir)) 'restart recovery restores missing program directory'

  $journal=New-Fixture 'interrupted-registration'
  Assert-WidgetUpdateTransaction $journal $script:agent
  Copy-WidgetVerifiedTree $journal.candidate $journal.nextRoot
  Copy-Item -LiteralPath (Join-Path $journal.appDir 'installation.json') -Destination (Join-Path $journal.nextRoot 'gpt-niang-usage\installation.json')
  [IO.Directory]::Move($journal.root,$journal.backup);[IO.Directory]::Move($journal.nextRoot,$journal.root)
  Set-WidgetUpdatePhase $journal 'registering' $script:agent
  Invoke-WidgetUpdateTransaction $journal $script:agent $journal.token -Recover
  Assert ((Read-WidgetUpdateJson (Join-Path $journal.appDir '.codex-plugin\plugin.json')).version-eq '1.3.2') 'restart before commit restores original files'

  $journal=New-Fixture 'locked-files'
  $locked=Join-Path $journal.root 'locked.txt';[IO.File]::WriteAllText($locked,'locked')
  $stream=[IO.File]::Open($locked,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
  try{Assert-Throws {Invoke-WidgetUpdateTransaction $journal $script:agent $journal.token} 'occupied Windows files reject replacement'}finally{$stream.Dispose()}
  Assert ($journal.phase-eq 'rolled-back' -and (Test-Path -LiteralPath $journal.appDir)) 'occupied old program is retained and restarted'

  $journal=New-Fixture 'broken-recovery';$journal.phase='moving-new'
  Remove-Item -LiteralPath (Join-Path $journal.appDir 'installation.json')
  Assert-Throws {Invoke-WidgetUpdateTransaction $journal $script:agent $journal.token -Recover} 'missing old configuration stops recovery'
  Assert ($journal.phase-eq 'recovery-failed' -and (Test-Path -LiteralPath (Join-Path $script:agent 'update-diagnostic.txt'))) 'failed recovery keeps diagnosis and blocks automatic retry'
  Assert-Throws {Restore-WidgetUpdate $journal $script:agent $journal.token} 'failed recovery cannot be automatically repeated'

  $lock=Enter-WidgetUpdateLock -AgentDir $script:agent
  try{Assert-Throws {Enter-WidgetUpdateLock -AgentDir $script:agent} 'installer/update/uninstall lock is exclusive'}finally{Exit-WidgetUpdateLock $lock}
  $script:dataDir=Join-Path $testRoot 'ui-preferences';$null=New-Item -ItemType Directory -Path $script:dataDir
  $script:settingsMenuUi=@{}
  Initialize-WidgetUpdater;Assert $script:autoUpdate 'WPF automatic-update default is on'
  Set-WidgetAutomaticUpdate $false;Initialize-WidgetUpdater;Assert (!$script:autoUpdate) 'WPF toggle survives initialization'
  $script:context=[pscustomobject]@{IsOpen=$false};$script:disposedUpdater=$false
  $script:updateProcess=[pscustomobject]@{HasExited=$true;ExitCode=12}
  $script:updateProcess|Add-Member ScriptMethod Dispose {$script:disposedUpdater=$true}
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Tick-WidgetUpdater $now
  $failed=Read-WidgetUpdateJson (Join-Path $script:dataDir 'update-status.json')
  Assert ($failed.phase-eq 'failed' -and $failed.nextCheckAt-ge $now+86400000 -and $script:disposedUpdater -and !$script:updateProcess) 'unexpected updater exit reports failure, releases its handle and delays background retries'
  Write-Output ("All $checks isolated Windows updater assertions passed.")
} finally {
  Assert-WidgetUpdateChildPath $testRoot ([IO.Path]::GetTempPath())
  Remove-Item -LiteralPath $testRoot -Recurse -Force
}
