# AL-Go for Azure DevOps (AL-Go4ADO)

Run [AL-Go for GitHub](https://github.com/microsoft/AL-Go) — Microsoft's build system for Business Central AL
apps — in **Azure DevOps Pipelines**, on **Microsoft-hosted** or **self-hosted** agents.

AL-Go4ADO is a **wrapper**: it runs the unmodified upstream `microsoft/AL-Go-Actions` PowerShell scripts and
bridges the GitHub-specific parts (environment, outputs, log commands, GitHub REST API) to Azure DevOps.
Your repositories keep the standard AL-Go layout and settings (`.github/AL-Go-Settings.json`,
`.AL-Go/settings.json`, …), so the same settings documentation applies: <https://aka.ms/algosettings>.

See [docs/PLAN.md](docs/PLAN.md) for the architecture, the GitHub → Azure DevOps mapping and the roadmap.

## What you get

| Pipeline (template)                                | AL-Go for GitHub equivalent            |
|----------------------------------------------------|----------------------------------------|
| `templates/pipelines/cicd.yml`                     | CI/CD (+ Test Current / Next Minor / Next Major via `workflowName`) |
| `templates/pipelines/pull-request.yml`             | Pull Request Handler                   |
| `templates/pipelines/create-release.yml`           | Create release                         |
| `templates/pipelines/publish-to-environment.yml`   | Publish To Environment                 |
| `templates/pipelines/repo-maintenance.yml`         | Increment Version Number, Create a new app / test app / performance test app, Add existing app |

Supported: multi-project repositories with dependencies (build order → one matrix job per build depth),
build modes, containers or compiler folder, tests (results in the ADO *Tests* tab), code signing
(Key Vault / Trusted Signing), BC artifact cache, previous-release upgrade tests, incremental builds,
`appDependencyProbingPaths` to other Azure DevOps (and GitHub) repositories, deployment to Business
Central environments with Azure DevOps approvals, releases, and pull requests created by maintenance pipelines.

## Quick start

1. **Import this repository** into your Azure DevOps organization (e.g. project `Shared`, repository `AL-Go4ADO`)
   and tag a version (`git tag v1.0.0`).
2. **Create an AL-Go repository** — start from [`samples/per-tenant-extension`](samples/per-tenant-extension)
   (or keep an existing AL-Go for GitHub repository; only the pipeline files are new).
   Update `resources.repositories` in the pipeline files to point to your copy of AL-Go4ADO.
3. **Create the pipelines** in Azure DevOps from the YAML files in `.azure-pipelines/`
   (name the CI/CD pipeline `CICD`, it is referenced by `CreateRelease.yml`).
4. **Variable group** `AL-Go` (Pipelines → Library) with the secrets you need, for example
   `licenseFileUrl`, `AZURE_CREDENTIALS`, `insiderSasToken`, `ghTokenWorkflow`; optionally link it to an
   Azure Key Vault. Organization/repository settings can be set as variables `ALGoOrgSettings` / `ALGoRepoSettings` (JSON).
   Authorize the pipelines to use the group.
5. **Branch policy**: add `PullRequest.yml` as *Build validation* on `main`.
6. **Permissions** of the project's build service identity (*Project Settings → Repositories → Security* and
   *Pipelines → Security*), only needed for the features you use:

   | Feature                                  | Permission                                                                 |
   |------------------------------------------|----------------------------------------------------------------------------|
   | Create release                           | Repository: *Create tag*, *Create branch*; CI/CD pipeline: *Edit build quality*, *Manage builds* |
   | Increment version / Create app (PR)      | Repository: *Contribute*, *Create branch*, *Contribute to pull requests*   |
   | Dependencies on other repositories       | *Read* on those repositories and their pipelines                          |

   If *Limit job authorization scope to current project* is enabled, cross-project dependencies need it disabled.

## Agents

Every job runs on the pool you pass in:

```yaml
extends:
  template: templates/pipelines/cicd.yml@AlGoAdo
  parameters:
    initPool:  { vmImage: windows-latest }          # light-weight jobs
    buildPool: { name: 'BC Build Agents' }          # self-hosted pool
    deployPool: { vmImage: windows-latest }
    shell: powershell                               # or pwsh
```

