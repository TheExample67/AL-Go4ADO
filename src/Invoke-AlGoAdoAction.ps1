<#
    .SYNOPSIS
    Runs an upstream AL-Go action inside an Azure DevOps pipeline step.

    .DESCRIPTION
    - Restores the job state (GITHUB_ENV entries written by earlier AL-Go steps in this job)
    - Computes the GITHUB_* environment from Azure DevOps predefined variables
    - Runs the AL-Go action script in a child process of the same PowerShell edition and
      translates GitHub workflow commands in its output to Azure DevOps logging commands
    - Publishes GITHUB_OUTPUT entries as ADO output variables ($(<StepName>.<Name>)) and
      GITHUB_ENV entries as ADO job variables (and job state)

    Action inputs are passed as environment variables named ALGO_INPUT_<parameterName>.

    .PARAMETER Action
    Name of the AL-Go action (folder name in microsoft/AL-Go-Actions), e.g. ReadSettings.
    .PARAMETER StepName
    Name of the ADO step. Must match the step's `name:` for output variables to resolve.
    .PARAMETER Script
    Optional script file inside the action folder, when the action has more than one (e.g. ComputeDependencyArtifactPattern.ps1).
#>
Param(
    [Parameter(Mandatory = $true)]
    [string] $Action,
    [string] $StepName = '',
    [string] $Script = '',
    [string] $ActionsPath = $env:ALGO_ACTIONS_PATH,
    [string] $Workspace = $env:ALGO_WORKSPACE
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'AlGoAdo.Shim.psm1') -Force -DisableNameChecking

if (-not $StepName) { $StepName = $Action }
if (-not $Workspace) { $Workspace = $env:BUILD_SOURCESDIRECTORY }
if (-not $ActionsPath -or -not (Test-Path $ActionsPath)) {
    throw "AL-Go actions not found ('$ActionsPath'). Make sure the setup step (templates/steps/setup.yml) ran in this job."
}

$adoEnv = @{}
Get-ChildItem env: | ForEach-Object { $adoEnv[$_.Name] = $_.Value }

# Job state - lives in Agent.TempDirectory, which the agent cleans after every job
$tempRoot = if ($env:AGENT_TEMPDIRECTORY) { $env:AGENT_TEMPDIRECTORY } else { [System.IO.Path]::GetTempPath() }
$stateFolder = Join-Path $tempRoot 'al-go-ado'
New-Item -Path $stateFolder -ItemType Directory -Force | Out-Null
$stateFile = Join-Path $stateFolder 'state.json'
$state = [ordered]@{ env = [ordered]@{}; outputs = [ordered]@{} }
if (Test-Path $stateFile) {
    $loaded = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $loaded.env.PSObject.Properties) { $state.env[$p.Name] = $p.Value }
    foreach ($p in $loaded.outputs.PSObject.Properties) { $state.outputs[$p.Name] = $p.Value }
}

# GitHub environment
$gitHubEnv = Get-AlGoGitHubEnvironment -AdoEnv $adoEnv -Workspace $Workspace -ActionsPath $ActionsPath -ActionName $Action

# Event payload - created once per job
$eventFile = Join-Path $stateFolder 'event.json'
if (-not (Test-Path $eventFile)) {
    $baseSha = ''
    if ($gitHubEnv.GITHUB_EVENT_NAME -eq 'pull_request') {
        # ADO builds PRs from the merge commit; its first parent is the target branch tip
        $ErrorActionPreference = 'Continue'
        $baseSha = & git -C $Workspace rev-parse 'HEAD^1' 2>$null
        if ($LASTEXITCODE -ne 0) { $baseSha = '' }
        $ErrorActionPreference = 'Stop'
    }
    $payload = New-AlGoEventPayload -AdoEnv $adoEnv -GitHubEnv $gitHubEnv -BaseSha "$baseSha".Trim() -InputsJson "$env:ALGO_EVENT_INPUTS"
    $payload | ConvertTo-Json -Depth 10 | Set-Content -Path $eventFile -Encoding UTF8
}

