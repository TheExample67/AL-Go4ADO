@{
    ExcludeRules = @(
        # Write-Host is how Azure DevOps logging commands (##vso[...]) are emitted
        'PSAvoidUsingWriteHost',
        # Override functions keep the exact parameter signatures of the AL-Go functions they replace
        'PSReviewUnusedParameter',
        # Function names follow AL-Go / Azure DevOps REST naming (GetReleases, Get-AdoBuilds, ...)
        'PSUseSingularNouns',
        'PSUseShouldProcessForStateChangingFunctions',
        # The child runner passes parameters through globals into AL-Go's Invoke-AlGoAction scriptblock
        'PSAvoidGlobalVars'
    )
}
