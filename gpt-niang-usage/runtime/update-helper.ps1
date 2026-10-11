param([string]$Token,[switch]$Recover,[switch]$FunctionsOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'supervisor-task.ps1')
. (Join-Path $PSScriptRoot 'update-common.ps1')
. (Join-Path $PSScriptRoot 'install-preflight.ps1')

function Assert-WidgetUpdateTransaction($Journal,[string]$AgentDir) {
  if(!$Journal -or $Journal.schema-ne 1 -or $Journal.token-notmatch '^[a-f0-9-]{36}$'){throw 'Invalid update transaction.'}
  $null=Assert-WidgetUpdateBinding $Journal.appDir $Journal.dataDir $AgentDir
  $root=[IO.Path]::GetFullPath($Journal.root).TrimEnd('\')
  if([IO.Path]::GetFullPath($Journal.appDir)-ine (Join-Path $root 'gpt-niang-usage') -or !(Split-Path $root -Leaf) -or !(Split-Path (Split-Path $root -Parent) -Leaf)){throw 'Unsafe program root.'}
  Assert-WidgetNoReparsePoint $root
  Assert-WidgetNoReparsePoint $Journal.dataDir
  for($dir=$root;$dir;$dir=Split-Path $dir -Parent){if(Test-Path -LiteralPath (Join-Path $dir '.git')){throw 'Source checkout cannot be replaced by the updater.'}}
  $job=Join-Path $Journal.dataDir ('updates\'+$Journal.token)
  Assert-WidgetUpdateChildPath $Journal.candidate $job
  if([IO.Path]::GetFullPath($Journal.archive)-ine (Join-Path $job 'release.zip')){throw 'Unexpected update archive path.'}
  $Journal|Add-Member backup ($root+'.backup-'+$Journal.token) -Force
  $Journal|Add-Member nextRoot ($root+'.next-'+$Journal.token) -Force
  $Journal|Add-Member failedRoot ($root+'.failed-'+$Journal.token) -Force
  foreach($target in @($Journal.backup,$Journal.nextRoot,$Journal.failedRoot)){Assert-WidgetUpdateChildPath $target (Split-Path $root -Parent);Assert-WidgetNoReparsePoint $target}
}
function Set-WidgetUpdatePhase($Journal,[string]$Phase,[string]$AgentDir) {
  $Journal.phase=$Phase
  Write-WidgetSupervisorJson (Join-Path $AgentDir 'update-transaction.json') $Journal
}
function Copy-WidgetVerifiedTree([string]$Source,[string]$Destination) {
  Assert-WidgetNoReparsePoint $Source
  $items=@(Get-ChildItem -LiteralPath $Source -Force -Recurse)
  foreach($item in $items){if($item.Attributes-band [IO.FileAttributes]::ReparsePoint){throw 'Links are forbidden in a copied update tree.'}}
  $null=New-Item -ItemType Directory -Path $Destination -Force
  foreach($item in $items){
    $relative=$item.FullName.Substring($Source.TrimEnd('\').Length).TrimStart('\')
    $target=Join-Path $Destination $relative;Assert-WidgetUpdateChildPath $target $Destination
    if($item.PSIsContainer){$null=New-Item -ItemType Directory -Path $target -Force}
    else {
      $null=New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force
      Copy-Item -LiteralPath $item.FullName -Destination $target -Force
      if((Get-WidgetFileHash $item.FullName)-ne (Get-WidgetFileHash $target)){throw 'Copied update/data file verification failed.'}
    }
  }
}
function Wait-WidgetUpdateIdle($Journal) {
  while($true){
    $idle=Read-WidgetUpdateJson (Join-Path $Journal.dataDir 'update-idle.json')
    $worker=Read-WidgetUpdateJson (Join-Path $Journal.dataDir 'worker-status.json')
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if(!$idle -or !(Get-Process -Id ([int]$idle.pid) -ErrorAction SilentlyContinue) -or $now-[long]$idle.at-gt 60000){throw 'Widget closed before update installation.'}
    if($Journal.mode-eq 'automatic'){
      $preferences=Read-WidgetUpdateJson (Join-Path $Journal.dataDir 'update-preferences.json')
      if($preferences -and $preferences.automatic-eq $false){throw 'Automatic update was disabled before installation.'}
    }
    if($idle -and $now-[long]$idle.at-ge 0 -and $now-[long]$idle.at-lt 5000 -and (Get-Process -Id ([int]$idle.pid) -ErrorAction SilentlyContinue) -and !$idle.editor -and !$idle.menu -and !$idle.drag -and !$worker.busy){return}
    Start-Sleep -Milliseconds 500
  }
}
function Wait-WidgetUpdatedHealth($Journal) {
  $config=Read-WidgetUpdateJson (Join-Path $Journal.appDir 'installation.json')
  Assert-WidgetPluginRegistration $config.codexPath $Journal.version
  $deadline=[DateTime]::UtcNow.AddSeconds(30)
  do {
    $status=Read-WidgetUpdateJson (Join-Path $Journal.dataDir 'supervisor-status.json')
    if($status -and ([DateTime]::UtcNow-([DateTime]$status.at).ToUniversalTime()).TotalSeconds-lt 10 -and ([DateTime]$status.at).ToUniversalTime()-ge ([DateTime]$Journal.installStartedAt).ToUniversalTime()) {
      $process=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$status.pid) -ErrorAction Stop
      $expected='"'+(Join-Path (Get-WidgetUpdateAgentDir) 'update-agent.ps1')+'"'
      if($process -and $process.Name-in @('powershell.exe','pwsh.exe') -and $process.CommandLine.IndexOf($expected,[StringComparison]::OrdinalIgnoreCase)-ge 0){return}
    }
    Start-Sleep -Milliseconds 500
  }while([DateTime]::UtcNow-lt $deadline)
  throw 'New supervisor heartbeat was not confirmed.'
}
function Invoke-WidgetUpdateInstaller($Journal,[string]$Token) {
  & (Join-Path $Journal.appDir 'Install.ps1') -UpdateToken $Token
}
function Assert-WidgetCandidatePackage($Journal,$Configuration) {
  & $Configuration.nodePath (Join-Path $Journal.appDir 'runtime\update.mjs') '--validate-package' $Journal.archive $Journal.candidate $Journal.version $Journal.hash
  if($LASTEXITCODE-ne 0){throw 'Candidate package changed after download validation.'}
}
function Restore-WidgetUpdate($Journal,[string]$AgentDir,[string]$Token) {
  if($Journal.phase-eq 'recovery-failed'){throw 'Recovery already failed; automatic retry is disabled.'}
  if($Journal.phase-eq 'prepared'){Set-WidgetUpdatePhase $Journal 'rolled-back' $AgentDir;return}
  if(Test-Path -LiteralPath $Journal.backup){
    # A newly registered version must release its files before restoration.
    if(Test-Path -LiteralPath (Join-Path $Journal.appDir 'installation.json')){
      Stop-WidgetSupervisorTask $Journal.appDir
      Stop-WidgetGui $Journal.appDir $Journal.dataDir
    }
    Set-WidgetUpdatePhase $Journal 'restoring' $AgentDir
    if(Test-Path -LiteralPath $Journal.root){
      if(Test-Path -LiteralPath $Journal.failedRoot){throw 'Failed version backup already exists.'}
      [IO.Directory]::Move($Journal.root,$Journal.failedRoot)
    }
    [IO.Directory]::Move($Journal.backup,$Journal.root)
  }
  if(!(Test-Path -LiteralPath (Join-Path $Journal.appDir 'installation.json'))){throw 'Old installation is unavailable for recovery.'}
  $config=Read-WidgetUpdateJson (Join-Path $Journal.appDir 'installation.json')
  if($config.version-ne $Journal.oldVersion){throw 'Recovered installation version mismatch.'}
  # Re-register even when interrupted between the two directory renames.
  Set-WidgetUpdatePhase $Journal 'registering-old' $AgentDir
  Invoke-WidgetUpdateInstaller $Journal $Token
  Set-WidgetUpdatePhase $Journal 'rolled-back' $AgentDir
  Write-WidgetSupervisorJson (Join-Path $Journal.dataDir 'update-status.json') @{phase='rolled-back';message='Update failed; the previous version was restored.';nextCheckAt=[DateTimeOffset]::UtcNow.AddDays(1).ToUnixTimeMilliseconds()}
}
function Invoke-WidgetUpdateTransaction($Journal,[string]$AgentDir,[string]$Token,[switch]$Recover) {
  Assert-WidgetUpdateTransaction $Journal $AgentDir
  $flag=Join-Path $Journal.dataDir 'update-installing.json'
  try {
    if($Recover){Restore-WidgetUpdate $Journal $AgentDir $Token;return}
    if($Journal.phase-ne 'prepared'){throw 'Update transaction is not prepared.'}
    if((Get-WidgetFileHash $Journal.archive)-ine $Journal.hash){throw 'Downloaded archive changed before installation.'}
    $candidateApp=Join-Path $Journal.candidate 'gpt-niang-usage'
    $config=Get-WidgetInstallPreflight -SourceDir $candidateApp -AppDir $Journal.appDir
    if($config.version-ne $Journal.version -or $config.dataDir-ine $Journal.dataDir){throw 'Candidate installation identity mismatch.'}
    if($Journal.dataDir.StartsWith($Journal.root+'\',[StringComparison]::OrdinalIgnoreCase)){
      $relative=$Journal.dataDir.Substring($Journal.root.Length+1)
      if(Test-Path -LiteralPath (Join-Path $Journal.candidate $relative)){throw 'Data directory overlaps candidate program files.'}
    }
    Assert-WidgetCandidatePackage $Journal $config
    if(Test-Path -LiteralPath $Journal.nextRoot){throw 'Update staging directory already exists.'}
    Copy-WidgetVerifiedTree $Journal.candidate $Journal.nextRoot
    # Use the validated existing installation configuration, not a downloaded path.
    Copy-Item -LiteralPath (Join-Path $Journal.appDir 'installation.json') -Destination (Join-Path $Journal.nextRoot 'gpt-niang-usage\installation.json')
    Wait-WidgetUpdateIdle $Journal
    Write-WidgetSupervisorJson $flag @{token=$Token;pid=$PID;startedAt=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')}
    Set-WidgetUpdatePhase $Journal 'stopping' $AgentDir
    Stop-WidgetSupervisorTask $Journal.appDir
    Stop-WidgetGui $Journal.appDir $Journal.dataDir
    # Headless MCP workers also exit on the installation flag. Wait for their handle.
    $worker=Read-WidgetUpdateJson (Join-Path $Journal.dataDir 'worker-status.json')
    if($worker.pid -and (Get-Process -Id ([int]$worker.pid) -ErrorAction SilentlyContinue)){
      $deadline=[DateTime]::UtcNow.AddSeconds(10)
      while((Test-Path -LiteralPath (Join-Path $Journal.dataDir 'worker-status.json')) -and [DateTime]::UtcNow-lt $deadline){Start-Sleep -Milliseconds 100}
      if(Test-Path -LiteralPath (Join-Path $Journal.dataDir 'worker-status.json')){throw 'Quota worker did not stop.'}
    }
    if($Journal.dataDir.StartsWith($Journal.root+'\',[StringComparison]::OrdinalIgnoreCase)) {
      $relative=$Journal.dataDir.Substring($Journal.root.Length+1)
      if($relative-ieq 'gpt-niang-usage' -or $relative.StartsWith('gpt-niang-usage\runtime\',[StringComparison]::OrdinalIgnoreCase)){throw 'Data directory overlaps program files.'}
      Copy-WidgetVerifiedTree $Journal.dataDir (Join-Path $Journal.nextRoot $relative)
    }
    if(Test-Path -LiteralPath $Journal.backup){throw 'Old-version backup already exists.'}
    # Persist intent before each rename; recovery uses actual directory presence.
    Set-WidgetUpdatePhase $Journal 'moving-old' $AgentDir
    [IO.Directory]::Move($Journal.root,$Journal.backup)
    Set-WidgetUpdatePhase $Journal 'moving-new' $AgentDir
    [IO.Directory]::Move($Journal.nextRoot,$Journal.root)
    $Journal|Add-Member installStartedAt ([DateTime]::UtcNow.ToString('o')) -Force
    Set-WidgetUpdatePhase $Journal 'registering' $AgentDir
    Invoke-WidgetUpdateInstaller $Journal $Token
    Wait-WidgetUpdatedHealth $Journal
    Set-WidgetUpdatePhase $Journal 'committed' $AgentDir
    Write-WidgetSupervisorJson (Join-Path $Journal.dataDir 'update-status.json') @{phase='updated';version=$Journal.version;message=('Updated to '+$Journal.version);nextCheckAt=[DateTimeOffset]::UtcNow.AddDays(1).ToUnixTimeMilliseconds();backup=$Journal.backup}
  } catch {
    $failure=$_.Exception.ToString()
    # Once health and registration are confirmed, a status-file write failure
    # must not roll the completed installation back.
    if($Journal.phase-eq 'committed'){
      try{[IO.File]::WriteAllText((Join-Path $AgentDir 'update-diagnostic.txt'),$failure,[Text.UTF8Encoding]::new($false))}catch{}
      return
    }
    try{if($Recover){throw 'Restart recovery failed; no second automatic attempt.'};Restore-WidgetUpdate $Journal $AgentDir $Token}
    catch{
      Set-WidgetUpdatePhase $Journal 'recovery-failed' $AgentDir
      $failure+=[Environment]::NewLine+'Recovery: '+$_.Exception.ToString()
    }
    [IO.File]::WriteAllText((Join-Path $AgentDir 'update-diagnostic.txt'),$failure,[Text.UTF8Encoding]::new($false))
    throw $failure
  } finally {
    if(Test-Path -LiteralPath $flag){Remove-Item -LiteralPath $flag}
  }
}

if($FunctionsOnly){return}
$agentDir=$PSScriptRoot
$lock=$null
try {
  $journal=Read-WidgetUpdateJson (Join-Path $agentDir 'update-transaction.json')
  if($Recover){$lock=Enter-WidgetUpdateLock -AgentDir $agentDir;$Token=$lock.Token}
  else {$lock=Enter-WidgetUpdateLock -AgentDir $agentDir -Token $Token}
  Invoke-WidgetUpdateTransaction $journal $agentDir $Token -Recover:$Recover
} finally {Exit-WidgetUpdateLock $lock}
