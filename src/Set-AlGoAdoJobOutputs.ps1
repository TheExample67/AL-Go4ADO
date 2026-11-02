<#
    .SYNOPSIS
    Publishes values derived from AL-Go state as Azure DevOps variables, for use in job/step conditions and matrices.

    .DESCRIPTION
    Azure DevOps conditions have no fromJson() or hashFiles(); this script evaluates those
    expressions from the AL-Go job state and publishes simple True/False (or JSON matrix) variables.

    Modes:
      Initialization - output variables matrix<N>/count<N> (build matrices per depth),
                       deploy_<environment> flags (environments from ALGO_ENVIRONMENTS),
                       deliverMatrix/deliverCount (delivery targets) and trackALAlerts.
                       Run as step named 'AlGoAdo'.
      BuildSettings  - job variables algoWorkspaceCompilation, algoCanSign, algoHasBuildInitializeHook, algoHasBuildFinalizeHook.
      BuildOutputs   - job variables algoHas<ArtifactType> telling which build outputs exist for the project.
#>
Param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Initialization', 'BuildSettings', 'BuildOutputs')]
    [string] $Mode,
    [int] $MaxBuildDepth = 1,
    [string] $Project = '.',
    [string] $Workspace = $env:ALGO_WORKSPACE
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AlGoAdo.Shim.psm1') -Force -DisableNameChecking

$stateFile = Join-Path (Join-Path $env:AGENT_TEMPDIRECTORY 'al-go-ado') 'state.json'
$state = $null
if (Test-Path $stateFile) { $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json }

function Get-PropertyNames($object) {
    if ($null -eq $object) { return @() }
    return @($object.PSObject.Properties | ForEach-Object { $_.Name })
}

function Get-StepOutput([string] $step, [string] $name, [string] $default = '') {
    if ($state -and (Get-PropertyNames $state.outputs) -contains $step) {
        $o = $state.outputs.$step
        if ((Get-PropertyNames $o) -contains $name) { return "$($o.$name)" }
    }
    return $default
}

function Get-JobEnv([string] $name, [string] $default = '') {
    if ($state -and (Get-PropertyNames $state.env) -contains $name) { return "$($state.env.$name)" }
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($value) { return $value }
    return $default
}

function Set-Var([string] $name, [string] $value, [switch] $IsOutput) {
    Write-Host "$name = $value"
    Write-Host (Format-AdoSetVariable -Name $name -Value $value -IsOutput:$IsOutput)
}

switch ($Mode) {
    'Initialization' {
        $matrices = ConvertTo-AdoBuildMatrix -BuildOrderJson (Get-StepOutput 'DetermineProjectsToBuild' 'BuildOrderJson' '[]') -MaxBuildDepth $MaxBuildDepth
        foreach ($depth in $matrices.Keys) {
            if ([int]$depth -gt $MaxBuildDepth) {
                if ($matrices[$depth].Count -gt 0) { throw "The build order requires $depth levels, but the pipeline supports $MaxBuildDepth (template parameter maxBuildDepth)" }
                continue
            }
            Set-Var -IsOutput "count$depth" "$($matrices[$depth].Count)"
            Set-Var -IsOutput "matrix$depth" (ConvertTo-Json -InputObject $matrices[$depth] -Depth 5 -Compress)
        }

        $deploymentEnvironments = $null
        $json = Get-StepOutput 'DetermineDeploymentEnvironments' 'DeploymentEnvironmentsJson' '{}'
        if ($json) { $deploymentEnvironments = $json | ConvertFrom-Json }
        $names = Get-PropertyNames $deploymentEnvironments
        foreach ($envName in (Get-AlGoAdoEnvironmentName)) {
            $id = $envName -replace '[ .()-]', '_'
            Set-Var -IsOutput "deploy_$id" "$($names -contains $envName)"
        }

        $deliveryMatrix = ConvertTo-AdoDeliveryMatrix -DeliveryTargetsJson (Get-StepOutput 'DetermineDeliveryTargets' 'DeliveryTargetsJson' '[]')
        Set-Var -IsOutput 'deliverCount' "$($deliveryMatrix.Count)"
        Set-Var -IsOutput 'deliverMatrix' (ConvertTo-Json -InputObject $deliveryMatrix -Depth 5 -Compress)
        Set-Var -IsOutput 'trackALAlerts' "$((Get-JobEnv 'trackALAlertsInGitHub' 'False') -eq 'True')"
    }
    'BuildSettings' {
        $settings = (Get-JobEnv 'Settings' '{}') | ConvertFrom-Json
        $workspaceCompilation = $false
        $settingNames = Get-PropertyNames $settings
        if ($settingNames -contains 'workspaceCompilation' -and $settings.workspaceCompilation -and (Get-PropertyNames $settings.workspaceCompilation) -contains 'enabled') {
            $workspaceCompilation = [bool]$settings.workspaceCompilation.enabled
        }
        $canSign = $false
        if ($settingNames -contains 'keyVaultCodesignCertificateName' -and $settings.keyVaultCodesignCertificateName) { $canSign = $true }
        if ($settingNames -contains 'trustedSigning' -and $settings.trustedSigning) {
            $ts = $settings.trustedSigning
            $props = Get-PropertyNames $ts
            if ($props -contains 'Endpoint' -and $props -contains 'Account' -and $props -contains 'CertificateProfile' -and $ts.Endpoint -and $ts.Account -and $ts.CertificateProfile) { $canSign = $true }
        }
        Set-Var 'algoWorkspaceCompilation' "$workspaceCompilation"
        Set-Var 'algoCanSign' "$canSign"
        Set-Var 'algoHasBuildInitializeHook' "$(Test-Path (Join-Path $Workspace "$Project/.AL-Go/BuildInitialize.ps1"))"
        Set-Var 'algoHasBuildFinalizeHook' "$(Test-Path (Join-Path $Workspace "$Project/.AL-Go/BuildFinalize.ps1"))"
    }
    'BuildOutputs' {
        $projectFolder = Join-Path $Workspace $Project
        $buildArtifacts = Join-Path $projectFolder '.buildartifacts'
        $checks = [ordered]@{
            'algoHasApps'                           = Join-Path $buildArtifacts 'Apps/*'
            'algoHasAppFiles'                       = Join-Path $buildArtifacts 'Apps/*.app'
            'algoHasDependencies'                   = Join-Path $buildArtifacts 'Dependencies/*'
            'algoHasTestApps'                       = Join-Path $buildArtifacts 'TestApps/*'
            'algoHasBuildOutput'                    = Join-Path $projectFolder 'BuildOutput.txt'
            'algoHasContainerEventLog'              = Join-Path $projectFolder 'ContainerEventLog.evtx'
            'algoHasTestResults'                    = Join-Path $buildArtifacts 'TestResults.xml'
            'algoHasBcptTestResults'                = Join-Path $buildArtifacts 'bcptTestResults.json'
            'algoHasPageScriptingTestResults'       = Join-Path $buildArtifacts 'PageScriptingTestResults.xml'
            'algoHasPageScriptingTestResultDetails' = Join-Path $buildArtifacts 'PageScriptingTestResultDetails/*'
            'algoHasErrorLogs'                      = Join-Path $buildArtifacts 'ErrorLogs/*'
        }
        foreach ($name in $checks.Keys) {
            Set-Var $name "$([bool](Get-ChildItem -Path $checks[$name] -ErrorAction SilentlyContinue))"
        }
    }
}
