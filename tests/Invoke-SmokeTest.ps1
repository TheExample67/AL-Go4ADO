<#
    .SYNOPSIS
    Local smoke test: runs real AL-Go actions through the AL-Go4ADO wrapper in a simulated Azure DevOps agent.

    .DESCRIPTION
    Use it to validate a new AL-Go version (-AlGoVersion) before bumping the default.
    It simulates what the agent does with logging commands (task.setvariable -> environment of later steps)
    and runs the Initialization flow and the start of a Build job for the sample repository.
    No Business Central artifacts are downloaded and telemetry is disabled.

    .EXAMPLE
    ./tests/Invoke-SmokeTest.ps1 -AlGoVersion v10.0
    ./tests/Invoke-SmokeTest.ps1 -LocalActionsPath C:\src\AL-Go\Actions
#>
Param(
    [string] $AlGoVersion = 'v10.0',
    [string] $LocalActionsPath = '',
    [string] $Sample = (Join-Path $PSScriptRoot '../samples/per-tenant-extension')
)

$ErrorActionPreference = 'Stop'
$src = (Resolve-Path (Join-Path $PSScriptRoot '../src')).Path
$root = Join-Path ([System.IO.Path]::GetTempPath()) "al-go-ado-smoke-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$workspace = Join-Path $root 'self'
New-Item $workspace -ItemType Directory -Force | Out-Null
Copy-Item -Path (Join-Path $Sample '*') -Destination $workspace -Recurse -Force
Get-ChildItem -Path $Sample -Force -Filter '.*' | Copy-Item -Destination $workspace -Recurse -Force

# A minimal app so that AL-Go has something to analyze
$appFolder = Join-Path $workspace 'HelloWorld'
New-Item $appFolder -ItemType Directory -Force | Out-Null
@{ id = [guid]::NewGuid().ToString(); name = 'HelloWorld'; publisher = 'Contoso'; version = '1.0.0.0'; application = '26.0.0.0'; platform = '1.0.0.0'; idRanges = @(@{ from = 50100; to = 50149 }); runtime = '15.0' } |
    ConvertTo-Json -Depth 5 | Set-Content (Join-Path $appFolder 'app.json') -Encoding UTF8
Set-Content -Path (Join-Path $appFolder 'HelloWorld.Codeunit.al') -Encoding UTF8 -Value 'codeunit 50100 "Hello World" { }'
$ErrorActionPreference = 'Continue'   # git writes progress/warnings to stderr
& git -C $workspace init --quiet -b main 2>&1 | Out-Null
& git -C $workspace -c core.autocrlf=false add --all 2>&1 | Out-Null
& git -C $workspace -c user.email=smoke@test -c user.name=smoke commit --quiet -m init 2>&1 | Out-Null
$ErrorActionPreference = 'Stop'

$savedEnv = @{}
Get-ChildItem env: | ForEach-Object { $savedEnv[$_.Name] = $_.Value }

function Reset-Job([string] $jobName) {
    $temp = Join-Path $root "temp-$jobName"
    if (Test-Path $temp) { Remove-Item $temp -Recurse -Force }
    New-Item $temp -ItemType Directory | Out-Null
    $env:AGENT_TEMPDIRECTORY = $temp
    $env:SYSTEM_JOBNAME = $jobName
}

# Simulated agent: run a step and process the logging commands it writes
$script:outputs = @{}
function Invoke-Step([string] $stepName, [scriptblock] $step) {
    Write-Host "---- $stepName" -ForegroundColor Cyan
    $lines = & $step *>&1 | ForEach-Object { "$_" }
    $exitCode = $LASTEXITCODE
    foreach ($line in $lines) {
        if ($line -match '^##vso\[task\.setvariable variable=([^;\]]+)(;[^\]]*)?\](.*)$') {
            $name = $Matches[1]; $props = "$($Matches[2])"; $value = $Matches[3].Replace('%0A', "`n").Replace('%0D', "`r").Replace('%AZP25', '%')
            if ($props -like '*isOutput=true*') { $script:outputs["$stepName.$name"] = $value }
            else { Set-Item -Path "env:$($name.ToUpperInvariant().Replace('.', '_'))" -Value $value }
        }
        elseif ($line -match '^##\[(group|endgroup|debug|section)\]' ) { if ($Matches[1] -ne 'debug') { Write-Host $line -ForegroundColor DarkGray } }
        else { Write-Host $line }
    }
    if ($exitCode -ne 0) { throw "Step $stepName failed with exit code $exitCode" }
}

