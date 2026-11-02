<#
    AL-Go for Azure DevOps - minimal Azure DevOps REST client.

    Authenticates with System.AccessToken (map it into the step env as SYSTEM_ACCESSTOKEN).
#>

Set-StrictMode -Version 2.0

$script:apiVersion = '7.1'

function Get-AdoContext {
    $collectionUri = "$env:SYSTEM_COLLECTIONURI"
    if (-not $collectionUri) { throw 'SYSTEM_COLLECTIONURI is not set - AL-Go4ADO REST calls must run in an Azure DevOps pipeline' }
    if (-not $env:SYSTEM_ACCESSTOKEN) { throw 'SYSTEM_ACCESSTOKEN is not available. Map it into the step: env: { SYSTEM_ACCESSTOKEN: $(System.AccessToken) }' }
    [PSCustomObject]@{
        CollectionUri = $collectionUri.TrimEnd('/') + '/'
        Project       = "$env:SYSTEM_TEAMPROJECT"
        ProjectId     = "$env:SYSTEM_TEAMPROJECTID"
        RepositoryId  = "$env:BUILD_REPOSITORY_ID"
        DefinitionId  = "$env:SYSTEM_DEFINITIONID"
        BuildId       = "$env:BUILD_BUILDID"
        Token         = "$env:SYSTEM_ACCESSTOKEN"
    }
}

function Get-AdoHeaders([string] $accept = 'application/json') {
    $ctx = Get-AdoContext
    @{
        'Authorization' = "Bearer $($ctx.Token)"
        'Accept'        = $accept
    }
}

function Invoke-AdoRest {
    Param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [string] $Method = 'GET',
        $Body = $null,
        [string] $Project = '',
        [string] $ContentType = 'application/json',
        [switch] $Organization
    )

    $ctx = Get-AdoContext
    if ($Path -match '^https?://') {
        $uri = $Path
    }
    else {
        if (-not $Project) { $Project = $ctx.Project }
        $prefix = if ($Organization) { $ctx.CollectionUri } else { "$($ctx.CollectionUri)$([Uri]::EscapeDataString($Project))/" }
        $uri = "$prefix$($Path.TrimStart('/'))"
    }
    if ($uri -notmatch 'api-version=') {
        $uri += $(if ($uri.Contains('?')) { '&' } else { '?' }) + "api-version=$script:apiVersion"
    }
    $params = @{
        Uri             = $uri
        Method          = $Method
        Headers         = Get-AdoHeaders
        UseBasicParsing = $true
    }
    if ($null -ne $Body) {
        $params.Body = $(if ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 20 -Compress })
        $params.ContentType = $ContentType
    }
    $attempt = 0
    while ($true) {
        try {
            return Invoke-RestMethod @params
        }
        catch {
            $attempt++
            $status = 0
            try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = 0 }
            if ($attempt -ge 3 -or ($status -ge 400 -and $status -lt 500 -and $status -ne 429)) {
                throw "Azure DevOps REST call $Method $uri failed: $($_.Exception.Message)"
            }
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
}

<#
    .SYNOPSIS
    Splits an Azure DevOps git repository URL into organization URL, project and repository.
    Supports https://dev.azure.com/org/project/_git/repo, https://org.visualstudio.com/project/_git/repo,
    on-premises collection URLs and the AL-Go4ADO shim form <collectionUri>/<project>/<repo>.
    Returns $null for non-ADO (e.g. GitHub) URLs.
#>
function Resolve-AdoRepositoryUrl([string] $url) {
    if (-not $url) { return $null }
    $url = $url.TrimEnd('/')
    if ($url -match '\.git$') { $url = $url.Substring(0, $url.Length - 4) }
    $uri = [uri]$url
    if ($uri.Host -in @('github.com') -or $uri.Host -like '*.ghe.com') { return $null }

    $collection = "$env:SYSTEM_COLLECTIONURI".TrimEnd('/')
    $rest = $null
    if ($collection -and $url.StartsWith($collection, [StringComparison]::OrdinalIgnoreCase)) {
        $orgUrl = $collection
        $rest = $url.Substring($collection.Length).Trim('/')
    }
    elseif ($uri.Host -eq 'dev.azure.com') {
        $segments = $uri.AbsolutePath.Trim('/').Split('/')
        $orgUrl = "https://dev.azure.com/$($segments[0])"
        $rest = ($segments | Select-Object -Skip 1) -join '/'
    }
    elseif ($uri.Host -like '*.visualstudio.com') {
        $orgUrl = "https://$($uri.Host)"
        $rest = $uri.AbsolutePath.Trim('/')
    }
    else {
        return $null
    }
    $parts = @([Uri]::UnescapeDataString($rest).Split('/') | Where-Object { $_ -and $_ -ne '_git' })
    if ($parts.Count -lt 1) { return $null }
    $project = $parts[0]
    $repo = $parts[-1]
    [PSCustomObject]@{ OrganizationUrl = "$orgUrl/"; Project = $project; Repository = $repo }
}

