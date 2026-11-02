# AL-Go for Azure DevOps — Plan & Implementation Steps

## 1. Goal

Run Microsoft's **AL-Go for GitHub** build system (Business Central AL apps: settings,
multi-project builds, containers/compiler folder, tests, signing, deployment, releases)
from **Azure DevOps Pipelines**, on **Microsoft-hosted** or **self-hosted** agents,
without forking AL-Go.

## 2. Decision: wrapper, not rebuild

All of AL-Go's real logic lives in PowerShell (`microsoft/AL-Go-Actions`). The GitHub
coupling is a thin, well-defined layer:

| Coupling                                   | How AL-Go uses it                                | How we bridge it                                                               |
|--------------------------------------------|--------------------------------------------------|--------------------------------------------------------------------------------|
| `GITHUB_*` environment variables           | branch, sha, run number, workspace, event, repo  | **Shim** computes them from ADO predefined variables                           |
| `GITHUB_OUTPUT` / `GITHUB_ENV` files       | step outputs and job environment                 | Shim creates the files, then publishes them as ADO variables / job state       |
| `GITHUB_STEP_SUMMARY`                      | markdown summaries                               | `##vso[task.uploadsummary]`                                                    |
| Workflow commands (`::error::`, `::group::`, `::add-mask::` …) | logging                      | Child process output is translated line-by-line to `##vso[...]` / `##[group]` |
| `GITHUB_EVENT_PATH`                        | PR head/base sha, fork status                    | Synthetic event JSON generated from ADO PR variables                           |
| GitHub REST API (releases, artifacts, runs, environments, PRs) | ~12 helper functions          | **Overrides** re-implemented on top of Azure DevOps REST                       |
| `actions/upload-artifact` / `download-artifact` | build artifacts                             | `PublishPipelineArtifact@1` / `DownloadPipelineArtifact@2` / ADO REST          |
| GitHub secrets / environments              | secrets & approvals                              | Variable groups (optionally Key Vault linked) & ADO Environments               |
| Reusable workflows + "Update AL-Go System Files" | distribution / updates                     | ADO **extends templates** referenced via `resources.repositories` (pinned ref) |

A rebuild would mean re-implementing ~13k lines of PowerShell and tracking upstream
forever. The wrapper pins an upstream AL-Go version and only owns the bridge.

## 3. Architecture

```
Consumer repo (your AL apps)                 AL-Go4ADO repo (this repo)
────────────────────────────                 ───────────────────────────────────────────
.azure-pipelines/CICD.yml ──extends──────▶  templates/pipelines/cicd.yml
.github/AL-Go-Settings.json                    ├─ templates/jobs/initialization.yml
.AL-Go/settings.json (per project)             ├─ templates/jobs/build.yml  (matrix per build depth)
app folders …                                  └─ templates/stages/deploy.yml
                                             templates/steps/action.yml ─┐
                                                                          ▼
                                             src/Invoke-AlGoAdoAction.ps1 (parent, in agent step)
                                               │ 1. restore job state, compute GITHUB_* env
                                               │ 2. spawn child shell ──▶ src/Invoke-AlGoAdoActionChild.ps1
                                               │                            └─ upstream Invoke-AlGoAction.ps1
                                               │                                 └─ upstream <Action>.ps1
                                               │                                      └─ AL-Go-Helper.ps1
                                               │                                           └─ (hook) AlGoAdo.Overrides.ps1
                                               │ 3. translate output lines to ##vso
                                               └ 4. publish GITHUB_OUTPUT/ENV as ADO variables + job state

src/Initialize-AlGoAdo.ps1 downloads microsoft/AL-Go-Actions@<version> once per agent
(cached in Agent.ToolsDirectory), appends a one-line hook to AL-Go-Helper.ps1 and copies
the override + REST modules next to it.
```

### Concept mapping

