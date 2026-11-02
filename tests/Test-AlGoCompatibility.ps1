<#
    .SYNOPSIS
    Static compatibility check of AL-Go4ADO against an AL-Go actions version (parses only, runs nothing).

    .DESCRIPTION
    Checks for one AL-Go-Actions source folder:
      1. every action/script used by the templates exists
      2. every input the templates pass is a parameter of the action script
         (otherwise Invoke-AlGoAdoAction.ps1 drops it with a warning)
      3. every call of an overridden function (src/AlGoAdo.Overrides.ps1) in the AL-Go sources only uses
         named parameters the override declares (otherwise the call fails at runtime)
      4. overridden functions that no longer exist in AL-Go (informational)
    Returns the findings as objects; exit code 1 when there are errors.

    .EXAMPLE
    git clone --depth 1 --branch v10.0 https://github.com/microsoft/AL-Go-Actions.git C:\temp\algo-v10.0
    ./tests/Test-AlGoCompatibility.ps1 -ActionsPath C:\temp\algo-v10.0
#>
Param(
    [Parameter(Mandatory = $true)]
    [string] $ActionsPath,
    [string] $TemplatesPath = (Join-Path $PSScriptRoot '../templates')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repoRoot = Split-Path $PSScriptRoot -Parent
$findings = [System.Collections.Generic.List[object]]::new()
function Add-Finding([string] $severity, [string] $check, [string] $message) {
    $findings.Add([PSCustomObject]@{ Severity = $severity; Check = $check; Message = $message })
}

function Get-Ast([string] $path) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $tokens, [ref] $errors)
}

function Get-ScriptParameterName([string] $path) {
    $ast = Get-Ast $path
    if (-not $ast.ParamBlock) { return @() }
    @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
}

# --- template usage: action -> script + inputs (from templates/**/*.yml, simple YAML scan)
$usages = @{}
foreach ($file in Get-ChildItem -Path $TemplatesPath -Recurse -Filter '*.yml') {
    $lines = Get-Content -Path $file.FullName -Encoding UTF8
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^(\s*)-?\s*template:\s*/templates/steps/action\.yml\s*$') { continue }
        $action = $null; $script = ''; $inputs = @(); $inInputs = $false; $inputsIndent = -1
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            $line = $lines[$j]
            if ($line -match '^\s*-\s' -and $line -notmatch '^\s*-\s*\$\{\{') { if (-not $inInputs -or $line.Length - $line.TrimStart().Length -le $inputsIndent) { break } }
            if ($line -match '^\s*action:\s*(\S+)\s*$') { $action = $Matches[1] }
            elseif ($line -match '^\s*script:\s*(\S+)\s*$') { $script = $Matches[1] }
            elseif ($line -match '^(\s*)inputs:\s*(\S*)\s*$') { $inInputs = ($Matches[2] -eq ''); $inputsIndent = $Matches[1].Length }
            elseif ($inInputs -and $line -match '^(\s*)([A-Za-z_][A-Za-z0-9_]*):') {
                if ($Matches[1].Length -le $inputsIndent) { $inInputs = $false } else { $inputs += $Matches[2] }
            }
            elseif ($inInputs -and $line.Trim() -and ($line.Length - $line.TrimStart().Length) -le $inputsIndent) { $inInputs = $false }
        }
        if (-not $action -or $action -like '*${{*') { continue }
        $key = "$action|$script"
        if (-not $usages.ContainsKey($key)) { $usages[$key] = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
        $inputs | ForEach-Object { [void]$usages[$key].Add($_) }
    }
}
# repo-maintenance.yml passes the caller's inputs: check the ones the samples use
$usages['IncrementVersionNumber|'] = [System.Collections.Generic.HashSet[string]]::new([string[]]@('projects', 'versionNumber', 'directCommit'), [StringComparer]::OrdinalIgnoreCase)
$usages['CreateApp|'] = [System.Collections.Generic.HashSet[string]]::new([string[]]@('type', 'name', 'publisher', 'idrange', 'project', 'sampleCode', 'sampleSuite', 'directCommit'), [StringComparer]::OrdinalIgnoreCase)

# Actions the templates only run when a setting of a newer AL-Go version enables them
$optionalActions = @{
    'RunTests' = 'the step only runs when RunPipeline sets runTestsInSeparateAction (newer AL-Go)'
}

foreach ($key in ($usages.Keys | Sort-Object)) {
    $action, $script = $key.Split('|')
    $folder = Join-Path $ActionsPath $action
    if (-not (Test-Path $folder)) {
        if ($optionalActions.ContainsKey($action)) { Add-Finding 'Warning' 'Action' "Optional action '$action' does not exist - $($optionalActions[$action])" }
        else { Add-Finding 'Error' 'Action' "Action '$action' does not exist" }
        continue
    }
    if ($script) { $scriptPath = Join-Path $folder $script }
    else { $scriptPath = @("$action.Action.ps1", "$action.ps1") | ForEach-Object { Join-Path $folder $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1 }
    if (-not $scriptPath -or -not (Test-Path $scriptPath)) { Add-Finding 'Error' 'Action' "No script for action '$action' ($script)"; continue }
    $parameters = Get-ScriptParameterName $scriptPath
    foreach ($input in $usages[$key]) {
        if (-not ($parameters | Where-Object { $_ -ieq $input })) {
            Add-Finding 'Warning' 'Input' "$action ($([System.IO.Path]::GetFileName($scriptPath))) has no parameter '$input' (has: $($parameters -join ', '))"
        }
    }
}

# --- overrides: declared parameters
$overrideAst = Get-Ast (Join-Path $repoRoot 'src/AlGoAdo.Overrides.ps1')
$overrides = @{}
foreach ($fn in $overrideAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    $names = @()
    if ($fn.Body.ParamBlock) { $names = @($fn.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
    elseif ($fn.Parameters) { $names = @($fn.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
    $overrides[$fn.Name] = $names
}
$replaced = @($overrides.Keys | Where-Object { $_ -notlike '*-AlGoAdo*' -and $_ -ne 'ConvertTo-AlGoAdoRelease' })

# --- AL-Go sources: definitions and calls of the overridden functions
$defined = @{}
foreach ($file in Get-ChildItem -Path $ActionsPath -Recurse -Include '*.ps1', '*.psm1' -File) {
    $ast = Get-Ast $file.FullName
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($replaced -contains $fn.Name) { $defined[$fn.Name] = $true }
    }
    foreach ($call in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $call.GetCommandName()
        if (-not $name -or $replaced -notcontains $name) { continue }
        foreach ($element in $call.CommandElements) {
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            $p = $element.ParameterName
            # PowerShell accepts unambiguous prefixes of parameter names
            if (-not ($overrides[$name] | Where-Object { $_ -like "$p*" })) {
                $rel = $file.FullName.Substring($ActionsPath.Length).TrimStart('\', '/')
                Add-Finding 'Error' 'Override' "$rel line $($call.Extent.StartLineNumber): $name -$p is not a parameter of the override (has: $($overrides[$name] -join ', '))"
            }
        }
    }
}
foreach ($name in $replaced) {
    if (-not $defined.ContainsKey($name)) { Add-Finding 'Info' 'Override' "$name is no longer defined in AL-Go (override unused)" }
}

if (-not (Test-Path (Join-Path $ActionsPath 'AL-Go-Helper.ps1'))) { Add-Finding 'Error' 'Hook' 'AL-Go-Helper.ps1 not found' }

$findings
if ($findings | Where-Object { $_.Severity -eq 'Error' }) { exit 1 }