$stepId = "$StepName.$([guid]::NewGuid().ToString('N').Substring(0,8))"
$outputFile = Join-Path $stateFolder "$stepId.output"
$envFile = Join-Path $stateFolder "$stepId.env"
$summaryFile = Join-Path $stateFolder "$stepId.summary.md"
foreach ($f in @($outputFile, $envFile, $summaryFile)) { New-Item -Path $f -ItemType File -Force | Out-Null }

# Remove unresolved ADO macros like "$(ReadSecrets.Secrets)" from the environment
Get-ChildItem env: | Where-Object { $_.Value -match '^\$\([^)]+\)$' } | ForEach-Object { Remove-Item "env:$($_.Name)" }

foreach ($key in $state.env.Keys) { Set-Item -Path "env:$key" -Value "$($state.env[$key])" }
foreach ($key in $gitHubEnv.Keys) {
    if ("$($gitHubEnv[$key])") { Set-Item -Path "env:$key" -Value "$($gitHubEnv[$key])" }
    else { Remove-Item "env:$key" -ErrorAction SilentlyContinue }
}
$env:GITHUB_OUTPUT = $outputFile
$env:GITHUB_ENV = $envFile
$env:GITHUB_STEP_SUMMARY = $summaryFile
$env:GITHUB_EVENT_PATH = $eventFile

