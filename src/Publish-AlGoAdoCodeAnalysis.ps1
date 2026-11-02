<#
    .SYNOPSIS
    Publishes the AL code analysis results (SARIF from AL-Go's ProcessALCodeAnalysisLogs) in Azure DevOps.

    .DESCRIPTION
    - Writes a markdown build summary: totals per severity, top rules, apps and files
    - Copies the SARIF file to <OutputFolder> (default $(Build.ArtifactStagingDirectory)/CodeAnalysisLogs),
      which the pipeline publishes as artifact 'CodeAnalysisLogs'. That artifact name is what the
      "SARIF SAST Scans Tab" extension shows as the Scans tab, and the folder is the input for
      Advanced Security (AdvancedSecurity-Publish@1).
    - Sets the job variable algoHasSarif.
#>
Param(
    [string] $SarifFile = (Join-Path $env:ALGO_WORKSPACE 'ErrorLogs/output.sarif.json'),
    [string] $OutputFolder = (Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY 'CodeAnalysisLogs'),
    [int] $Top = 15
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not (Test-Path $SarifFile)) {
    Write-Host "No SARIF file found at $SarifFile - no AL code analysis results to publish"
    Write-Host '##vso[task.setvariable variable=algoHasSarif]False'
    return
}

$sarif = Get-Content -Path $SarifFile -Raw -Encoding UTF8 | ConvertFrom-Json
$run = @($sarif.runs)[0]
$results = @($run.results)
$rules = @{}
foreach ($rule in @($run.tool.driver.rules)) { if ($rule) { $rules["$($rule.id)"] = $rule } }

function Get-ResultPath($result) {
    "$($result.locations[0].physicalLocation.artifactLocation.uri)".Replace('%20', ' ')
}

function Format-MarkdownTable([string[]] $headers, [object[]] $rows) {
    $lines = @("| $($headers -join ' | ') |", "|$((@($headers) | ForEach-Object { '---' }) -join '|')|")
    foreach ($row in $rows) { $lines += "| $(($row | ForEach-Object { "$_".Replace('|', '\|') }) -join ' | ') |" }
    $lines
}

$md = @('## AL code analysis', '')
if ($results.Count -eq 0) {
    $md += 'No warnings or errors reported by the AL compiler.'
}
else {
    $bySeverity = $results | Group-Object -Property level | Sort-Object -Property Name
    $md += "**$($results.Count)** issue(s): " + (($bySeverity | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', ')
    $md += ''

    $md += "### Top rules"
    $md += Format-MarkdownTable @('Rule', 'Count', 'Description') @(
        $results | Group-Object -Property ruleId | Sort-Object -Property Count -Descending | Select-Object -First $Top | ForEach-Object {
            $description = ''
            if ($rules.ContainsKey($_.Name)) { $description = "$($rules[$_.Name].shortDescription.text)" -replace "^$([regex]::Escape($_.Name)):\s*", '' }
            if ($description.Length -gt 120) { $description = $description.Substring(0, 117) + '...' }
            , @($_.Name, $_.Count, $description)
        })
    $md += ''

    $md += "### Issues per app folder"
    $md += Format-MarkdownTable @('App folder', 'Count') @(
        $results | Group-Object -Property { (Get-ResultPath $_).Split('/')[0] } | Sort-Object -Property Count -Descending | Select-Object -First $Top | ForEach-Object { , @($_.Name, $_.Count) })
    $md += ''

    $md += "### Top files"
    $md += Format-MarkdownTable @('File', 'Count') @(
        $results | Group-Object -Property { Get-ResultPath $_ } | Sort-Object -Property Count -Descending | Select-Object -First $Top | ForEach-Object { , @($_.Name, $_.Count) })
}

New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
Copy-Item -Path $SarifFile -Destination (Join-Path $OutputFolder 'ALCodeAnalysis.sarif') -Force
$summaryFile = Join-Path $env:AGENT_TEMPDIRECTORY 'al-code-analysis.md'
Set-Content -Path $summaryFile -Value ($md -join "`n") -Encoding UTF8
Write-Host ($md -join "`n")
Write-Host "##vso[task.uploadsummary]$summaryFile"
Write-Host '##vso[task.setvariable variable=algoHasSarif]True'
