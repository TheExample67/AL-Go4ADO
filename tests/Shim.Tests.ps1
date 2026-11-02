BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/AlGoAdo.Shim.psm1') -Force -DisableNameChecking
}

Describe 'Get-AlGoGitHubEnvironment' {
    BeforeAll {
        $base = @{
            SYSTEM_COLLECTIONURI   = 'https://dev.azure.com/contoso/'
            SYSTEM_TEAMPROJECT     = 'BC'
            BUILD_REPOSITORY_NAME  = 'MyApps'
            BUILD_SOURCEBRANCH     = 'refs/heads/main'
            BUILD_SOURCEVERSION    = 'abc123'
            BUILD_BUILDID          = '4711'
            AL_GO_RUN_NUMBER       = '42'
            SYSTEM_JOBATTEMPT      = '2'
            AGENT_TEMPDIRECTORY    = 'D:\a\_temp'
            BUILD_REQUESTEDFOREMAIL = 'jane.doe@contoso.com'
            SYSTEM_ACCESSTOKEN     = 'token'
        }
    }

    It 'maps a CI build' {
        $adoEnv = $base.Clone(); $adoEnv.BUILD_REASON = 'IndividualCI'
        $gh = Get-AlGoGitHubEnvironment -AdoEnv $adoEnv -Workspace 'D:\a\1\self'
        $gh.GITHUB_EVENT_NAME | Should -Be 'push'
        $gh.GITHUB_REF_NAME | Should -Be 'main'
        $gh.GITHUB_HEAD_REF | Should -Be ''
        $gh.GITHUB_REPOSITORY | Should -Be 'BC/MyApps'
        $gh.GITHUB_SERVER_URL | Should -Be 'https://dev.azure.com/contoso'
        $gh.GITHUB_RUN_NUMBER | Should -Be '42'
        $gh.GITHUB_RUN_ATTEMPT | Should -Be '2'
        $gh.GITHUB_RUN_ID | Should -Be '4711'
        $gh.GITHUB_SHA | Should -Be 'abc123'
        $gh.GITHUB_ACTOR | Should -Be 'jane.doe'
        $gh.GITHUB_WORKSPACE | Should -Be 'D:\a\1\self'
        $gh.RUNNER_TEMP | Should -Be 'D:\a\_temp'
        $gh.GITHUB_ACTIONS | Should -Be 'true'
        $gh.ALGO_ADO | Should -Be 'true'
    }

    It 'maps a pull request build' {
        $adoEnv = $base.Clone()
        $adoEnv.BUILD_REASON = 'PullRequest'
        $adoEnv.BUILD_SOURCEBRANCH = 'refs/pull/17/merge'
        $adoEnv.SYSTEM_PULLREQUEST_PULLREQUESTID = '17'
        $adoEnv.SYSTEM_PULLREQUEST_SOURCEBRANCH = 'refs/heads/feature/x'
        $adoEnv.SYSTEM_PULLREQUEST_TARGETBRANCH = 'refs/heads/main'
        $gh = Get-AlGoGitHubEnvironment -AdoEnv $adoEnv -Workspace 'C:\w'
        $gh.GITHUB_EVENT_NAME | Should -Be 'pull_request'
        $gh.GITHUB_REF_NAME | Should -Be '17/merge'
        $gh.GITHUB_HEAD_REF | Should -Be 'feature/x'
        $gh.GITHUB_BASE_REF | Should -Be 'main'
    }

    It 'falls back to the build id when no run number counter is defined and ignores unresolved macros' {
        $adoEnv = $base.Clone(); $adoEnv.AL_GO_RUN_NUMBER = '$(AL_GO_RUN_NUMBER)'
        (Get-AlGoGitHubEnvironment -AdoEnv $adoEnv -Workspace 'C:\w').GITHUB_RUN_NUMBER | Should -Be '4711'
    }

    It 'uses the workflow name override' {
        $adoEnv = $base.Clone(); $adoEnv.ALGO_WORKFLOW_NAME = 'Test Next Minor'
        (Get-AlGoGitHubEnvironment -AdoEnv $adoEnv -Workspace 'C:\w').GITHUB_WORKFLOW | Should -Be 'Test Next Minor'
    }

    It 'maps build reasons to GitHub events' -TestCases @(
        @{ Reason = 'Schedule'; Event = 'schedule' }
        @{ Reason = 'Manual'; Event = 'workflow_dispatch' }
        @{ Reason = 'BatchedCI'; Event = 'push' }
        @{ Reason = 'ResourceTrigger'; Event = 'workflow_run' }
    ) {
        ConvertTo-GitHubEventName $Reason '' | Should -Be $Event
    }
}