function Invoke-Action([string] $action, [string] $stepName = $action, [hashtable] $inputs = @{}) {
    foreach ($k in $inputs.Keys) { Set-Item -Path "env:ALGO_INPUT_$k" -Value $inputs[$k] }
    try {
        Invoke-Step $stepName { & (Join-Path $src 'Invoke-AlGoAdoAction.ps1') -Action $action -StepName $stepName }
    }
    finally {
        foreach ($k in $inputs.Keys) { Remove-Item "env:ALGO_INPUT_$k" -ErrorAction SilentlyContinue }
    }
}

function Assert([bool] $condition, [string] $message) {
    if (-not $condition) { throw "ASSERTION FAILED: $message" }
    Write-Host "OK: $message" -ForegroundColor Green
}

try {
    $env:SYSTEM_COLLECTIONURI = 'https://dev.azure.com/contoso/'
    $env:SYSTEM_TEAMPROJECT = 'BC'
    $env:BUILD_REPOSITORY_NAME = 'MyApps'
    $env:BUILD_REPOSITORY_URI = 'https://dev.azure.com/contoso/BC/_git/MyApps'
    $env:BUILD_SOURCEBRANCH = 'refs/heads/main'
    $env:BUILD_SOURCEVERSION = (& git -C $workspace rev-parse HEAD)
    $env:BUILD_REASON = 'IndividualCI'
    $env:BUILD_BUILDID = '1001'
    $env:AL_GO_RUN_NUMBER = '7'
    $env:SYSTEM_JOBATTEMPT = '1'
    $env:ALGO_WORKFLOW_NAME = 'CI/CD'
    $env:AGENT_TOOLSDIRECTORY = Join-Path $root 'tools'
    $env:ALGoRepoSettings = '{"microsoftTelemetryConnectionString":""}'
    $env:SYSTEM_ACCESSTOKEN = 'smoke-test-token'   # no Azure DevOps REST calls are made in this flow

    # --- Initialization job
    Reset-Job 'Initialization'
    # The agent passes '$(Pipeline.Workspace)/self' - a path with mixed separators on Windows
    Invoke-Step 'Setup' { & (Join-Path $src 'Initialize-AlGoAdo.ps1') -AlGoVersion $AlGoVersion -LocalActionsPath $LocalActionsPath -Workspace "$root/self" }
    Assert ($env:ALGO_WORKSPACE -eq [System.IO.Path]::GetFullPath($workspace)) "Workspace is normalized ($env:ALGO_WORKSPACE)"
    Assert (Test-Path (Join-Path $env:ALGO_ACTIONS_PATH 'AL-Go-Helper.ps1')) 'AL-Go actions are available'
    Assert ((Get-Content (Join-Path $env:ALGO_ACTIONS_PATH 'AL-Go-Helper.ps1') -Raw).Contains('AL-Go4ADO hook')) 'Override hook is installed'

    Invoke-Action 'WorkflowInitialize' -inputs @{ actionsRepo = 'microsoft/AL-Go-Actions'; actionsRef = $AlGoVersion }
    Invoke-Action 'ReadSettings' -inputs @{ get = 'type' }
    Assert ($env:TYPE -eq 'PTE') 'ReadSettings published the type setting as a job variable'
    Invoke-Action 'DetermineProjectsToBuild' -inputs @{ maxBuildDepth = '3' }
    Assert ($script:outputs['DetermineProjectsToBuild.ProjectsJson'] -like '*"."*') 'DetermineProjectsToBuild found the root project'
    # Delivery: nuGetFeedUrl makes NuGet a delivery target (NuGetContext from System.AccessToken)
    $env:ALGO_NUGET_FEED_URL = 'https://pkgs.dev.azure.com/contoso/BC/_packaging/al-go/nuget/v3/index.json'
    Invoke-Action 'DetermineDeliveryTargets' 'DetermineDeliveryTargetSecrets' @{ projectsJson = $script:outputs['DetermineProjectsToBuild.ProjectsJson']; checkContextSecrets = 'false' }
    Assert ($script:outputs['DetermineDeliveryTargetSecrets.ContextSecrets'] -like '*NuGetContext*') 'Delivery target secrets include NuGetContext'
    Invoke-Action 'ReadSecrets' -inputs @{ getSecrets = $script:outputs['DetermineDeliveryTargetSecrets.ContextSecrets'] }
    $env:Secrets = $script:outputs['ReadSecrets.Secrets']
    Invoke-Action 'DetermineDeliveryTargets' -inputs @{ projectsJson = $script:outputs['DetermineProjectsToBuild.ProjectsJson']; checkContextSecrets = 'true' }
    Remove-Item env:Secrets
    Assert ($script:outputs['DetermineDeliveryTargets.DeliveryTargetsJson'] -eq '["NuGet"]') "Delivery targets: $($script:outputs['DetermineDeliveryTargets.DeliveryTargetsJson'])"

    $env:ALGO_ENVIRONMENTS = '[{"name": "QA", "adoEnvironment": "BC-QA"}]'
    Invoke-Step 'AlGoAdo' { & (Join-Path $src 'Set-AlGoAdoJobOutputs.ps1') -Mode Initialization -MaxBuildDepth 3 }
    Assert ($script:outputs['AlGoAdo.deploy_QA'] -eq 'False') 'QA is not deployed (DetermineDeploymentEnvironments did not run)'
    Assert ($script:outputs['AlGoAdo.deliverCount'] -eq '1' -and $script:outputs['AlGoAdo.deliverMatrix'] -eq '{"NuGet":{"deliveryTarget":"NuGet"}}') "Delivery matrix: $($script:outputs['AlGoAdo.deliverMatrix'])"
    Assert ($script:outputs['AlGoAdo.trackALAlerts'] -eq 'False') 'Code analysis is off by default'
    Assert ($script:outputs['AlGoAdo.count1'] -eq '1') 'Build matrix depth 1 has one entry'
    Assert ($script:outputs['AlGoAdo.count2'] -eq '0') 'Build matrix depth 2 is empty'
    $matrix = $script:outputs['AlGoAdo.matrix1'] | ConvertFrom-Json
    $entry = $matrix.PSObject.Properties | Select-Object -First 1

    # --- Build job (first matrix entry)
    Reset-Job 'Build1'
    Get-ChildItem env: | Where-Object { $_.Name -in @('TYPE', 'SETTINGS') } | ForEach-Object { Remove-Item "env:$($_.Name)" }
    $env:PROJECT = $entry.Value.project; $env:BUILDMODE = $entry.Value.buildMode
    Invoke-Action 'ReadSettings' -inputs @{ project = $env:PROJECT; buildMode = $env:BUILDMODE; get = 'useCompilerFolder,doNotRunTests,doNotSignApps,skipUpgrade,artifact' }
    Assert ($env:DONOTSIGNAPPS -in @('True', 'False')) 'Build settings are available'
    Invoke-Step 'EvaluateSettings' { & (Join-Path $src 'Set-AlGoAdoJobOutputs.ps1') -Mode BuildSettings -Project $env:PROJECT -Workspace $workspace }
    Assert ($env:ALGOWORKSPACECOMPILATION -in @('True', 'False')) 'Build conditions are evaluated'
    Invoke-Action 'DetermineBuildProject' -inputs @{ skippedProjectsJson = $script:outputs['DetermineProjectsToBuild.SkippedProjectsJson']; project = $env:PROJECT; baselineWorkflowRunId = '0'; buildMode = $env:BUILDMODE }
    Assert ($script:outputs['DetermineBuildProject.BuildIt'] -eq 'True') 'DetermineBuildProject decided to build'
    Invoke-Action 'ReadSecrets' -inputs @{ getSecrets = 'licenseFileUrl,appDependencySecrets,AZURE_CREDENTIALS' }
    Assert ($null -ne $script:outputs['ReadSecrets.Secrets']) 'ReadSecrets produced a Secrets output'
    Invoke-Action 'CalculateArtifactNames' -inputs @{ project = $env:PROJECT; buildMode = $env:BUILDMODE }
    Assert (-not $script:outputs.ContainsKey('CalculateArtifactNames.BuildMode')) 'Reserved output BuildMode is not set as an Azure DevOps variable'
    Assert ($script:outputs['CalculateArtifactNames.AppsArtifactsName'] -like 'MyApps-main-Apps-*') "Artifact name is $($script:outputs['CalculateArtifactNames.AppsArtifactsName'])"

    # --- Code analysis job: compiler error log -> SARIF (AL-Go) -> summary + artifact folder
    Reset-Job 'CodeAnalysis'
    $errorLogs = Join-Path $workspace 'ErrorLogs/MyApps-main-ErrorLogs-1.0.7.0'
    New-Item $errorLogs -ItemType Directory -Force | Out-Null
    $alFile = 'C:\agent\_work\9\self\HelloWorld\HelloWorld.Codeunit.al'   # path from another agent, mapped by file name
    $issue = { param($rule, $severity, $line) [ordered]@{ ruleId = $rule; shortMessage = "$rule message"; fullMessage = "$rule description"
            locations = @(@{ analysisTarget = @(@{ uri = $alFile; region = @{ startLine = $line; startColumn = 1; endLine = $line; endColumn = 5 } }) })
            properties = @{ severity = $severity; category = 'Compiler'; helpLink = "https://learn.microsoft.com/$rule" } } }
    @{ version = '1.0.0'; issues = @((& $issue 'AL0432' 'Warning' 1), (& $issue 'AL0432' 'Warning' 2), (& $issue 'AL0603' 'Warning' 3)) } |
        ConvertTo-Json -Depth 10 | Set-Content (Join-Path $errorLogs 'HelloWorld.errorLog.json') -Encoding UTF8
    Invoke-Action 'ProcessALCodeAnalysisLogs' -inputs @{ errorLogsFolder = 'ErrorLogs' }
    $sarif = Get-Content (Join-Path $workspace 'ErrorLogs/output.sarif.json') -Raw | ConvertFrom-Json
    Assert (@($sarif.runs[0].results).Count -eq 3) "SARIF has 3 results"
    Assert ($sarif.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri -eq 'HelloWorld/HelloWorld.Codeunit.al') 'SARIF paths are relative to the repository'
    $env:BUILD_ARTIFACTSTAGINGDIRECTORY = Join-Path $root 'staging'
    Invoke-Step 'PublishCodeAnalysis' { & (Join-Path $src 'Publish-AlGoAdoCodeAnalysis.ps1') }
    Assert ($env:ALGOHASSARIF -eq 'True' -and (Test-Path (Join-Path $root 'staging/CodeAnalysisLogs/ALCodeAnalysis.sarif'))) 'SARIF copied for the CodeAnalysisLogs artifact'
    $summary = Get-Content (Join-Path $env:AGENT_TEMPDIRECTORY 'al-code-analysis.md') -Raw
    Assert ($summary -match '\*\*3\*\* issue' -and $summary -match '\| AL0432 \| 2 \|' -and $summary -match '\| HelloWorld \| 3 \|') 'Code analysis summary lists issues per rule and app folder'

    Write-Host "Smoke test succeeded" -ForegroundColor Green
}
finally {
    # restore environment
    Get-ChildItem env: | Where-Object { -not $savedEnv.ContainsKey($_.Name) } | ForEach-Object { Remove-Item "env:$($_.Name)" }
    foreach ($k in $savedEnv.Keys) { Set-Item -Path "env:$k" -Value $savedEnv[$k] }
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}
