# Regression test: the Azure DevOps agent starts steps with environment variables that have an empty
# value (e.g. an action input that resolves to ''). Windows PowerShell 5.1 lists such variables but
# Remove-Item env:<name> fails with "path not found", which aborted the Build step (pipeline run 31482).

BeforeAll {
    $script:shim = (Resolve-Path (Join-Path $PSScriptRoot '../src/AlGoAdo.Shim.psm1')).Path

    function Invoke-WithEmptyVariable([string] $exe, [string] $command) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"$command`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.EnvironmentVariables['ALGO_INPUT_emptyInput'] = ''
        $psi.EnvironmentVariables['ALGO_INPUT_setInput'] = 'value'
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        [PSCustomObject]@{ ExitCode = $p.ExitCode; Output = $out.Trim() }
    }
}

Describe 'Empty environment variables created by the agent' -Skip:(-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
    It 'is listed by Get-ChildItem env: in <Exe>' -TestCases @(@{ Exe = 'powershell.exe' }, @{ Exe = 'pwsh' }) {
        $r = Invoke-WithEmptyVariable $Exe "(Get-ChildItem env: | Where-Object Name -like 'ALGO_INPUT_*' | ForEach-Object Name | Sort-Object) -join ','"
        $r.Output | Should -Be 'ALGO_INPUT_emptyInput,ALGO_INPUT_setInput'
    }

    It 'is cleared by Set-ProcessEnvironmentVariable without errors in <Exe>' -TestCases @(@{ Exe = 'powershell.exe' }, @{ Exe = 'pwsh' }) {
        $command = "`$ErrorActionPreference = 'Stop'; Import-Module '$script:shim'; " +
            "Get-ChildItem env: | Where-Object Name -like 'ALGO_INPUT_*' | ForEach-Object { Set-ProcessEnvironmentVariable `$_.Name `$null }; " +
            "'left:' + @(Get-ChildItem env: | Where-Object Name -like 'ALGO_INPUT_*').Count"
        $r = Invoke-WithEmptyVariable $Exe $command
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Be 'left:0'
    }
}
