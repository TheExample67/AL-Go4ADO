<#
    AL-Go for Azure DevOps - overrides of AL-Go functions that call the GitHub API.

    This file is copied next to AL-Go-Helper.ps1 by Initialize-AlGoAdo.ps1 and dot-sourced at the
    end of AL-Go-Helper.ps1 (only when ALGO_ADO=true). Functions defined here replace the GitHub
    implementations in the calling scope and in the global scope.

    Release model in Azure DevOps:
      A release is a CI/CD build tagged 'AL-Go-Release' and 'AL-Go-Release:<tag>'
      (prereleases additionally 'AL-Go-Prerelease'), see templates/pipelines/create-release.yml.
    CI/CD builds are tagged 'AL-Go-CICD' (used as "last known good build" and for latestBuild dependencies).
#>

if (-not (Get-Module -Name 'AlGoAdo.Rest')) {
    Import-Module (Join-Path $PSScriptRoot 'AlGoAdo.Rest.psm1') -DisableNameChecking -Global
}

$script:AlGoAdoOverrideNames = @(
    'Get-AlGoAdoRepoTarget', 'Get-AlGoAdoArtifactRegex', 'ConvertTo-AlGoAdoRelease',
    'GetReleases', 'GetLatestRelease', 'DownloadRelease',
    'FindLatestSuccessfulCICDRun', 'GetArtifactsFromWorkflowRun', 'GetArtifacts', 'DownloadArtifact',
    'GetDependencies', 'GetGitHubEnvironments', 'Get-BranchesFromPolicy', 'IsGitHubPagesAvailable',
    'CloneIntoNewFolder', 'CommitFromNewFolder', 'TestRunnerPrerequisites'
)

<#
    Resolves "project/repo", a repository URL or empty (= current repository) to project + repository id.
#>
function Get-AlGoAdoRepoTarget([string] $repository) {
    if (-not $repository -or $repository -eq $env:GITHUB_REPOSITORY -or $repository -eq "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY") {
        return [PSCustomObject]@{ Project = $env:SYSTEM_TEAMPROJECT; RepositoryId = $env:BUILD_REPOSITORY_ID; Name = $env:BUILD_REPOSITORY_NAME }
    }
    $resolved = Resolve-AdoRepositoryUrl $repository
    if ($resolved) {
        $project = $resolved.Project; $repoName = $resolved.Repository
    }
    else {
        $parts = $repository.Trim('/').Split('/')
        $project = $parts[0]; $repoName = $parts[-1]
    }
    $repo = Get-AdoRepository -Project $project -Repository $repoName
    return [PSCustomObject]@{ Project = $project; RepositoryId = $repo.id; Name = $repo.name }
}

<#
    Regex matching AL-Go artifact names: <project>-<branch>-<mask>-<version>