function Get-AdoRepository([string] $Project, [string] $Repository) {
    Invoke-AdoRest -Project $Project -Path "_apis/git/repositories/$([Uri]::EscapeDataString($Repository))"
}

<#
    .SYNOPSIS
    Lists completed, successful (or partially successful) builds.
#>
function Get-AdoBuilds {
    Param(
        [string] $Project = '',
        [string] $DefinitionId = '',
        [string] $RepositoryId = '',
        [string] $Branch = '',
        [string[]] $Tags = @(),
        [int] $Top = 20,
        [switch] $IncludePartiallySucceeded,
        [switch] $ExcludePullRequests,
        [int] $MaxAgeDays = 0
    )
    $query = @('statusFilter=completed', 'queryOrder=finishTimeDescending', "`$top=$Top")
    $query += $(if ($IncludePartiallySucceeded) { 'resultFilter=succeeded,partiallySucceeded' } else { 'resultFilter=succeeded' })
    if ($DefinitionId) { $query += "definitions=$DefinitionId" }
    if ($RepositoryId) { $query += "repositoryId=$RepositoryId"; $query += 'repositoryType=TfsGit' }
    if ($Branch) {
        $ref = $(if ($Branch -like 'refs/*') { $Branch } else { "refs/heads/$Branch" })
        $query += "branchName=$([Uri]::EscapeDataString($ref))"
    }
    if ($Tags) { $query += "tagFilters=$([Uri]::EscapeDataString($Tags -join ','))" }
    if ($ExcludePullRequests) { $query += 'reasonFilter=individualCI,batchedCI,manual,schedule,resourceTrigger,userCreated' }
    if ($MaxAgeDays -gt 0) { $query += "minTime=$([DateTime]::UtcNow.AddDays(-$MaxAgeDays).ToString('o'))" }
    $result = Invoke-AdoRest -Project $Project -Path "_apis/build/builds?$($query -join '&')"
    return @($result.value)
}

function Get-AdoBuildArtifacts([string] $BuildId, [string] $Project = '') {
    $result = Invoke-AdoRest -Project $Project -Path "_apis/build/builds/$BuildId/artifacts"
    return @($result.value)
}

<#
    .SYNOPSIS
    Downloads a build artifact as a zip whose root contains the artifact files (GitHub layout),
    returns the path of the zip file.