# Resolve the action script
$actionFolder = Join-Path $ActionsPath $Action
if (-not (Test-Path $actionFolder)) { throw "Unknown AL-Go action '$Action' (folder $actionFolder not found)" }
if ($Script) {
    $scriptPath = Join-Path $actionFolder $Script
}
else {
    $scriptPath = @("$Action.Action.ps1", "$Action.ps1") | ForEach-Object { Join-Path $actionFolder $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $scriptPath -or -not (Test-Path $scriptPath)) { throw "No script found for AL-Go action '$Action' in $actionFolder" }

# Map inputs (ALGO_INPUT_<name>) to script parameters
$inputs = @{}
Get-ChildItem env: | Where-Object { $_.Name -like 'ALGO_INPUT_*' } | ForEach-Object {
    $inputs[$_.Name.Substring(11)] = $_.Value
    Remove-Item "env:$($_.Name)"
}
# Inputs of the form "fromSecrets:<name>" are resolved from the Secrets JSON produced by ReadSecrets
# (the ADO equivalent of fromJson(steps.ReadSecrets.outputs.Secrets).<name>)
foreach ($key in @($inputs.Keys)) {
    if ("$($inputs[$key])" -like 'fromSecrets:*') {
        $secretName = "$($inputs[$key])".Substring('fromSecrets:'.Length)
        $value = ''
        if ($env:Secrets) {
            $secrets = $env:Secrets | ConvertFrom-Json
            if (@($secrets.PSObject.Properties | ForEach-Object { $_.Name }) -contains $secretName) { $value = "$($secrets.$secretName)" }
        }
        $inputs[$key] = $value
    }
}

# ReadSecrets: build the "GitHub secrets" JSON from the secret variables mapped into the step as ALGO_SECRET_<name>
if ($Action -eq 'ReadSecrets' -and -not ($inputs.Keys | Where-Object { $_ -ieq 'gitHubSecrets' })) {
    $secretValues = [ordered]@{}
    Get-ChildItem env: | Where-Object { $_.Name -like 'ALGO_SECRET_*' } | ForEach-Object {
        if ($_.Value) { $secretValues[$_.Name.Substring(12)] = $_.Value }
        Remove-Item "env:$($_.Name)"
    }
    if ($env:SYSTEM_ACCESSTOKEN) { $secretValues['github_token'] = $env:SYSTEM_ACCESSTOKEN }
    Write-Host "Secrets available to ReadSecrets: $(@($secretValues.Keys | Where-Object { $_ -ne 'github_token' }) -join ', ')"
    $inputs['gitHubSecrets'] = ConvertTo-Json -InputObject $secretValues -Compress
}

$scriptParameters = (Get-Command $scriptPath).Parameters
$defaults = Get-ActionInputDefault -ActionFolder $actionFolder
$defaults['token'] = $env:SYSTEM_ACCESSTOKEN
$defaults['actor'] = $gitHubEnv.GITHUB_ACTOR
$defaults['baseFolder'] = $Workspace
Get-ChildItem env: | Where-Object { $_.Name -like 'ALGO_PARAM_*' } | ForEach-Object { Remove-Item "env:$($_.Name)" }
foreach ($name in $scriptParameters.Keys) {
    if ([System.Management.Automation.Cmdlet]::CommonParameters -contains $name) { continue }
    $inputKey = $inputs.Keys | Where-Object { $_ -ieq $name } | Select-Object -First 1
    if ($inputKey) {
        Set-Item -Path "env:ALGO_PARAM_$name" -Value $inputs[$inputKey]
    }
    elseif ($defaults.ContainsKey($name) -and $defaults[$name]) {
        Set-Item -Path "env:ALGO_PARAM_$name" -Value $defaults[$name]
    }
}
foreach ($inputKey in $inputs.Keys) {
    if (-not ($scriptParameters.Keys | Where-Object { $_ -ieq $inputKey })) {
        Write-Host "##[warning]Input '$inputKey' is not a parameter of $([System.IO.Path]::GetFileName($scriptPath)) and is ignored"
    }
}

# Run the action in a child process of the same PowerShell edition and translate its output
$psExe = (Get-Process -Id $PID).Path
$childScript = Join-Path $PSScriptRoot 'Invoke-AlGoAdoActionChild.ps1'
Write-Host "##[debug]Running AL-Go action $Action ($scriptPath) with $psExe"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { Write-Verbose 'Console encoding could not be set' }

$ErrorActionPreference = 'Continue'
& $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $childScript -ActionsPath $ActionsPath -ActionName $Action -ScriptPath $scriptPath 2>&1 | ForEach-Object {
    $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { "$($_.Exception.Message)" } else { "$_" }
    $translated = ConvertTo-AdoLogLine -Line $line
    if ($null -ne $translated) { Write-Host $translated }
}
$exitCode = $LASTEXITCODE
$ErrorActionPreference = 'Stop'

# Publish GITHUB_ENV entries: job state + ADO variables (for conditions in later steps)
$newEnv = Read-GitHubFileCommand -Path $envFile
foreach ($key in $newEnv.Keys) {
    $state.env[$key] = $newEnv[$key]
    if ("$($newEnv[$key])".Length -gt 16000) {
        # Large values (e.g. the full Settings JSON) stay in the job state only - they are not needed in conditions
        Write-Host "##[debug]$key is only kept in the AL-Go job state ($("$($newEnv[$key])".Length) characters)"
        continue
    }
    Write-Host (Format-AdoSetVariable -Name $key -Value $newEnv[$key] -IsSecret:(Test-SecretVariableName $key))
}

# Publish GITHUB_OUTPUT entries as output variables: $(StepName.Name) / dependencies.<job>.outputs['StepName.Name']
$newOutputs = Read-GitHubFileCommand -Path $outputFile
$stepOutputs = [ordered]@{}
foreach ($key in $newOutputs.Keys) {
    $isSecret = Test-SecretVariableName $key
    if (-not $isSecret) { $stepOutputs[$key] = $newOutputs[$key] }
    Write-Host (Format-AdoSetVariable -Name $key -Value $newOutputs[$key] -IsOutput -IsSecret:$isSecret)
}
$state.outputs[$StepName] = $stepOutputs
$state | ConvertTo-Json -Depth 10 | Set-Content -Path $stateFile -Encoding UTF8

if ((Get-Item $summaryFile).Length -gt 0) {
    Write-Host "##vso[task.uploadsummary]$summaryFile"
}

if ($exitCode -ne 0) {
    Write-Host "##[error]AL-Go action $Action failed with exit code $exitCode"
}
exit $exitCode