Describe 'New-AlGoEventPayload' {
    It 'creates a pull request payload' {
        $adoEnv = @{ SYSTEM_PULLREQUEST_PULLREQUESTID = '17'; SYSTEM_PULLREQUEST_SOURCECOMMITID = 'head1' }
        $gh = [ordered]@{ GITHUB_REPOSITORY = 'BC/MyApps'; GITHUB_EVENT_NAME = 'pull_request'; GITHUB_HEAD_REF = 'feature/x'; GITHUB_BASE_REF = 'main' }
        $payload = New-AlGoEventPayload -AdoEnv $adoEnv -GitHubEnv $gh -BaseSha 'base1'
        $payload.repository.fork | Should -BeFalse
        $payload.pull_request.number | Should -Be 17
        $payload.pull_request.head.sha | Should -Be 'head1'
        $payload.pull_request.base.sha | Should -Be 'base1'
    }
}

Describe 'ConvertTo-AdoLogLine' {
    It 'translates <Line>' -TestCases @(
        @{ Line = '::error::Something failed'; Expected = '##vso[task.logissue type=error]Something failed' }
        @{ Line = '::Error::Mixed case'; Expected = '##vso[task.logissue type=error]Mixed case' }
        @{ Line = '::Warning::Careful'; Expected = '##vso[task.logissue type=warning]Careful' }
        @{ Line = '::warning file=src/a.al,line=10,col=5::AL0432 obsolete'; Expected = '##vso[task.logissue type=warning;sourcepath=src/a.al;linenumber=10;columnnumber=5]AL0432 obsolete' }
        @{ Line = '::group::Compiling'; Expected = '##[group]Compiling' }
        @{ Line = '::endgroup::'; Expected = '##[endgroup]' }
        @{ Line = '::endgroup::Done analyzing'; Expected = '##[endgroup]' }
        @{ Line = '::Debug::[AL-Go]details'; Expected = '##[debug][AL-Go]details' }
        @{ Line = '::Notice::FYI'; Expected = '##[section]FYI' }
        @{ Line = "`r::add-mask::s3cr3t"; Expected = '##vso[task.setsecret]s3cr3t' }
        @{ Line = 'Plain output :: with colons'; Expected = 'Plain output :: with colons' }
        @{ Line = ''; Expected = '' }
    ) {
        ConvertTo-AdoLogLine -Line $Line | Should -BeExactly $Expected
    }

    It 'suppresses stop-commands' {
        ConvertTo-AdoLogLine -Line '::stop-commands::token' | Should -BeNullOrEmpty
    }
}

Describe 'Read-GitHubFileCommand' {
    It 'parses simple and multi-line values, last one wins' {
        $file = Join-Path $TestDrive 'output.txt'
        @(
            'BuildIt=True'
            'Json={"a":1,"b":"x=y"}'
            'Multi<<EOF_123'
            'line 1'
            'line 2'
            'EOF_123'
            ''
            'BuildIt=False'
        ) | Set-Content -Path $file -Encoding UTF8
        $result = Read-GitHubFileCommand -Path $file
        $result.BuildIt | Should -Be 'False'
        $result.Json | Should -Be '{"a":1,"b":"x=y"}'
        $result.Multi | Should -Be "line 1`nline 2"
        @($result.Keys) | Should -Be @('Json', 'Multi', 'BuildIt')
    }

    It 'returns an empty result for a missing file' {
        (Read-GitHubFileCommand -Path (Join-Path $TestDrive 'nope.txt')).Count | Should -Be 0
    }
}

