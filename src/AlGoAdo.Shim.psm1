<#
    AL-Go for Azure DevOps - GitHub Actions compatibility shim.

    Pure functions that translate between the Azure DevOps agent world and the
    GitHub Actions world that AL-Go expects. Nothing in here talks to the network.
#>

Set-StrictMode -Version 2.0

function Get-EnvValue([hashtable] $AdoEnv, [string] $Name, [string] $Default = '') {
    # Environment lookups are case-insensitive on Windows, but we want the same behavior everywhere
    foreach ($key in $AdoEnv.Keys) {
        if ($key -ieq $Name) {
            $value = "$($AdoEnv[$key])"
            # Unresolved ADO macros are passed through literally - treat them as unset
            if ($value -match '^\$\([^)]+\)$') { return $Default }
            if ($value) { return $value }
        }
    }
    return $Default
}

<#
    .SYNOPSIS
    Sets (or with an empty value: removes) a process environment variable.
    Unlike Set-Item/Remove-Item on env:, this also works for variables the agent created with an
    empty value, which Windows PowerShell 5.1 lists but reports as not found.
#>
function Set-ProcessEnvironmentVariable([string] $Name, [AllowEmptyString()][AllowNull()][string] $Value) {
    if ([string]::IsNullOrEmpty($Value)) {
        # A real null deletes the variable. PowerShell would pass $null as '' and newer .NET versions
        # keep a variable that is set to '' (Windows PowerShell deletes it).
        [Environment]::SetEnvironmentVariable($Name, [System.Management.Automation.Language.NullString]::Value, [EnvironmentVariableTarget]::Process)
    }
    else {
        [Environment]::SetEnvironmentVariable($Name, $Value, [EnvironmentVariableTarget]::Process)
    }
}

<#
    .SYNOPSIS
    Returns a full path with the platform's directory separator and without a trailing separator.
    Azure DevOps paths like '$(Pipeline.Workspace)/self' mix '\' and '/' on Windows, which breaks
    tools that compare paths as strings (BcContainerHelper's Run-AlPipeline).
#>
function ConvertTo-NormalizedPath([string] $Path) {
    if (-not $Path) { return $Path }
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) }
    return $full
}

<#
    .SYNOPSIS
    Returns true for variable names that must not be set as Azure DevOps variables because the
    pipeline already defines them read-only (the build matrix variables), plus ALGO_RESERVED_VARIABLES.
    Such values stay in the AL-Go job state, so later AL-Go steps still get them.