#>
function Save-AdoBuildArtifact {
    Param(
        [Parameter(Mandatory = $true)]
        $Artifact,
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [string] $FileName = ''
    )
    if (-not $FileName) { $FileName = "$($Artifact.name).zip" }
    New-Item -Path $Path -ItemType Directory -Force | Out-Null
    $downloadUrl = $Artifact.resource.downloadUrl
    if ($downloadUrl -notmatch 'format=zip') {
        $downloadUrl += $(if ($downloadUrl.Contains('?')) { '&' } else { '?' }) + '$format=zip'
    }
    $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -Path $tmpRoot -ItemType Directory | Out-Null
    try {
        $rawZip = Join-Path $tmpRoot 'raw.zip'
        Write-Host "Downloading artifact $($Artifact.name)"
        Invoke-WebRequest -Uri $downloadUrl -Headers (Get-AdoHeaders -accept 'application/zip') -OutFile $rawZip -UseBasicParsing
        $extract = Join-Path $tmpRoot 'x'
        Expand-Archive -Path $rawZip -DestinationPath $extract -Force
        # ADO zips contain a top-level folder named after the artifact - strip it
        $content = $extract
        $inner = Join-Path $extract $Artifact.name
        if (Test-Path -LiteralPath $inner -PathType Container) { $content = $inner }
        $zipFile = Join-Path $Path $FileName
        if (Test-Path -LiteralPath $zipFile) { Remove-Item -LiteralPath $zipFile -Force }
        Compress-Archive -Path (Join-Path $content '*') -DestinationPath $zipFile
        return $zipFile
    }
    finally {
        Remove-Item -Path $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Add-AdoBuildTag([string] $BuildId, [string] $Tag, [string] $Project = '') {
    Invoke-AdoRest -Project $Project -Method PUT -Path "_apis/build/builds/$BuildId/tags/$([Uri]::EscapeDataString($Tag))" | Out-Null
}

function Get-AdoBuild([string] $BuildId, [string] $Project = '') {
    Invoke-AdoRest -Project $Project -Path "_apis/build/builds/$BuildId"
}

function Add-AdoRetentionLease([string] $BuildId, [string] $DefinitionId, [string] $OwnerId, [int] $DaysValid = 36500, [string] $Project = '') {
    $body = @(@{ daysValid = $DaysValid; definitionId = [int]$DefinitionId; ownerId = $OwnerId; protectPipeline = $false; runId = [int]$BuildId })
    Invoke-AdoRest -Project $Project -Method POST -Path '_apis/build/retention/leases' -Body (ConvertTo-Json -InputObject $body -Depth 5 -Compress) | Out-Null
}

function New-AdoAnnotatedTag([string] $RepositoryId, [string] $Name, [string] $CommitId, [string] $Message, [string] $Project = '') {
    $body = @{ name = $Name; taggedObject = @{ objectId = $CommitId }; message = $Message }
    Invoke-AdoRest -Project $Project -Method POST -Path "_apis/git/repositories/$RepositoryId/annotatedtags" -Body $body
}

function New-AdoBranch([string] $RepositoryId, [string] $Name, [string] $CommitId, [string] $Project = '') {
    $ref = $(if ($Name -like 'refs/*') { $Name } else { "refs/heads/$Name" })
    $body = @(@{ name = $ref; oldObjectId = '0000000000000000000000000000000000000000'; newObjectId = $CommitId })
    Invoke-AdoRest -Project $Project -Method POST -Path "_apis/git/repositories/$RepositoryId/refs" -Body (ConvertTo-Json -InputObject $body -Compress)
}

function Get-AdoAuthenticatedIdentityId {
    (Invoke-AdoRest -Organization -Path '_apis/connectionData' -Method GET).authenticatedUser.id
}

function New-AdoPullRequest {
    Param(
        [string] $RepositoryId,
        [string] $SourceBranch,
        [string] $TargetBranch,
        [string] $Title,
        [string] $Description,
        [string[]] $Labels = @(),
        [switch] $AutoComplete,
        [ValidateSet('squash', 'noFastForward', 'rebase', 'rebaseMerge')]
        [string] $MergeStrategy = 'squash',
        [string] $Project = ''
    )
    $body = [ordered]@{
        sourceRefName = $(if ($SourceBranch -like 'refs/*') { $SourceBranch } else { "refs/heads/$SourceBranch" })
        targetRefName = $(if ($TargetBranch -like 'refs/*') { $TargetBranch } else { "refs/heads/$TargetBranch" })
        title         = $Title
        description   = $(if ($Description.Length -gt 4000) { $Description.Substring(0, 3990) + '...' } else { $Description })
    }
    if ($Labels) { $body.labels = @($Labels | ForEach-Object { @{ name = $_ } }) }
    $pr = Invoke-AdoRest -Project $Project -Method POST -Path "_apis/git/repositories/$RepositoryId/pullrequests" -Body $body
    if ($AutoComplete) {
        $patch = @{
            autoCompleteSetBy = @{ id = (Get-AdoAuthenticatedIdentityId) }
            completionOptions = @{ mergeStrategy = $MergeStrategy; deleteSourceBranch = $true }
        }
        Invoke-AdoRest -Project $Project -Method PATCH -Path "_apis/git/repositories/$RepositoryId/pullrequests/$($pr.pullRequestId)" -Body $patch | Out-Null
    }
    return $pr
}

Export-ModuleMember -Function Get-AdoContext, Get-AdoHeaders, Invoke-AdoRest, Resolve-AdoRepositoryUrl, Get-AdoRepository, Get-AdoBuilds, `
    Get-AdoBuildArtifacts, Save-AdoBuildArtifact, Add-AdoBuildTag, Get-AdoBuild, Add-AdoRetentionLease, New-AdoAnnotatedTag, New-AdoBranch, `
    Get-AdoAuthenticatedIdentityId, New-AdoPullRequest