#>
function Get-AlGoAdoArtifactRegex([string] $project, [string] $mask, [string] $branch = '', [string] $version = '') {
    $p = $(if (-not $project -or $project -eq '*') { '.+' } else { [regex]::Escape($project.Replace('\', '_').Replace('/', '_')).Replace('\*', '.*').Replace('\?', '.') })
    $b = $(if ($branch) { [regex]::Escape($branch.Replace('\', '_').Replace('/', '_')) } else { '.+' })
    $v = $(if (-not $version -or $version -eq 'latest' -or $version -eq '*') { '[^-]+' } else { [regex]::Escape($version) })
    return "^(?<project>$p)-$b-$([regex]::Escape($mask))-(?<version>$v)$"
}

function ConvertTo-AlGoAdoRelease($build, [string] $project) {
    $tag = @($build.tags | Where-Object { $_ -like 'AL-Go-Release:*' } | Select-Object -First 1)
    if (-not $tag) { return $null }
    $tagName = "$($tag[0])".Substring('AL-Go-Release:'.Length)
    [PSCustomObject]@{
        id               = $build.id
        buildId          = $build.id
        project          = $project
        tag_name         = $tagName
        name             = $tagName
        prerelease       = [bool](@($build.tags) -contains 'AL-Go-Prerelease')
        draft            = $false
        target_commitish = "$($build.sourceBranch)".Replace('refs/heads/', '')
        sha              = $build.sourceVersion
        html_url         = $build._links.web.href
        assets           = @()
    }
}

function GetReleases {
    Param(
        [string] $token,
        [string] $api_url = $ENV:GITHUB_API_URL,
        [string] $repository = $ENV:GITHUB_REPOSITORY
    )
    $target = Get-AlGoAdoRepoTarget $repository
    Write-Host "Getting releases (builds tagged AL-Go-Release) from $($target.Project)/$($target.Name)"
    $builds = Get-AdoBuilds -Project $target.Project -RepositoryId $target.RepositoryId -Tags @('AL-Go-Release') -Top 200 -IncludePartiallySucceeded
    $index = 0
    $releases = @($builds | ForEach-Object { ConvertTo-AlGoAdoRelease $_ $target.Project } | Where-Object { $_ } | ForEach-Object {
            $_ | Add-Member -NotePropertyName 'sortIndex' -NotePropertyValue ($index++) -PassThru
        })
    # Sort by semantic version (desc) where possible, otherwise keep finish time order
    $releases | Sort-Object -Property @{ Descending = $true; Expression = {
            $v = $_.tag_name -replace '^v', '' -replace '-.*$', ''
            $parsed = $null
            if ([System.Version]::TryParse($v, [ref] $parsed)) { $parsed } elseif ($v -match '^\d+$') { [System.Version]::new([int]$v, 0) } else { [System.Version]::new(0, 0) }
        }
    }, @{ Descending = $false; Expression = { $_.sortIndex } }
}

function GetLatestRelease {
    Param(
        [string] $token,
        [string] $api_url = $ENV:GITHUB_API_URL,
        [string] $repository = $ENV:GITHUB_REPOSITORY,
        [string] $ref = $ENV:GITHUB_REF_NAME
    )
    $releases = @(GetReleases -token $token -api_url $api_url -repository $repository | Where-Object { -not ($_.prerelease -or $_.draft) })
    if ($ref -like 'release/*' -or $ref -like 'releases/*') {
        $cleanVersion = ($ref -split '/' | Select-Object -Last 1) -replace '^v', '' -replace '\.?x$', ''
        if ($cleanVersion -match '^\d+(\.\d+)?$') {
            $prefix = "$cleanVersion."
            $releases = @($releases | Where-Object { ($_.tag_name -replace '^v', '').StartsWith($prefix) -or ($_.tag_name -replace '^v', '') -eq $cleanVersion })
        }
    }
    $releases | Select-Object -First 1
}

function DownloadRelease {
    Param(
        [string] $token,
        [string] $projects = "*",
        [string] $api_url = $ENV:GITHUB_API_URL,
        [string] $repository = $ENV:GITHUB_REPOSITORY,
        [string] $path,
        [string] $mask = "Apps",
        [switch] $unpack,
        $release
    )
    if ($projects -eq '') { $projects = '*' }
    Write-Host "Downloading release $($release.name) (build $($release.buildId)), projects $projects, type $mask"
    $artifacts = @(Get-AdoBuildArtifacts -BuildId $release.buildId -Project $release.project)
    foreach ($project in $projects.Split(',')) {
        $regex = Get-AlGoAdoArtifactRegex -project $project -mask $mask
        foreach ($artifact in @($artifacts | Where-Object { $_.name -match $regex })) {
            $zip = Save-AdoBuildArtifact -Artifact $artifact -Path $path -FileName "$($artifact.name).zip"
            if ($unpack) {
                $folder = Join-Path $path $artifact.name
                if (Test-Path $folder) { Remove-Item $folder -Recurse -Force }
                Expand-Archive -Path $zip -DestinationPath $folder
                Remove-Item $zip -Force
                $folder
            }
            else {
                $zip
            }
        }
    }
}

function FindLatestSuccessfulCICDRun {
    Param(
        [string] $repository,
        [string] $branch,
        [string] $token,
        [int] $retention = 0
    )
    $target = Get-AlGoAdoRepoTarget $repository
    Write-Host "Finding latest successful CI/CD build (tag AL-Go-CICD) on branch $branch"
    $build = Get-AdoBuilds -Project $target.Project -RepositoryId $target.RepositoryId -Branch $branch -Tags @('AL-Go-CICD') -Top 1 -MaxAgeDays $retention -ExcludePullRequests | Select-Object -First 1
    if ($build) {
        Write-Host "Last known good build: $($build.id) ($($build.sourceVersion))"
        return $build.id, $build.sourceVersion
    }
    Write-Host "No successful CI/CD build found"
    return 0, ''
}

function GetArtifactsFromWorkflowRun {
    Param(
        $workflowRun,
        [string] $token,
        [string] $api_url,
        [string] $repository,
        [string] $mask,
        [string] $projects,
        [ref] $expiredArtifacts   # GitHub expires artifacts separately; in Azure DevOps they live as long as the run
    )
    $target = Get-AlGoAdoRepoTarget $repository
    $artifacts = @(Get-AdoBuildArtifacts -BuildId $workflowRun -Project $target.Project)
    $found = @()
    foreach ($project in $projects.Split(',')) {
        $regex = Get-AlGoAdoArtifactRegex -project $project -mask $mask
        $match = $artifacts | Where-Object { $_.name -match $regex } | Select-Object -First 1
        if ($match) {
            $match | Add-Member -NotePropertyName 'buildId' -NotePropertyValue $workflowRun -Force
            $found += $match
        }
    }
    if ($found.Count -eq 1) { return $found[0] }
    return $found
}

function GetArtifacts {
    Param(
        [string] $token,
        [string] $api_url,
        [string] $repository,
        [string] $mask,
        [string] $projects,
        [string] $version,
        [string] $branch = 'main',
        [string] $baselineWorkflowID
    )
    if (-not $projects) { $projects = '*' }
    $target = Get-AlGoAdoRepoTarget $repository
    if ($baselineWorkflowID -and $baselineWorkflowID -ne '0') {
        $builds = @([PSCustomObject]@{ id = $baselineWorkflowID })
    }
    else {
        $builds = Get-AdoBuilds -Project $target.Project -RepositoryId $target.RepositoryId -Branch $branch -Tags @('AL-Go-CICD') -Top 30 -IncludePartiallySucceeded -ExcludePullRequests
    }
    $projectList = @($projects.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $result = [ordered]@{}
    foreach ($build in $builds) {
        $artifacts = @(Get-AdoBuildArtifacts -BuildId $build.id -Project $target.Project)
        foreach ($project in $projectList) {
            $regex = Get-AlGoAdoArtifactRegex -project $project -mask $mask -branch $branch -version $version
            foreach ($artifact in $artifacts) {
                if ($artifact.name -notmatch $regex) { continue }
                $key = $Matches['project']
                if (-not $result.Contains($key)) {
                    $artifact | Add-Member -NotePropertyName 'buildId' -NotePropertyValue $build.id -Force
                    $result[$key] = $artifact
                }
            }
        }
        if ($result.Count -gt 0) {
            $explicitProjects = @($projectList | Where-Object { $_ -notlike '*[*?]*' } | ForEach-Object { $_.Replace('\', '_').Replace('/', '_') })
            $missing = @($explicitProjects | Where-Object { -not $result.Contains($_) })
            if ($explicitProjects.Count -lt $projectList.Count -or $missing.Count -eq 0) { break }
        }
    }
    Write-Host "Found $($result.Count) $mask artifact(s) for projects '$projects', version '$version', branch '$branch'"
    @($result.Values)
}

function DownloadArtifact {
    Param(
        [string] $token,
        [string] $path,
        $artifact,
        [switch] $unpack
    )
    $zip = Save-AdoBuildArtifact -Artifact $artifact -Path $path -FileName "$($artifact.name).zip"
    if ($unpack) {
        $folder = Join-Path $path $artifact.name
        if (Test-Path $folder) { Remove-Item $folder -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $folder
        Remove-Item $zip -Force
        return $folder
    }
    return $zip
}

function GetDependencies {
    Param(
        $probingPathsJson,
        [string] $api_url = $ENV:GITHUB_API_URL,   # AL-Go <= v10 passes it; not used in Azure DevOps
        [string] $saveToPath = (Join-Path $ENV:GITHUB_WORKSPACE ".dependencies"),
        [string[]] $masks = @('Apps', 'Dependencies', 'TestApps')
    )

    if (!(Test-Path $saveToPath)) {
        New-Item $saveToPath -ItemType Directory | Out-Null
    }
    $currentBuildArtifacts = $null
    $downloadedList = @()
    foreach ($mask in $masks) {
        foreach ($dependency in $probingPathsJson) {
            $projects = $dependency.projects
            $buildMode = $dependency.buildMode
            $currentMask = $mask
            $altMask = $(if ($mask -eq 'TestApps') { 'Apps' } else { 'TestApps' })
            if ($buildMode -and $buildMode -ne 'Default') {
                $currentMask = "$buildMode$currentMask"
                $altMask = "$buildMode$altMask"
            }
            Write-Host "Locating $currentMask artifacts for projects: $projects"

            if ($dependency.release_status -eq 'thisBuild') {
                $missingProjects = @()
                foreach ($project in $projects.Split(',')) {
                    $branchName = $dependency.branch.Replace('\', '_').Replace('/', '_')
                    $project = $project.Replace('\', '_').Replace('/', '_')
                    $downloadName = Join-Path $saveToPath "$project-$branchName-$currentMask-*"
                    if (-not (Test-Path $downloadName -PathType Container) -and $env:BUILD_BUILDID) {
                        # Not pre-downloaded - fetch from the artifacts already published by this run
                        if ($null -eq $currentBuildArtifacts) { $currentBuildArtifacts = @(Get-AdoBuildArtifacts -BuildId $env:BUILD_BUILDID) }
                        foreach ($pattern in @("$project-$branchName-$currentMask-*", "$project-$branchName-$altMask-*")) {
                            $currentBuildArtifacts | Where-Object { $_.name -like $pattern } | ForEach-Object {
                                $folder = Join-Path $saveToPath $_.name
                                if (-not (Test-Path $folder)) {
                                    $zip = Save-AdoBuildArtifact -Artifact $_ -Path $saveToPath
                                    Expand-Archive -Path $zip -DestinationPath $folder
                                    Remove-Item $zip -Force
                                }
                            }
                        }
                    }
                    if (Test-Path $downloadName -PathType Container) {
                        $folder = Get-Item $downloadName
                        Get-ChildItem -LiteralPath $folder | ForEach-Object {
                            if ($currentMask -like '*TestApps') { $downloadedList += @("($($_.FullName))") } else { $downloadedList += @($_.FullName) }
                            Write-Host "$($_.FullName) found from previous job"
                        }
                    }
                    elseif ($currentMask -like '*Apps') {
                        $altDownloadName = Join-Path $saveToPath "$project-$branchName-$altMask-*"
                        if (!(Test-Path $altDownloadName -PathType Container)) {
                            Write-Host "$project not built, downloading from artifacts"
                            $missingProjects += @($project)
                        }
                        else {
                            Write-Host "$project built, but $currentMask not found"
                        }
                    }
                }
                if ($missingProjects -and $dependency.baselineWorkflowID -and $dependency.baselineWorkflowID -ne '0') {
                    $dependency.release_status = 'latestBuild'
                    $dependency.branch = $dependency.baseBranch
                    $dependency.projects = $missingProjects -join ","
                }
            }
            $projects = $dependency.projects

            if ($dependency.release_status -eq 'thisBuild' -or $dependency.release_status -eq 'include') {
                continue
            }
            if ($null -eq (Resolve-AdoRepositoryUrl $dependency.repo)) {
                # Dependency hosted on GitHub - use the original AL-Go implementation
                Write-Host "Dependency repository $($dependency.repo) is not an Azure DevOps repository, using AL-Go for GitHub logic"
                $githubHelper = Get-Module -Name 'Github-Helper' | Select-Object -First 1
                $downloadedList += @(& $githubHelper { param($d, $s, $m) GetDependencies -probingPathsJson @($d) -saveToPath $s -masks @($m) } $dependency $saveToPath $mask)
                continue
            }
            if ($dependency.release_status -eq 'latestBuild') {
                $artifacts = GetArtifacts -repository $dependency.repo -mask $currentMask -projects $projects -version $dependency.version -branch $dependency.branch -baselineWorkflowID $dependency.baselineWorkflowID
                if ($artifacts) {
                    foreach ($artifact in $artifacts) {
                        $download = DownloadArtifact -path $saveToPath -artifact $artifact
                        if ($currentMask -like '*TestApps') { $downloadedList += @("($download)") } else { $downloadedList += @($download) }
                    }
                }
                else {
                    Write-Host -ForegroundColor Red "Could not find any $currentMask artifacts for projects $projects, version $($dependency.version)"
                }
            }
            else {
                $releases = @(GetReleases -repository $dependency.repo)
                if ($dependency.version -ne 'latest') {
                    $releases = @($releases | Where-Object { $_.tag_name -eq $dependency.version })
                }
                switch ($dependency.release_status) {
                    'release' { $release = $releases | Where-Object { -not ($_.prerelease -or $_.draft) } | Select-Object -First 1 }
                    'prerelease' { $release = $releases | Where-Object { $_.prerelease } | Select-Object -First 1 }
                    'draft' { throw 'Draft releases are not supported in Azure DevOps' }
                    default { throw "Invalid release status '$($dependency.release_status)' is encountered." }
                }
                if (-not $release) {
                    throw "Could not find a release that matches the criteria."
                }
                foreach ($download in @(DownloadRelease -projects $projects -repository $dependency.repo -path $saveToPath -release $release -mask $currentMask)) {
                    if ($currentMask -like '*TestApps') { $downloadedList += @("($download)") } else { $downloadedList += @($download) }
                }
            }
        }
    }
    return $downloadedList
}

function GetGitHubEnvironments {
    # Deployment environments are declared in the pipeline (template parameter 'environments') and passed as ALGO_ENVIRONMENTS
    if (-not (Get-Command Get-AlGoAdoEnvironmentName -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot 'AlGoAdo.Shim.psm1') -DisableNameChecking -Global
    }
    @(Get-AlGoAdoEnvironmentName | ForEach-Object { @{ name = $_; protection_rules = @() } })
}

function Get-BranchesFromPolicy($ghEnvironment) {
    # Branch policies are enforced by Azure DevOps environment checks (and AL-Go's DeployTo<env>.Branches setting)
    return $null
}

function IsGitHubPagesAvailable() {
    return $false
}

function TestRunnerPrerequisites {
    try { invoke-git version } catch { OutputWarning -Message "Git is not installed" }
}

function CloneIntoNewFolder {
    Param(
        [string] $actor,
        [string] $token,
        [string] $updateBranch = $ENV:GITHUB_REF_NAME,
        [string] $newBranchPrefix = '',
        [bool] $directCommit
    )

    $baseFolder = NewTemporaryFolder
    Set-Location $baseFolder
    $repoUrl = "$env:BUILD_REPOSITORY_URI"
    if (-not $repoUrl) { throw 'BUILD_REPOSITORY_URI is not set' }

    # Authenticate git with System.AccessToken through environment config (never on the command line or on disk)
    $env:GIT_CONFIG_COUNT = '1'
    $env:GIT_CONFIG_KEY_0 = 'http.extraheader'
    $env:GIT_CONFIG_VALUE_0 = "AUTHORIZATION: bearer $env:SYSTEM_ACCESSTOKEN"

    invoke-git clone --quiet $repoUrl repo
    Set-Location (Join-Path $baseFolder 'repo')
    $email = $(if ($env:BUILD_REQUESTEDFOREMAIL) { $env:BUILD_REQUESTEDFOREMAIL } else { "$actor@azure-pipelines" })
    $name = $(if ($env:BUILD_REQUESTEDFOR) { $env:BUILD_REQUESTEDFOR } else { $actor })
    invoke-git config user.email $email
    invoke-git config user.name $name
    invoke-git config core.autocrlf false
    invoke-git checkout $updateBranch

    $branch = "$newBranchPrefix/$updateBranch/$((Get-Date).ToUniversalTime().ToString('yyMMddHHmmss'))"
    if (!$directCommit) {
        invoke-git checkout -b $branch
    }
    $repoUrl
    $branch
}

function CommitFromNewFolder {
    Param(
        [string] $serverUrl,
        [string] $commitMessage,
        [string] $body = $commitMessage,
        [string] $branch,
        [string] $headBranch = $ENV:GITHUB_REF_NAME
    )

    invoke-git add --all
    $status = invoke-git -returnValue status --porcelain=v1
    if (-not $status) {
        Write-Host "No changes detected in files"
        return $false
    }
    $title = $commitMessage
    $settings = ReadSettings
    if ($settings.commitOptions.messageSuffix) {
        $commitMessage = "$commitMessage / $($settings.commitOptions.messageSuffix)"
        $body = "$body`n$($settings.commitOptions.messageSuffix)"
    }
    if ($commitMessage.Length -gt 250) { $commitMessage = "$($commitMessage.Substring(0,250))...)" }
    if ($title.Length -gt 250) { $title = "$($title.Substring(0,250))...)" }

    invoke-git commit --allow-empty -m "$commitMessage"
    $activeBranch = "$(invoke-git -returnValue -silent rev-parse --abbrev-ref HEAD)".Trim()
    if ($activeBranch -ne $branch) {
        try {
            invoke-git push origin "HEAD:refs/heads/$headBranch"
            return $true
        }
        catch {
            OutputWarning("Direct commit wasn't allowed, trying to create a Pull Request instead")
            invoke-git reset --soft HEAD~
            invoke-git checkout -b $branch
            invoke-git commit --allow-empty -m "$commitMessage"
        }
    }
    try {
        invoke-git push -u origin $branch
    }
    catch {
        throw "git push of branch $branch failed. Make sure the build service identity has Contribute and Create branch permissions on the repository. $($_.Exception.Message)"
    }
    try {
        $mergeStrategy = 'squash'
        if ("$($settings.commitOptions.pullRequestMergeMethod)".ToLowerInvariant() -eq 'merge') { $mergeStrategy = 'noFastForward' }
        $pr = New-AdoPullRequest -RepositoryId $env:BUILD_REPOSITORY_ID -SourceBranch $branch -TargetBranch $headBranch -Title $title -Description $body `
            -Labels @($settings.commitOptions.pullRequestLabels) -AutoComplete:([bool]$settings.commitOptions.pullRequestAutoMerge) -MergeStrategy $mergeStrategy
        Write-Host "Pull request created: $($env:BUILD_REPOSITORY_URI)/pullrequest/$($pr.pullRequestId)"
    }
    catch {
        OutputError("Could not create the pull request ($($_.Exception.Message)). Create it manually from branch $branch. Make sure the build service identity has 'Contribute to pull requests' permission.")
    }
    return $true
}

# Make the overrides visible to modules that resolve commands through the global scope
foreach ($name in $script:AlGoAdoOverrideNames) {
    $definition = Get-Item -Path "function:$name" -ErrorAction SilentlyContinue
    if ($definition) { Set-Item -Path "function:global:$name" -Value $definition.ScriptBlock }
}