#>
function Test-AdoReservedVariableName([string] $Name) {
    $reserved = @('project', 'projectName', 'buildMode') + @("$env:ALGO_RESERVED_VARIABLES".Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return [bool]($reserved | Where-Object { $_ -ieq $Name })
}

function Remove-RefPrefix([string] $ref) {
    if ($ref -like 'refs/heads/*') { return $ref.Substring(11) }
    if ($ref -like 'refs/tags/*') { return $ref.Substring(10) }
    return $ref
}

<#
    .SYNOPSIS
    Maps Azure DevOps Build.Reason to a GitHub event name.
#>
function ConvertTo-GitHubEventName([string] $buildReason, [string] $override) {
    if ($override) { return $override }
    switch ($buildReason) {
        'PullRequest'       { return 'pull_request' }
        'IndividualCI'      { return 'push' }
        'BatchedCI'         { return 'push' }
        'Schedule'          { return 'schedule' }
        'ResourceTrigger'   { return 'workflow_run' }
        default             { return 'workflow_dispatch' }  # Manual, Checkin, ValidateShelveset, ...
    }
}

<#
    .SYNOPSIS
    Computes the GITHUB_* (and related) environment variables AL-Go expects, from the ADO agent environment.
    .PARAMETER AdoEnv
    Hashtable of the current environment variables (Get-ChildItem env:).
    .PARAMETER Workspace
    Folder containing the AL-Go repository checkout.
    .PARAMETER ActionsPath
    Folder containing the AL-Go actions (root of microsoft/AL-Go-Actions).
#>
function Get-AlGoGitHubEnvironment {
    Param(
        [Parameter(Mandatory = $true)]
        [hashtable] $AdoEnv,
        [Parameter(Mandatory = $true)]
        [string] $Workspace,
        [string] $ActionsPath = '',
        [string] $ActionName = ''
    )

    $collectionUri = (Get-EnvValue $AdoEnv 'SYSTEM_COLLECTIONURI' 'https://dev.azure.com/local/').TrimEnd('/')
    $teamProject = Get-EnvValue $AdoEnv 'SYSTEM_TEAMPROJECT' 'local'
    $repoName = Get-EnvValue $AdoEnv 'BUILD_REPOSITORY_NAME' (Split-Path $Workspace -Leaf)
    # ADO repository names may be "project/repo" for some repository types - keep the last segment
    $repoName = $repoName.Split('/')[-1]

    $buildReason = Get-EnvValue $AdoEnv 'BUILD_REASON' 'Manual'
    $eventName = ConvertTo-GitHubEventName $buildReason (Get-EnvValue $AdoEnv 'ALGO_EVENT_NAME')

    $refName = Remove-RefPrefix (Get-EnvValue $AdoEnv 'BUILD_SOURCEBRANCH' 'refs/heads/main')
    $headRef = ''
    $baseRef = ''
    if ($eventName -eq 'pull_request') {
        $prNumber = Get-EnvValue $AdoEnv 'SYSTEM_PULLREQUEST_PULLREQUESTNUMBER' (Get-EnvValue $AdoEnv 'SYSTEM_PULLREQUEST_PULLREQUESTID' '0')
        $headRef = Remove-RefPrefix (Get-EnvValue $AdoEnv 'SYSTEM_PULLREQUEST_SOURCEBRANCH')
        $baseRef = Remove-RefPrefix (Get-EnvValue $AdoEnv 'SYSTEM_PULLREQUEST_TARGETBRANCH')
        $refName = "$prNumber/merge"
    }

    $runNumber = Get-EnvValue $AdoEnv 'AL_GO_RUN_NUMBER' (Get-EnvValue $AdoEnv 'BUILD_BUILDID' '1')
    $runAttempt = Get-EnvValue $AdoEnv 'SYSTEM_JOBATTEMPT' '1'
    $temp = Get-EnvValue $AdoEnv 'AGENT_TEMPDIRECTORY' ([System.IO.Path]::GetTempPath())

    $result = [ordered]@{
        'GITHUB_ACTIONS'           = 'true'
        'ALGO_ADO'                 = 'true'
        'CI'                       = 'true'
        'GITHUB_WORKSPACE'         = $Workspace
        'GITHUB_REPOSITORY'        = "$teamProject/$repoName"
        'GITHUB_REPOSITORY_OWNER'  = $teamProject
        'GITHUB_REPOSITORY_ID'     = Get-EnvValue $AdoEnv 'BUILD_REPOSITORY_ID'
        'GITHUB_SERVER_URL'        = $collectionUri
        'GITHUB_API_URL'           = "$collectionUri/_apis"
        'GITHUB_REF'               = Get-EnvValue $AdoEnv 'BUILD_SOURCEBRANCH' "refs/heads/$refName"
        'GITHUB_REF_NAME'          = $refName
        'GITHUB_HEAD_REF'          = $headRef
        'GITHUB_BASE_REF'          = $baseRef
        'GITHUB_SHA'               = Get-EnvValue $AdoEnv 'BUILD_SOURCEVERSION'
        'GITHUB_EVENT_NAME'        = $eventName
        'GITHUB_WORKFLOW'          = Get-EnvValue $AdoEnv 'ALGO_WORKFLOW_NAME' (Get-EnvValue $AdoEnv 'BUILD_DEFINITIONNAME' 'CI/CD')
        'GITHUB_RUN_ID'            = Get-EnvValue $AdoEnv 'BUILD_BUILDID' '0'
        'GITHUB_RUN_NUMBER'        = $runNumber
        'GITHUB_RUN_ATTEMPT'       = $runAttempt
        'GITHUB_ACTOR'             = (Get-EnvValue $AdoEnv 'BUILD_REQUESTEDFOREMAIL' (Get-EnvValue $AdoEnv 'BUILD_REQUESTEDFOR' 'azure-pipelines')).Split('@')[0]
        'GITHUB_JOB'               = Get-EnvValue $AdoEnv 'SYSTEM_JOBNAME'
        'RUNNER_TEMP'              = $temp
        'RUNNER_OS'                = $(if (Get-Variable -Name IsLinux -ValueOnly -ErrorAction SilentlyContinue) { 'Linux' } elseif (Get-Variable -Name IsMacOS -ValueOnly -ErrorAction SilentlyContinue) { 'macOS' } else { 'Windows' })
        'RUNNER_ENVIRONMENT'       = $(if ((Get-EnvValue $AdoEnv 'AGENT_ISSELFHOSTED') -eq '0' -or (Get-EnvValue $AdoEnv 'AGENT_NAME') -like 'Azure Pipelines*' -or (Get-EnvValue $AdoEnv 'AGENT_NAME') -like 'Hosted Agent*') { 'github-hosted' } else { 'self-hosted' })
        'GITHUB_TOKEN'             = Get-EnvValue $AdoEnv 'SYSTEM_ACCESSTOKEN'
    }
    if ($ActionsPath -and $ActionName) {
        $result['GITHUB_ACTION_PATH'] = Join-Path $ActionsPath $ActionName
    }
    return $result
}

<#
    .SYNOPSIS
    Creates a GitHub-like event payload, used by AL-Go for PR head/base sha and telemetry.
#>
function New-AlGoEventPayload {
    Param(
        [Parameter(Mandatory = $true)]
        [hashtable] $AdoEnv,
        [System.Collections.IDictionary] $GitHubEnv,
        [string] $BaseSha = '',
        [string] $InputsJson = ''
    )

    $payload = [ordered]@{
        repository = [ordered]@{
            name      = $GitHubEnv.GITHUB_REPOSITORY.Split('/')[-1]
            full_name = $GitHubEnv.GITHUB_REPOSITORY
            fork      = $false
            html_url  = Get-EnvValue $AdoEnv 'BUILD_REPOSITORY_URI'
        }
    }
    if ($GitHubEnv.GITHUB_EVENT_NAME -eq 'pull_request') {
        $payload.pull_request = [ordered]@{
            number = [int](Get-EnvValue $AdoEnv 'SYSTEM_PULLREQUEST_PULLREQUESTNUMBER' (Get-EnvValue $AdoEnv 'SYSTEM_PULLREQUEST_PULLREQUESTID' '0'))
            head   = [ordered]@{ sha = Get-EnvValue $AdoEnv 'SYSTEM_PULLREQUEST_SOURCECOMMITID'; ref = $GitHubEnv.GITHUB_HEAD_REF }
            base   = [ordered]@{ sha = $BaseSha; ref = $GitHubEnv.GITHUB_BASE_REF }
        }
    }
    if ($InputsJson) {
        $payload.inputs = $InputsJson | ConvertFrom-Json
    }
    else {
        $payload.inputs = [ordered]@{}
    }
    return $payload
}

$script:workflowCommandRegex = [regex]'^(?<prefix>\r?)::(?<cmd>[A-Za-z-]+)(?<props>\s+[^:]*)?::(?<msg>.*)$'

function ConvertFrom-WorkflowProperties([string] $props) {
    $result = [ordered]@{}
    if (-not $props) { return $result }
    foreach ($pair in $props.Trim().Split(',')) {
        $kv = $pair.Split('=', 2)
        if ($kv.Count -eq 2) { $result[$kv[0].Trim().ToLowerInvariant()] = $kv[1].Trim() }
    }
    return $result
}

function Format-AdoLogIssue([string] $type, [System.Collections.IDictionary] $props, [string] $message) {
    $adoProps = @("type=$type")
    if ($props.Contains('file')) { $adoProps += "sourcepath=$($props.file)" }
    if ($props.Contains('line')) { $adoProps += "linenumber=$($props.line)" }
    if ($props.Contains('col')) { $adoProps += "columnnumber=$($props.col)" }
    if ($props.Contains('title') -and -not $message) { $message = $props.title }
    return "##vso[task.logissue $($adoProps -join ';')]$message"
}

<#
    .SYNOPSIS
    Translates a single output line written by AL-Go (GitHub workflow commands) to Azure DevOps logging commands.
    Returns the translated line, or $null if the line should be suppressed.
#>
function ConvertTo-AdoLogLine {
    Param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Line
    )

    if ($null -eq $Line) { return '' }
    $trimmed = $Line.TrimStart("`r")
    # Never let a line from the action start an ADO logging command unless we produced it.
    # AL-Go doesn't emit ##vso commands; only our own override module does, and those are allowed through.
    $m = $script:workflowCommandRegex.Match($trimmed)
    if (-not $m.Success) {
        return $Line
    }

    $cmd = $m.Groups['cmd'].Value.ToLowerInvariant()
    $props = ConvertFrom-WorkflowProperties $m.Groups['props'].Value
    $msg = $m.Groups['msg'].Value
    switch ($cmd) {
        'error'          { return Format-AdoLogIssue 'error' $props $msg }
        'warning'        { return Format-AdoLogIssue 'warning' $props $msg }
        'notice'         { return "##[section]$msg" }
        'debug'          { return "##[debug]$msg" }
        'group'          { return "##[group]$msg" }
        'endgroup'       { return "##[endgroup]" }
        'add-mask'       { if ($msg) { return "##vso[task.setsecret]$msg" } else { return $null } }
        'stop-commands'  { return $null }
        'set-output'     { return $Line }   # deprecated GitHub command - AL-Go doesn't use it
        default          { return $Line }
    }
}

