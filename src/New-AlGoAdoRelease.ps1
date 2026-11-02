<#
    .SYNOPSIS
    Creates an AL-Go release in Azure DevOps from a CI/CD run.

    .DESCRIPTION
    An AL-Go release in Azure DevOps consists of
      - build tags 'AL-Go-Release' and 'AL-Go-Release:<tag>' (+ 'AL-Go-Prerelease') on the CI/CD run,
      - a retention lease that keeps the run (and its artifacts) forever,
      - an annotated git tag <tag> on the commit the run was built from (message = release notes),
      - optionally a release branch release/<tag>.
    DownloadPreviousRelease, appDependencyProbingPaths (release_status: release) and
    PublishToEnvironment (version: latest / <tag>) find releases through these build tags.

    Required permissions for the project's build service identity:
      CI/CD pipeline : Edit build quality (tags), Manage builds (retention lease)
      Repository     : Contribute, Create tag, Create branch (release branch)
#>
Param(
    [Parameter(Mandatory = $true)]
    [string] $BuildId,
    [Parameter(Mandatory = $true)]
    [string] $Tag,
    [string] $Name = '',
    [string] $Prerelease = 'false',
    [string] $CreateReleaseBranch = 'false',
    [string] $Workspace = $env:ALGO_WORKSPACE
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AlGoAdo.Rest.psm1') -Force -DisableNameChecking

$isPrerelease = $Prerelease -in @('true', 'True', '1')
$createBranch = $CreateReleaseBranch -in @('true', 'True', '1')
if (-not $Name) { $Name = $Tag }
if ($Tag -notmatch '^[A-Za-z0-9._-]+$') { throw "Tag '$Tag' contains invalid characters (allowed: letters, digits, '.', '_', '-')" }

$build = Get-AdoBuild -BuildId $BuildId
Write-Host "Creating release '$Name' (tag $Tag) from run $($build.buildNumber) (id $BuildId) of $($build.definition.name), commit $($build.sourceVersion), branch $($build.sourceBranch)"
if ($build.status -ne 'completed' -or $build.result -notin @('succeeded', 'partiallySucceeded')) {
    throw "Run $BuildId is not a completed, successful run (status $($build.status), result $($build.result))"
}
if (@($build.tags) -notcontains 'AL-Go-CICD') {
    Write-Host "##[warning]Run $BuildId is not tagged AL-Go-CICD - it might not be an AL-Go CI/CD run"
}
$existing = @($build.tags | Where-Object { $_ -like 'AL-Go-Release:*' })
if ($existing) { throw "Run $BuildId is already released as $($existing -join ', ')" }

$repositoryId = $build.repository.id
$refs = Invoke-AdoRest -Path "_apis/git/repositories/$repositoryId/refs?filter=tags/$([Uri]::EscapeDataString($Tag))"
if (@($refs.value | Where-Object { $_.name -eq "refs/tags/$Tag" })) { throw "Tag $Tag already exists in the repository" }

$artifacts = @(Get-AdoBuildArtifacts -BuildId $BuildId | Where-Object { $_.name -match '-(Apps|TestApps|Dependencies|PowerPlatformSolution)-' })
if (-not $artifacts) { throw "Run $BuildId has no AL-Go app artifacts" }

# Release notes: commits since the previous release
$previous = Get-AdoBuilds -RepositoryId $repositoryId -Tags @('AL-Go-Release') -Top 50 -IncludePartiallySucceeded |
    Where-Object { $_.id -ne [int]$BuildId -and -not (@($_.tags) -contains 'AL-Go-Prerelease') } | Select-Object -First 1
$notes = @("## $Name", '')
$range = $build.sourceVersion
if ($previous) {
    $prevTag = "$(@($previous.tags | Where-Object { $_ -like 'AL-Go-Release:*' })[0])".Substring('AL-Go-Release:'.Length)
    $notes += "Changes since $prevTag"
    $range = "$($previous.sourceVersion)..$($build.sourceVersion)"
}
$notes += ''
if ($Workspace -and (Test-Path (Join-Path $Workspace '.git'))) {
    $ErrorActionPreference = 'Continue'   # git writes progress to stderr
    git -C $Workspace fetch --quiet origin $build.sourceVersion 2>&1 | Out-Null
    $log = @(git -C $Workspace log --no-merges --pretty=format:'- %s (%h, %an)' $range 2>$null | Select-Object -First 200)
    if ($LASTEXITCODE -eq 0 -and $log) { $notes += $log }
    $ErrorActionPreference = 'Stop'
}
$notes += ''
$notes += '### Artifacts'
$notes += @($artifacts | ForEach-Object { "- $($_.name)" })
$releaseNotes = $notes -join "`n"

Add-AdoBuildTag -BuildId $BuildId -Tag 'AL-Go-Release'
Add-AdoBuildTag -BuildId $BuildId -Tag "AL-Go-Release:$Tag"
if ($isPrerelease) { Add-AdoBuildTag -BuildId $BuildId -Tag 'AL-Go-Prerelease' }
Write-Host "Tagged run $BuildId"

try {
    Add-AdoRetentionLease -BuildId $BuildId -DefinitionId $build.definition.id -OwnerId "AL-Go-Release:$Tag"
    Write-Host "Added retention lease (run and artifacts are kept)"
}
catch {
    Write-Host "##vso[task.logissue type=warning]Could not add a retention lease to run $BuildId - artifacts may be deleted by retention policies. $($_.Exception.Message)"
}

New-AdoAnnotatedTag -RepositoryId $repositoryId -Name $Tag -CommitId $build.sourceVersion -Message $releaseNotes | Out-Null
Write-Host "Created tag $Tag on $($build.sourceVersion)"

if ($createBranch) {
    $branch = "release/$Tag"
    New-AdoBranch -RepositoryId $repositoryId -Name $branch -CommitId $build.sourceVersion | Out-Null
    Write-Host "Created branch $branch"
}

$summary = Join-Path $env:AGENT_TEMPDIRECTORY 'release-notes.md'
Set-Content -Path $summary -Value $releaseNotes -Encoding UTF8
Write-Host "##vso[task.uploadsummary]$summary"
Write-Host "##vso[build.updatebuildnumber]Release $Tag"
