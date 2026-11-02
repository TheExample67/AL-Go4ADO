BeforeAll {
    $env:SYSTEM_COLLECTIONURI = 'https://dev.azure.com/contoso/'
    $env:SYSTEM_TEAMPROJECT = 'BC'
    $env:BUILD_REPOSITORY_ID = 'repo-guid'
    $env:BUILD_REPOSITORY_NAME = 'MyApps'
    $env:GITHUB_REPOSITORY = 'BC/MyApps'
    $env:GITHUB_SERVER_URL = 'https://dev.azure.com/contoso'
    . (Join-Path $PSScriptRoot '../src/AlGoAdo.Overrides.ps1')
}

Describe 'Resolve-AdoRepositoryUrl' {
    It 'parses <Url>' -TestCases @(
        @{ Url = 'https://dev.azure.com/contoso/BC/_git/MyApps'; Org = 'https://dev.azure.com/contoso/'; Project = 'BC'; Repo = 'MyApps' }
        @{ Url = 'https://dev.azure.com/contoso/BC/MyApps'; Org = 'https://dev.azure.com/contoso/'; Project = 'BC'; Repo = 'MyApps' }
        @{ Url = 'https://contoso.visualstudio.com/Other%20Project/_git/Base%20App'; Org = 'https://contoso.visualstudio.com/'; Project = 'Other Project'; Repo = 'Base App' }
        @{ Url = 'https://dev.azure.com/fabrikam/Shared/_git/Common.git'; Org = 'https://dev.azure.com/fabrikam/'; Project = 'Shared'; Repo = 'Common' }
    ) {
        $r = Resolve-AdoRepositoryUrl $Url
        $r.OrganizationUrl | Should -Be $Org
        $r.Project | Should -Be $Project
        $r.Repository | Should -Be $Repo
    }

    It 'returns nothing for GitHub repositories' {
        Resolve-AdoRepositoryUrl 'https://github.com/microsoft/bcsamples-bingmaps.pte' | Should -BeNullOrEmpty
    }
}

Describe 'Get-AlGoAdoArtifactRegex' {
    It 'matches AL-Go artifact names' {
        'MyApps-main-Apps-1.0.7.0' | Should -Match (Get-AlGoAdoArtifactRegex -project '*' -mask 'Apps')
        'MyApps-main-TestApps-1.0.7.0' | Should -Not -Match (Get-AlGoAdoArtifactRegex -project '*' -mask 'Apps')
        'MyApps-main-CleanApps-1.0.7.0' | Should -Not -Match (Get-AlGoAdoArtifactRegex -project '*' -mask 'Apps')
        'Apps_Sales-release_2.x-Apps-2.0.1.0' | Should -Match (Get-AlGoAdoArtifactRegex -project 'Apps/Sales' -mask 'Apps' -branch 'release/2.x')
        'Apps_Sales-main-Apps-2.0.1.0' | Should -Not -Match (Get-AlGoAdoArtifactRegex -project 'Apps/Sales' -mask 'Apps' -branch 'release/2.x')
        'Base-main-Apps-1.2.3.4' | Should -Match (Get-AlGoAdoArtifactRegex -project 'Base' -mask 'Apps' -version '1.2.3.4')
        'Base-main-Apps-1.2.3.5' | Should -Not -Match (Get-AlGoAdoArtifactRegex -project 'Base' -mask 'Apps' -version '1.2.3.4')
    }

    It 'captures the project name' {
        'Apps_Sales-main-Apps-2.0.1.0' -match (Get-AlGoAdoArtifactRegex -project '*' -mask 'Apps' -branch 'main') | Should -BeTrue
        $Matches['project'] | Should -Be 'Apps_Sales'
    }
}