<#
    .SYNOPSIS
    Parses a GitHub file command file (GITHUB_OUTPUT / GITHUB_ENV).
    Supports both "name=value" and the multi-line "name<<DELIMITER" format.
    Later assignments win.
#>
function Read-GitHubFileCommand {
    Param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $result = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    $i = 0
    while ($i -lt $lines.Count) {
        $line = $lines[$i].TrimStart([char]0xFEFF)
        $i++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $heredoc = [regex]::Match($line, '^(?<name>[^=<]+)<<(?<delim>.+)$')
        $eq = $line.IndexOf('=')
        if ($heredoc.Success -and ($eq -lt 0 -or $eq -gt $line.IndexOf('<<'))) {
            $name = $heredoc.Groups['name'].Value
            $delim = $heredoc.Groups['delim'].Value
            $valueLines = @()
            while ($i -lt $lines.Count -and $lines[$i] -ne $delim) {
                $valueLines += $lines[$i]
                $i++
            }
            $i++ # skip delimiter
            if ($result.Contains($name)) { $result.Remove($name) }
            $result[$name] = $valueLines -join "`n"
        }
        elseif ($eq -gt 0) {
            $name = $line.Substring(0, $eq)
            if ($result.Contains($name)) { $result.Remove($name) }
            $result[$name] = $line.Substring($eq + 1)
        }
    }
    return $result
}

