<#
    .SYNOPSIS
    Child-process side of Invoke-AlGoAdoAction.ps1. Do not call directly.

    Reads the action parameters from ALGO_PARAM_<name> environment variables (so secrets never
    touch the command line or the disk), converts them to the declared parameter types and runs
    the upstream action through AL-Go's own Invoke-AlGoAction.ps1 wrapper (telemetry + error handling).
#>
Param(
    [Parameter(Mandatory = $true)]
    [string] $ActionsPath,
    [Parameter(Mandatory = $true)]
    [string] $ActionName,
    [Parameter(Mandatory = $true)]
    [string] $ScriptPath
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { Write-Verbose 'Console encoding could not be set' }

$global:AlGoAdoParameters = @{}
$declared = (Get-Command $ScriptPath).Parameters
Get-ChildItem env: | Where-Object { $_.Name -like 'ALGO_PARAM_*' } | ForEach-Object {
    $name = $_.Name.Substring(11)
    $value = $_.Value
    [Environment]::SetEnvironmentVariable($_.Name, [System.Management.Automation.Language.NullString]::Value, [EnvironmentVariableTarget]::Process)
    $paramName = $declared.Keys | Where-Object { $_ -ieq $name } | Select-Object -First 1
    if (-not $paramName) { return }
    $type = $declared[$paramName].ParameterType
    if ($type -eq [switch] -or $type -eq [bool]) {
        $converted = $value -in @('true', 'True', 'TRUE', '1', 'yes', '$true')
        if ($type -eq [switch]) { $converted = [switch]$converted }
    }
    elseif ($type -eq [int] -or $type -eq [int32]) {
        $converted = [int]$value
    }
    elseif ($type -eq [string[]]) {
        $converted = @($value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    else {
        $converted = $value
    }
    $global:AlGoAdoParameters[$paramName] = $converted
}
$global:AlGoAdoScriptPath = $ScriptPath

& (Join-Path $ActionsPath 'Invoke-AlGoAction.ps1') -ActionName $ActionName -Action {
    $p = $global:AlGoAdoParameters
    & $global:AlGoAdoScriptPath @p
}
exit $LASTEXITCODE
