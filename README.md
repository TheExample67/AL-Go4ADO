# AL-Go for Azure DevOps (AL-Go4ADO)

[![AL-Go compatibility](https://github.com/TheExample67/AL-Go4ADO/actions/workflows/al-go-compatibility.yml/badge.svg)](https://github.com/TheExample67/AL-Go4ADO/actions/workflows/al-go-compatibility.yml)

Run [AL-Go for GitHub](https://github.com/microsoft/AL-Go) — Microsoft's build system for Business Central AL
apps — in **Azure DevOps Pipelines**, on **Microsoft-hosted** or **self-hosted** agents.

AL-Go4ADO is a **wrapper**: it runs the unmodified upstream `microsoft/AL-Go-Actions` PowerShell scripts and
bridges the GitHub-specific parts (environment, outputs, log commands, GitHub REST API) to Azure DevOps.
Your repositories keep the standard AL-Go layout and settings (`.github/AL-Go-Settings.json`,
`.AL-Go/settings.json`, …), so the same settings documentation applies: <https://aka.ms/algosettings>.

See [docs/PLAN.md](docs/PLAN.md) for the architecture, the GitHub → Azure DevOps mapping and the roadmap.

## Who is this for?

AL-Go4ADO is meant as a **stepping stone to GitHub**. It is for Business Central teams whose code and pipelines
live in Azure DevOps today and who see their future on GitHub with AL-Go — but can't move everything at once.

Moving a team's whole development process is a big step. AL-Go4ADO lets you take the largest part of it
first, inside the environment you already know:

- **Adopt AL-Go now.** Restructure your repositories into AL-Go projects, move your build configuration into
  AL-Go settings, use AL-Go's versioning, test runs, code analysis and release model — with your existing
  Azure DevOps repositories, agents, feeds and approvals.
- **Learn it with your real code.** Your team gets used to AL-Go's conventions and settings while delivery
  continues as usual, instead of learning a new platform and a new build system on the same day.
- **Move when you are ready.** Everything that describes *how* your apps are built — repository layout,
  `.AL-Go/settings.json`, `.github/AL-Go-Settings.json`, override scripts such as `NewBcContainer.ps1` —
  works unchanged in AL-Go for GitHub. The move itself is mostly about the platform: add the AL-Go workflows,
  move secrets and environments to GitHub, and retire the Azure DevOps pipeline files.

AL-Go4ADO runs the original AL-Go code and follows its releases (tested weekly against every AL-Go release),
so what you learn and configure here carries over. It also works as a long-term setup, but some AL-Go
features exist only on GitHub (see [Limitations](#limitations--not-yet-supported)) - if you plan to stay on
Azure DevOps for good, check that list first.

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

1. **Get AL-Go4ADO into Azure DevOps**: import this repository into your organization (e.g. project `Shared`,
   repository `AL-Go4ADO`, including tags), or reference it on GitHub directly (`type: github` with a GitHub
   service connection). Pin a release, see [Versions](#versions).
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

## Delivery

The CI/CD pipeline delivers the build to every target that has a `<target>Context` secret and whose
`DeliverTo<target>` settings (`Branches` - default `main` only - and `ContinuousDelivery`) allow it:
NuGet, Storage, AppSource and custom targets (`.github/DeliverTo<target>.ps1`), exactly as in AL-Go.

For an **Azure Artifacts feed** no secret is needed - pass the feed URL and the pipeline's own token is used
(grant the project's build service *Feed Publisher (Contributor)* on the feed):

```yaml
    nuGetFeedUrl: https://pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/nuget/v3/index.json
```

Continuous delivery creates preview packages in BcContainerHelper's BC NuGet format. Use a feed of its own -
packages produced by other tooling in a different format should not be mixed into the same feed.

## AL code analysis

Set the AL-Go setting `"trackALAlertsInGitHub": true` (the name is AL-Go's; it also works in Azure DevOps).
The compiler then writes error logs, and a *Code analysis* job turns them into SARIF and publishes:

- a build summary with the issues per severity, rule, app folder and file,
- the pipeline artifact `CodeAnalysisLogs` (shown as *Scans* tab with the
  [SARIF SAST Scans Tab](https://marketplace.visualstudio.com/items?itemName=sariftools.scans) extension),
- Advanced Security alerts with `advancedSecurity: true` (needs GitHub Advanced Security for Azure DevOps).

Use `codeAnalysisShell: pwsh` on agents with PowerShell 7 - processing thousands of issues is about 5x faster.

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

## Versions

AL-Go4ADO is released from GitHub with the [Release](.github/workflows/release.yml) workflow, which first runs the
full AL-Go compatibility tests. Each release gets a tag and release notes
([releases](https://github.com/TheExample67/AL-Go4ADO/releases)):

| `ref` in your pipeline | Gets |
|---|---|
| `refs/tags/v0.1` | the newest `0.1.x` release - fixes arrive automatically |
| `refs/tags/v0.1.0` | exactly that release - fully reproducible |
| `refs/heads/main` | every change as soon as it is merged - for trying things out only |

Before 1.0, a new minor version (0.2) may contain breaking changes, so the moving tag follows the minor line;
from 1.0 on it follows the major version (`v1`). 0.x releases are marked as pre-release.

If your pipelines use an imported Azure DevOps copy, bring new tags over with
`git fetch --tags <github> && git push --tags <azure-devops>` (the moving tag needs `--force`).

## Supported AL-Go versions

AL-Go4ADO supports **AL-Go v9.1 and later**. `alGoVersion` selects the `microsoft/AL-Go-Actions` ref
(default `v10.0`; pin a commit SHA for fully reproducible builds).

The [AL-Go compatibility](.github/workflows/al-go-compatibility.yml) workflow tests every AL-Go release from
v9.1 and AL-Go's `main` branch (preview, informational) on every change and weekly, so new AL-Go releases are
checked automatically:

- unit tests on Windows PowerShell 5.1 and PowerShell 7,
- a static check that the actions and inputs the templates use exist and that AL-Go's calls to the functions
  AL-Go4ADO replaces still match (`tests/Test-AlGoCompatibility.ps1`),
- a smoke test running real AL-Go actions through the wrapper in a simulated agent (`tests/Invoke-SmokeTest.ps1`).

Locally:

```powershell
Invoke-Pester ./tests
./tests/Invoke-SmokeTest.ps1 -AlGoVersion v10.0
git clone --depth 1 --branch v10.0 https://github.com/microsoft/AL-Go-Actions.git $env:TEMPlgo
./tests/Test-AlGoCompatibility.ps1 -ActionsPath $env:TEMPlgo
```

## Telemetry

AL-Go sends telemetry to Microsoft by default (upstream behavior). To disable it, set
`"microsoftTelemetryConnectionString": ""` in your settings.

## Limitations / not yet supported

* GitHub-only features: Copilot PR review, GitHub Pages (ALDoc), `Update AL-Go System Files`
  (use the template `ref` instead), GitHub Packages, PR builds from forks.
* Power Platform build and ALDoc reference documentation are on the roadmap (see docs/PLAN.md).
* Delivery as part of *Create release* (non-preview NuGet packages, AppSource submission) is not wired yet.
* Re-running only failed jobs re-publishes artifacts with existing names and fails; re-run the whole pipeline.
* Draft releases do not exist in Azure DevOps.

## License

[MIT](LICENSE). Parts are derived from [AL-Go for GitHub](https://github.com/microsoft/AL-Go)
(MIT, © Microsoft Corporation), see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
AL-Go4ADO is not affiliated with or endorsed by Microsoft.