* **Microsoft-hosted** (`windows-latest`): works out of the box. Docker with Windows containers is available,
  but container builds are slow on hosted agents; consider `"useCompilerFolder": true` and `"doNotPublishApps": true`
  in `.github/AL-Go-Settings.json` (compile only, no tests), and run tests on a self-hosted pool.
* **Self-hosted**: Windows with PowerShell 5.1 (or 7 with `shell: pwsh`), git, and Docker (Windows containers) for
  container builds. AL-Go actions are cached per agent in `Agent.ToolsDirectory`; BcContainerHelper and BC
  artifacts are cached as usual. Agents without access to github.com can vendor the AL-Go actions into the
  repository and set `localActionsPath` (e.g. `.al-go/actions`).

## Secrets

Azure DevOps does not expose secret variables to scripts unless they are mapped explicitly. The templates map
every name in the `secretNames` parameter (default: the common AL-Go secrets) into the `ReadSecrets` step,
plus `<env>-AuthContext`, `<env>_AuthContext` and `AuthContext` for deployments. Names that are not defined are
simply ignored. Key Vault access through `AZURE_CREDENTIALS` + `keyVaultName` works exactly as in AL-Go.
`System.AccessToken` replaces `github_token`.

## Deployment

Declare environments on the CI/CD pipeline; each gets a deployment job against an Azure DevOps environment,
so approvals and checks configured there apply. Whether a run deploys is decided by AL-Go
(`DeployTo<env>` settings: `Branches`, `continuousDeployment`, `Projects`, …):

```yaml
    environments:
    - name: QA                        # AL-Go environment name, secret QA-AuthContext
      adoEnvironment: BC-QA
      variableGroup: AL-Go-QA         # optional: environment-specific secrets
    - name: PROD
      adoEnvironment: BC-PROD         # e.g. with an approval check
```

Set `"DeployToPROD": { "continuousDeployment": false }` in the AL-Go settings to deploy PROD only through
`PublishToEnvironment.yml`.

## Releases

A release is a CI/CD run marked with the build tags `AL-Go-Release` / `AL-Go-Release:<tag>` (plus `AL-Go-Prerelease`),
protected by a retention lease, with a git tag on the built commit. `CreateRelease.yml` creates it from the run
selected in the *Resources* picker. Releases are used by `DownloadPreviousRelease` (upgrade testing),
`appDependencyProbingPaths` (`release_status: release|prerelease`) and `PublishToEnvironment.yml`.

## How it works (short)

`templates/steps/action.yml` runs `src/Invoke-AlGoAdoAction.ps1 -Action <Name>`, which

1. maps Azure DevOps variables to the `GITHUB_*` environment AL-Go expects (`src/AlGoAdo.Shim.psm1`),
2. runs the upstream action script in a child PowerShell process and converts `::error::`, `::group::`,
   `::add-mask::`, … to Azure DevOps logging commands,
3. publishes `GITHUB_OUTPUT` as output variables (`$(<step>.<Output>)`) and `GITHUB_ENV` as job variables,
4. lets `src/AlGoAdo.Overrides.ps1` (hooked into `AL-Go-Helper.ps1`) replace the GitHub API calls
   (releases, artifacts, last known good build, environments, git push / pull requests) with Azure DevOps REST.

## Upgrading AL-Go

`alGoVersion` selects the `microsoft/AL-Go-Actions` ref (default `v10.0`; pin a commit SHA for fully
reproducible builds). Before raising the default, run the tests against the new version:

```powershell
Invoke-Pester ./tests
./tests/Invoke-SmokeTest.ps1 -AlGoVersion v10.1     # runs real AL-Go actions in a simulated agent
```

## Telemetry

AL-Go sends telemetry to Microsoft by default (upstream behavior). To disable it, set
`"microsoftTelemetryConnectionString": ""` in your settings.

## Limitations / not yet supported

* GitHub-only features: Copilot PR review, GitHub Pages (ALDoc), `Update AL-Go System Files`
  (use the template `ref` instead), GitHub Packages, PR builds from forks.
* Delivery (`Deliver` to NuGet/Storage/AppSource) and Power Platform build are on the roadmap (see docs/PLAN.md).
* Re-running only failed jobs re-publishes artifacts with existing names and fails; re-run the whole pipeline.
* Draft releases do not exist in Azure DevOps.