| AL-Go (GitHub)                     | AL-Go4ADO                                                                 |
|------------------------------------|---------------------------------------------------------------------------|
| `runs-on` / `githubRunner`         | `pool` template parameters (`initPool`, `buildPool`, `deployPool`)       |
| `shell` / `githubRunnerShell`      | `shell` template parameter (`powershell` or `pwsh`)                       |
| `GITHUB_RUN_NUMBER`                | `$[counter(...)]` per pipeline (`AL_GO_RUN_NUMBER`)                        |
| Workflow name (conditional settings)| `workflowName` template parameter (`CI/CD`, `Pull Request Handler`, …)   |
| `ALGoOrgSettings` / `ALGoRepoSettings` variables | same-named pipeline variables (e.g. from a variable group)  |
| GitHub release                     | CI/CD build tagged `AL-Go-Release:<tag>` + git tag + retention lease      |
| Last known good build              | latest successful build tagged `AL-Go-CICD` on the branch                 |
| GitHub environment + approvals     | ADO Environment (`deployment` job) + `DeployTo<env>` AL-Go setting        |
| `github_token`                     | `System.AccessToken`                                                      |
| PR created by workflow             | ADO pull request created via REST (optional auto-complete)                |

## 4. Phases and implementation steps

### Phase 1 — Core CI/CD (implemented)
1. **Repo scaffold** — `src/`, `templates/`, `samples/`, `tests/`, `docs/`.
2. **Bootstrap** `src/Initialize-AlGoAdo.ps1`
   - Download `microsoft/AL-Go-Actions` at `alGoVersion` (zip, `core.longpaths`-safe), or use a local/vendored path (offline self-hosted agents).
   - Cache per agent under `Agent.ToolsDirectory/microsoft/AL-Go-Actions/<version>` (layout preserved because `RunPipeline.ps1` derives the version from the path).
   - Inject hook into `AL-Go-Helper.ps1`; copy `AlGoAdo.Overrides.ps1` and `AlGoAdo.Rest.psm1`.
   - Set `ALGO_ACTIONS_PATH` job variable.
3. **Shim module** `src/AlGoAdo.Shim.psm1` (pure, unit-tested)
   - `Get-AlGoGitHubEnvironment` — ADO predefined variables → `GITHUB_*`.
   - `New-AlGoEventFile` — synthetic `GITHUB_EVENT_PATH` payload.
   - `ConvertTo-AdoLogLine` — workflow commands → ADO logging commands.
   - `Read-GitHubFileCommand` — parses `name=value` and `name<<EOF` formats.
   - Job state (`Agent.TempDirectory/al-go-ado/state.json`) so `GITHUB_ENV` survives between steps with exact casing.
4. **Action runner** `src/Invoke-AlGoAdoAction.ps1` + child
   - Resolve action script, map `ALGO_INPUT_*` → script parameters (type-aware: bool/switch/int).
   - Default `token`, `baseFolder`, `actor`, etc.
   - Run in child process of the same shell; stream + translate output; propagate exit code.
   - Publish outputs as `isOutput=true` variables, secret-looking values as `issecret=true`.
5. **Overrides** `src/AlGoAdo.Overrides.ps1` on ADO REST (`src/AlGoAdo.Rest.psm1`)
   - Artifacts & runs: `FindLatestSuccessfulCICDRun`, `GetArtifacts`, `GetArtifactsFromWorkflowRun`, `DownloadArtifact`.
   - Releases: `GetReleases`, `GetLatestRelease`, `DownloadRelease`.
   - Dependencies: `GetDependencies` (thisBuild / latestBuild / release, ADO repos; GitHub repos fall back to upstream).
   - Environments: `GetGitHubEnvironments`, `Get-BranchesFromPolicy`, `IsGitHubPagesAvailable`.
   - Git: `CloneIntoNewFolder`, `CommitFromNewFolder` (push + ADO PR, auto-complete).
   - `TestRunnerPrerequisites` (no `gh` warning).