Describe 'Releases' {
    BeforeAll {
        function New-Build($id, $tags) {
            [PSCustomObject]@{ id = $id; tags = $tags; sourceBranch = 'refs/heads/main'; sourceVersion = "sha$id"; _links = [PSCustomObject]@{ web = [PSCustomObject]@{ href = "https://x/$id" } } }
        }
    }

    It 'returns releases sorted by version, newest first' {
        Mock Get-AdoBuilds {
            @(
                (New-Build 30 @('AL-Go-CICD', 'AL-Go-Release', 'AL-Go-Release:1.10.0', 'AL-Go-Prerelease'))
                (New-Build 20 @('AL-Go-CICD', 'AL-Go-Release', 'AL-Go-Release:1.9.0'))
                (New-Build 10 @('AL-Go-CICD', 'AL-Go-Release', 'AL-Go-Release:v1.2.0'))
            )
        }
        $releases = @(GetReleases)
        $releases.tag_name | Should -Be @('1.10.0', '1.9.0', 'v1.2.0')
        $releases[0].prerelease | Should -BeTrue
        $releases[1].buildId | Should -Be 20
    }

    It 'GetLatestRelease skips prereleases and honors release branches' {
        Mock Get-AdoBuilds {
            @(
                (New-Build 40 @('AL-Go-Release', 'AL-Go-Release:3.0.0', 'AL-Go-Prerelease'))
                (New-Build 30 @('AL-Go-Release', 'AL-Go-Release:2.1.0'))
                (New-Build 20 @('AL-Go-Release', 'AL-Go-Release:1.5.0'))
            )
        }
        (GetLatestRelease -ref 'main').tag_name | Should -Be '2.1.0'
        (GetLatestRelease -ref 'release/1.x').tag_name | Should -Be '1.5.0'
    }
}

Describe 'GetArtifacts' {
    It 'returns the newest artifact per project' {
        Mock Get-AdoBuilds { @([PSCustomObject]@{ id = 2 }, [PSCustomObject]@{ id = 1 }) }
        Mock Get-AdoBuildArtifacts {
            if ($BuildId -eq 2) { @([PSCustomObject]@{ name = 'Base-main-Apps-1.0.2.0' }) }
            else { @([PSCustomObject]@{ name = 'Base-main-Apps-1.0.1.0' }, [PSCustomObject]@{ name = 'Sales-main-Apps-1.0.1.0' }) }
        }
        $result = @(GetArtifacts -mask 'Apps' -projects 'Base,Sales' -version 'latest' -branch 'main')
        $result.name | Should -Be @('Base-main-Apps-1.0.2.0', 'Sales-main-Apps-1.0.1.0')
        $result[0].buildId | Should -Be 2
    }

    It 'stops at the first build with artifacts when all projects are requested' {
        Mock Get-AdoBuilds { @([PSCustomObject]@{ id = 2 }, [PSCustomObject]@{ id = 1 }) }
        Mock Get-AdoBuildArtifacts { @([PSCustomObject]@{ name = "Base-main-Apps-1.0.$BuildId.0" }) }
        @(GetArtifacts -mask 'Apps' -projects '*' -version 'latest' -branch 'main').name | Should -Be @('Base-main-Apps-1.0.2.0')
        Should -Invoke Get-AdoBuildArtifacts -Times 1 -Exactly
    }
}

Describe 'GetGitHubEnvironments' {
    It 'returns the environments declared in the pipeline' {
        $env:ALGO_ENVIRONMENTS = 'QA, PROD'
        @(GetGitHubEnvironments | ForEach-Object { $_.name }) | Should -Be @('QA', 'PROD')
        $env:ALGO_ENVIRONMENTS = "[`n  {`n    `"name`": `"QA`",`n    `"adoEnvironment`": `"BC-QA`"`n  },`n  { `"name`": `"PROD (Production)`" }`n]"
        @(GetGitHubEnvironments | ForEach-Object { $_.name }) | Should -Be @('QA', 'PROD (Production)')
        $env:ALGO_ENVIRONMENTS = '{ "name": "QA" }'
        @(GetGitHubEnvironments | ForEach-Object { $_.name }) | Should -Be @('QA')
        $env:ALGO_ENVIRONMENTS = ''
        @(GetGitHubEnvironments).Count | Should -Be 0
    }
}