<#
    .SYNOPSIS
    Returns true if a variable name or value looks like it carries a credential, so it is published as a secret.
#>
function Test-SecretVariableName([string] $Name) {
    return ($Name -match '(?i)(secret|password|token|credential|authcontext|^Secrets$)')
}

<#
    .SYNOPSIS
    Formats an ADO setvariable logging command. Values are escaped per ADO rules.
#>
function Format-AdoSetVariable {
    Param(
        [string] $Name,
        [AllowEmptyString()]
        [string] $Value,
        [switch] $IsOutput,
        [switch] $IsSecret
    )
    $escaped = "$Value".Replace('%', '%AZP25').Replace("`r", '%0D').Replace("`n", '%0A')
    $props = @("variable=$Name")
    if ($IsOutput) { $props += 'isOutput=true' }
    if ($IsSecret) { $props += 'issecret=true' }
    return "##vso[task.setvariable $($props -join ';')]$escaped"
}

<#
    .SYNOPSIS
    Converts AL-Go's BuildOrderJson to Azure DevOps matrix objects, one per build depth.
    .OUTPUTS
    Ordered hashtable: depth (1-based) -> matrix (ordered hashtable of job name -> variables)
#>
function ConvertTo-AdoBuildMatrix {
    Param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $BuildOrderJson,
        [int] $MaxBuildDepth = 0
    )

    $matrices = [ordered]@{}
    $buildOrder = @()
    if ($BuildOrderJson) {
        # Windows PowerShell 5.1 returns a JSON array as one pipeline object - assign first, then wrap
        $parsed = ConvertFrom-Json -InputObject $BuildOrderJson
        $buildOrder = @($parsed)
    }
    $depth = 0
    foreach ($level in $buildOrder) {
        $depth++
        $matrix = [ordered]@{}
        foreach ($dim in @($level.buildDimensions)) {
            if (-not $dim) { continue }
            $buildMode = 'Default'
            if (@($dim.PSObject.Properties | ForEach-Object { $_.Name }) -contains 'buildMode' -and $dim.buildMode) { $buildMode = $dim.buildMode }
            $projectName = $dim.project
            if (@($dim.PSObject.Properties | ForEach-Object { $_.Name }) -contains 'projectName' -and $dim.projectName) { $projectName = $dim.projectName }
            $key = ("$($dim.project)_$buildMode" -replace '[^A-Za-z0-9_]', '_').Trim('_')
            if (-not $key -or $key -match '^[0-9]') { $key = "p_$key" }
            $baseKey = $key; $n = 1
            while ($matrix.Contains($key)) { $n++; $key = "$($baseKey)_$n" }
            $matrix[$key] = [ordered]@{
                project     = $dim.project
                projectName = $projectName
                buildMode   = $buildMode
            }
        }
        $matrices["$depth"] = $matrix
    }
    if ($MaxBuildDepth -gt 0) {
        for ($d = $depth + 1; $d -le $MaxBuildDepth; $d++) { $matrices["$d"] = [ordered]@{} }
    }
    return $matrices
}