6. **Templates**
   - `steps/setup.yml`, `steps/action.yml`, `steps/publish-artifacts.yml`.
   - `jobs/initialization.yml` (ReadSettings, DetermineProjectsToBuild → ADO matrices).
   - `jobs/build.yml` (full `_BuildALGoProject` equivalent: settings, secrets, artifact URL, dependencies, previous release, compile, RunPipeline, RunTests, Sign, artifacts, test analysis + `PublishTestResults@2`, cleanup).
   - `stages/deploy.yml` (determine environments, deployment job per ADO environment, Deploy action).
   - `pipelines/cicd.yml`, `pipelines/pull-request.yml`, `pipelines/test-next.yml`.
7. **Samples** — Per Tenant Extension consumer repo with pipeline YAML + settings.
8. **Tests** — Pester tests for the shim (env mapping, command translation, file-command parsing, matrix conversion).

### Phase 2 — Repo maintenance workflows (implemented)
9. `pipelines/create-release.yml` — tag a CI/CD run as release, git tag, retention lease, optional release branch, optional version increment PR.
10. `pipelines/increment-version-number.yml`, `pipelines/create-app.yml` (app/test app/performance test app) using the git/PR overrides.
11. `pipelines/publish-to-environment.yml` — manual deploy of `current`/`latest`/`<version>` artifacts.

### Phase 3 — Delivery and code analysis (implemented)
12. `jobs/deliver.yml`: AL-Go's two-pass delivery target detection in Initialization, one Deliver job per target
    (NuGet, Storage, AppSource, custom). `nuGetFeedUrl` delivers to Azure Artifacts with `System.AccessToken`.
    `jobs/code-analysis.yml`: error logs → SARIF (ProcessALCodeAnalysisLogs) → build summary,
    `CodeAnalysisLogs` artifact, optional Advanced Security.

### Phase 4 — Backlog
13. Incremental builds end-to-end validation (overrides exist; needs real-world testing).
14. Power Platform solutions, ALDoc reference documentation (Azure Static Web Apps instead of GitHub Pages).
15. Pipeline that checks for a newer AL-Go4ADO / AL-Go version and opens a PR bumping `ref`/`alGoVersion`.
16. End-to-end test project in an ADO organization (smoke test pipeline per release of this repo).

## 5. Validation status

| Check                                                                 | Status |
|-----------------------------------------------------------------------|--------|
| Unit tests (`tests/*.Tests.ps1`, 46 tests) on PowerShell 7 and Windows PowerShell 5.1 | passing |
| Smoke test with real AL-Go `v10.0` actions in a simulated agent (WorkflowInitialize, ReadSettings, DetermineProjectsToBuild, build matrix, DetermineBuildProject, ReadSecrets, CalculateArtifactNames) on both shells | passing |
| Overrides replace the GitHub implementations (script scope and from other modules) | verified |
| YAML syntax of all templates and samples                              | verified |
| **First run in a real Azure DevOps organization** (template expansion, matrices, artifacts, container build, deploy, release) | **open — next step** |

Next steps:
1. Import the repo into an ADO org, create the sample PTE repo with one app, run CI/CD on a hosted agent with `useCompilerFolder`.
2. Run on a self-hosted agent with Docker (container build + tests).
3. Two-project repo with a dependency (build depth 2, `thisBuild` dependency download).
4. CreateRelease → second CI/CD run (DownloadPreviousRelease) → PublishToEnvironment.
5. IncrementVersionNumber (PR creation).

## 6. Risks / constraints
- **Upstream drift**: overrides depend on function signatures in the pinned AL-Go version. Mitigated by pinning `alGoVersion` and the tests; bump deliberately.
- **Secrets** in ADO must be mapped explicitly into env; the `secretNames` parameter lists the names to map (unknown names resolve to nothing, not errors).
- **Build service permissions**: releases/PRs need the project's *Build Service* identity to have *Contribute*, *Create tag*, *Contribute to pull requests* on the repo and *Edit build quality* / *Manage builds* on the pipeline.
- **Re-running failed jobs** re-publishes artifacts with the same name; the publish step is `continueOnError` aware but a full re-run is recommended.
- **Hosted agents**: Windows containers work on `windows-latest`, but builds are faster with `useCompilerFolder: true` (+ `doNotRunTests` or a self-hosted agent for tests).
