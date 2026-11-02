<#
    .SYNOPSIS
    Prepares the AL-Go actions on the agent and sets the job variables used by Invoke-AlGoAdoAction.ps1.

    .DESCRIPTION
    Downloads microsoft/AL-Go-Actions at the requested ref (branch, tag or commit SHA) once per agent,
    caches it under Agent.ToolsDirectory and appends a one-line hook to AL-Go-Helper.ps1 that loads
    the AL-Go4ADO overrides (only active when ALGO_ADO=true, i.e. when run through this wrapper).

    Self-hosted agents without access to github.com can point -LocalActionsPath to a vendored copy.

    .PARAMETER AlGoVersion
    Ref of the actions repository. Pin a commit SHA or a version branch (e.g. v10.0).
    .PARAMETER ActionsRepo
    owner/repo of the actions repository (default microsoft/AL-Go-Actions).
    .PARAMETER LocalActionsPath
    Optional folder containing the AL-Go actions (same layout as microsoft/AL-Go-Actions).
    .PARAMETER Workspace
    Folder containing the checked-out AL-Go repository.
    .PARAMETER RefreshHours
    How long a cached download of a branch ref is reused before it is downloaded again (SHAs are cached forever).
#>
Param(
    [string] $AlGoVersion = 'v10.0',
    [string] $ActionsRepo = 'microsoft/AL-Go-Actions',
    [string] $LocalActionsPath = '',
    [string] $Workspace = $env:BUILD_SOURCESDIRECTORY,
    [int] $RefreshHours = 12
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0

$hookMarker = '# >>> AL-Go4ADO hook'
$hook = @"

$hookMarker
if (`$env:ALGO_ADO -eq 'true' -and `$env:ALGO_ADO_SRC) { . (Join-Path `$env:ALGO_ADO_SRC 'AlGoAdo.Overrides.ps1') }
# <<< AL-Go4ADO hook
"@

function Add-AlGoAdoHook([string] $actionsPath) {
    $helper = Join-Path $actionsPath 'AL-Go-Helper.ps1'
    if (-not (Test-Path $helper)) { throw "AL-Go-Helper.ps1 not found in $actionsPath - is this an AL-Go actions folder?" }
    $content = [System.IO.File]::ReadAllText($helper)
    if (-not $content.Contains($hookMarker)) {
        [System.IO.File]::AppendAllText($helper, $hook, (New-Object System.Text.UTF8Encoding($true)))
        Write-Host "Added AL-Go4ADO hook to $helper"
    }
}

$toolsRoot = $(if ($env:AGENT_TOOLSDIRECTORY) { $env:AGENT_TOOLSDIRECTORY } else { Join-Path ([System.IO.Path]::GetTempPath()) 'al-go-ado-tools' })

if ($LocalActionsPath) {
    $source = (Resolve-Path $LocalActionsPath).Path
    $actionsPath = Join-Path $toolsRoot "al-go-ado/AL-Go-Actions/local"
    Write-Host "Using local AL-Go actions from $source"
    if (Test-Path $actionsPath) { Remove-Item $actionsPath -Recurse -Force }
    New-Item -Path $actionsPath -ItemType Directory -Force | Out-Null
    Copy-Item -Path (Join-Path $source '*') -Destination $actionsPath -Recurse -Force
    Add-AlGoAdoHook $actionsPath
}
else {
    $owner, $repo = $ActionsRepo.Split('/')
    # Layout <owner>/<repo>/<ref>/<Action> is relied upon by AL-Go (RunPipeline derives its version from the path)
    $actionsPath = Join-Path $toolsRoot (Join-Path $owner (Join-Path $repo $AlGoVersion))
    $stampFile = Join-Path $actionsPath '.al-go-ado-downloaded'
    $isSha = $AlGoVersion -match '^[0-9a-f]{40}$'
    $useCache = $false
    if (Test-Path $stampFile) {
        $age = (Get-Date) - (Get-Item $stampFile).LastWriteTime
        $useCache = $isSha -or $age.TotalHours -lt $RefreshHours
    }
    if ($useCache) {
        Write-Host "Using cached AL-Go actions $ActionsRepo@$AlGoVersion ($actionsPath)"
    }
    else {
        $url = "https://github.com/$ActionsRepo/archive/$AlGoVersion.zip"
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
        New-Item -Path $tmp -ItemType Directory | Out-Null
        try {
            $zip = Join-Path $tmp 'actions.zip'
            Write-Host "Downloading $url"
            $attempt = 0
            while ($true) {
                try { Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing; break }
                catch {
                    if (++$attempt -ge 3) { throw "Unable to download AL-Go actions from $url. Error: $($_.Exception.Message)" }
                    Start-Sleep -Seconds (10 * $attempt)
                }
            }
            $extract = Join-Path $tmp 'x'
            Expand-Archive -Path $zip -DestinationPath $extract
            $root = Get-ChildItem -Path $extract -Directory | Select-Object -First 1
            if (Test-Path $actionsPath) { Remove-Item $actionsPath -Recurse -Force }
            New-Item -Path (Split-Path $actionsPath -Parent) -ItemType Directory -Force | Out-Null
            Move-Item -Path $root.FullName -Destination $actionsPath
            Add-AlGoAdoHook $actionsPath
            Set-Content -Path $stampFile -Value "$ActionsRepo@$AlGoVersion $(Get-Date -Format o)"
        }
        finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Add-AlGoAdoHook $actionsPath
}

if (-not $Workspace) { $Workspace = (Get-Location).Path }
Write-Host "AL-Go actions : $actionsPath"
Write-Host "AL-Go4ADO src : $PSScriptRoot"
Write-Host "Workspace     : $Workspace"
Write-Host "##vso[task.setvariable variable=ALGO_ACTIONS_PATH]$actionsPath"
Write-Host "##vso[task.setvariable variable=ALGO_ADO_SRC]$PSScriptRoot"
Write-Host "##vso[task.setvariable variable=ALGO_WORKSPACE]$Workspace"