<#
    .SYNOPSIS
    Converts AL-Go's DeliveryTargetsJson (e.g. ["NuGet","Storage"]) to an Azure DevOps matrix with a
    deliveryTarget variable per job.
#>
function ConvertTo-AdoDeliveryMatrix {
    Param(
        [AllowEmptyString()]
        [string] $DeliveryTargetsJson
    )
    $matrix = [ordered]@{}
    if (-not $DeliveryTargetsJson) { return $matrix }
    # Windows PowerShell 5.1 returns a JSON array as one pipeline object - assign first, then wrap
    $parsed = ConvertFrom-Json -InputObject $DeliveryTargetsJson
    foreach ($target in @($parsed)) {
        if (-not $target) { continue }
        $key = ("$target" -replace '[^A-Za-z0-9_]', '_')
        if ($key -match '^[0-9]') { $key = "t_$key" }
        $matrix[$key] = [ordered]@{ deliveryTarget = "$target" }
    }
    return $matrix
}

<#
    .SYNOPSIS
    Reads the literal default values of the inputs declared in an action's action.yaml.
    Defaults that are GitHub expressions (${{ ... }}) are ignored.
#>
function Get-ActionInputDefault {
    Param(
        [Parameter(Mandatory = $true)]
        [string] $ActionFolder
    )
    $defaults = @{}
    $file = @('action.yaml', 'action.yml') | ForEach-Object { Join-Path $ActionFolder $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $file) { return $defaults }
    $inInputs = $false
    $current = $null
    foreach ($line in (Get-Content -Path $file -Encoding UTF8)) {
        if ($line -match '^inputs:\s*$') { $inInputs = $true; continue }
        if (-not $inInputs) { continue }
        if ($line -match '^\S') { break }
        if ($line -match '^  ([A-Za-z0-9_-]+):\s*$') { $current = $Matches[1]; continue }
        if ($current -and $line -match '^    default:\s*(.*)$') {
            $value = $Matches[1].Trim()
            if ($value -match '^''(.*)''$' -or $value -match '^"(.*)"$') { $value = $Matches[1] }
            if ($value -notlike '*${{*') { $defaults[$current] = $value }
        }
    }
    return $defaults
}

<#
    .SYNOPSIS
    Returns the AL-Go environment names declared in the pipeline (ALGO_ENVIRONMENTS).
    Accepts the JSON written by convertToJson() (array of { name: ... }, a single object or names) or a comma separated list.
#>
function Get-AlGoAdoEnvironmentName([string] $Value = $env:ALGO_ENVIRONMENTS) {
    $Value = "$Value".Trim()
    if (-not $Value) { return @() }
    if ($Value.StartsWith('[') -or $Value.StartsWith('{')) {
        # Windows PowerShell 5.1 doesn't enumerate a JSON array into the pipeline - iterate explicitly
        $parsed = ConvertFrom-Json -InputObject $Value
        $names = @()
        foreach ($item in @($parsed)) {
            if ($item -is [string]) { $names += $item }
            elseif (@($item.PSObject.Properties | ForEach-Object { $_.Name }) -contains 'name' -and $item.name) { $names += "$($item.name)" }
        }
        return $names
    }
    return @($Value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

Export-ModuleMember -Function Get-AlGoGitHubEnvironment, New-AlGoEventPayload, ConvertTo-AdoLogLine, Read-GitHubFileCommand, `
    Format-AdoSetVariable, Test-SecretVariableName, ConvertTo-AdoBuildMatrix, ConvertTo-GitHubEventName, Get-EnvValue, Get-ActionInputDefault, Get-AlGoAdoEnvironmentName, Set-ProcessEnvironmentVariable, ConvertTo-NormalizedPath, Test-AdoReservedVariableName, ConvertTo-AdoDeliveryMatrix