Describe 'Format-AdoSetVariable' {
    It 'escapes values and sets flags' {
        Format-AdoSetVariable -Name 'X' -Value "a%b`nc" -IsOutput -IsSecret | Should -BeExactly '##vso[task.setvariable variable=X;isOutput=true;issecret=true]a%AZP25b%0Ac'
        Format-AdoSetVariable -Name 'Y' -Value '' | Should -BeExactly '##vso[task.setvariable variable=Y]'
    }

    It 'detects secret variable names' -TestCases @(
        @{ Name = 'Secrets'; Secret = $true }
        @{ Name = 'TokenForPush'; Secret = $true }
        @{ Name = 'containerCredential'; Secret = $true }
        @{ Name = 'Settings'; Secret = $false }
        @{ Name = 'BuildIt'; Secret = $false }
        @{ Name = 'keyVaultCodesignCertificateName'; Secret = $false }
    ) {
        Test-SecretVariableName $Name | Should -Be $Secret
    }
}

Describe 'ConvertTo-AdoBuildMatrix' {
    It 'creates one matrix per build depth' {
        $buildOrder = @(
            @{ projects = @('Base'); projectsCount = 1; buildDimensions = @(@{ project = 'Base'; projectName = 'Base'; buildMode = 'Default' }, @{ project = 'Base'; projectName = 'Base'; buildMode = 'Clean' }) }
            @{ projects = @('Apps/Sales'); projectsCount = 1; buildDimensions = @(@{ project = 'Apps/Sales'; projectName = 'Sales'; buildMode = 'Default' }) }
        ) | ConvertTo-Json -Depth 5 -Compress
        $matrices = ConvertTo-AdoBuildMatrix -BuildOrderJson $buildOrder -MaxBuildDepth 3
        @($matrices.Keys) | Should -Be @('1', '2', '3')
        $matrices['1'].Count | Should -Be 2
        $matrices['1']['Base_Default'].project | Should -Be 'Base'
        $matrices['1']['Base_Clean'].buildMode | Should -Be 'Clean'
        $matrices['2']['Apps_Sales_Default'].projectName | Should -Be 'Sales'
        $matrices['3'].Count | Should -Be 0
    }

    It 'handles the root project and an empty build order' {
        $buildOrder = '[{"buildDimensions":[{"project":".","projectName":".","buildMode":"Default"}]}]'
        $m = ConvertTo-AdoBuildMatrix -BuildOrderJson $buildOrder
        @($m['1'].Keys) | Should -Be @('Default')
        (ConvertTo-AdoBuildMatrix -BuildOrderJson '' -MaxBuildDepth 2)['1'].Count | Should -Be 0
    }
}

Describe 'Get-ActionInputDefault' {
    It 'reads literal defaults and ignores expressions' {
        $folder = Join-Path $TestDrive 'Sign'
        New-Item $folder -ItemType Directory | Out-Null
        @'
name: Sign
inputs:
  shell:
    description: Shell
    required: false
    default: powershell
  timestampService:
    description: Timestamp
    required: false
    default: "http://timestamp.digicert.com"
  token:
    required: false
    default: ${{ github.token }}
  project:
    default: '.'
runs:
  using: composite
'@ | Set-Content -Path (Join-Path $folder 'action.yaml')
        $defaults = Get-ActionInputDefault -ActionFolder $folder
        $defaults.timestampService | Should -Be 'http://timestamp.digicert.com'
        $defaults.project | Should -Be '.'
        $defaults.ContainsKey('token') | Should -BeFalse
    }
}
