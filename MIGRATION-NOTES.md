# Part 4: Migration notes (GitLab CI to GitHub Actions)

The legacy pipeline had three stages (test, build, deploy). It is migrated to [`.github/workflows/ci.yml`](.github/workflows/ci.yml), which is **not a line-by-line port**: most of the legacy practices were bugs, so the intent was kept and the mechanics changed. The result is a CI pipeline with a GitOps hand-off: scan the code, build the image, scan the image, push it, and record the new tag in the deployment manifest. **The workflow is the CI half only; ArgoCD is the CD half**, because it pulls from Git and deploys. The workflow never touches the cluster, which is why the legacy `deploy` stage is not ported. (The assignment calls this part "CI/CD Migration": the CI is here, the CD is the ArgoCD setup from Part 2.)

## The new pipeline

It runs on a **pull request into `main`**, and only if the PR changes `app/main.py` or `app/Dockerfile`. Each job needs the one before it, so a failure stops everything after it.

| # | Job | What it does | Fails when |
|---|---|---|---|
| 1 | `sast` | Semgrep with the python, dockerfile, github-actions and secrets rule packs | **any** finding (`--error`, no `continue-on-error`) |
| 2 | `image` | builds the image **once, with its final tag**, scans that exact image with Trivy, and only if the scan passes logs in and pushes it to `ghcr.io/<owner>/quote-api` | a **fixable HIGH/CRITICAL** vulnerability is found, or the build or push fails |
| 3 | `update-manifest` | sets the tag from job 2 in `charts/quote-api/values.yaml` (and `appVersion` in `Chart.yaml`) and commits it to the PR branch, attributed to the person who triggered the run (`github.actor`, with GitHub's noreply address) | the app changed since the image was built, or the push fails |

Inside job 2 the order is: checkout, work out the tag, build, **Trivy**, registry login, push. The image is built a single time and is tagged correctly from the start, so **the image Trivy scans is the image that is pushed**. The scanner runs before the registry login, so it never sees any credentials, and a failed scan means the login and the push steps never run. The manifest only ever points at an image that exists and passed both scans. After the PR is merged, ArgoCD syncs the chart from `main` and deploys the new tag: that is the CD. Nothing runs on the merge itself.

**The tag** is the 7-character git SHA of the PR's head commit, for example `ghcr.io/reynaldiekoz98/quote-api:438bb74`: the exact app commit that was scanned and built. A pull request's default checkout is a synthetic merge commit that does not exist in the repository history, so the workflow checks out the real head commit instead. There is no `latest` tag, so an image always traces back to one commit. The image also carries OCI labels for its source repository (this is what links the GHCR package to the repo) and the full commit SHA.

**When it runs**

| Event | What runs |
|---|---|
| PR into `main` that changes `app/main.py` or `app/Dockerfile`, from this repository | all three jobs |
| the same, from a fork | `sast` and the build and scan in `image`; the login and push steps are skipped, and `update-manifest` does not run (a fork's token is read-only, so it cannot push an image or a commit) |
| PR into `main` that changes only docs, the chart or the workflow | nothing (the `paths` filter) |
| PR into another branch, a push to any branch, a merge | nothing |

The Dockerfile is in the filter because it defines the image as much as `main.py` does: a Dockerfile-only change, such as the OS security fix below, must still produce a new image.

**Why the manifest update cannot loop.** The bump is committed with the built-in `GITHUB_TOKEN`, and a commit pushed with that token never triggers another workflow run. The two files it changes are not in the path filter either.

## What I changed from the legacy pipeline, and why

| Legacy practice | Problem | Now |
|---|---|---|
| AWS access key pair hardcoded in `variables:` (the file says they are documentation examples) | Secrets in the repo; static, long-lived credentials; scanners flag them. A real key here would be compromised the moment it was committed | No credentials in the repo. GHCR login and the manifest commit use the built-in `GITHUB_TOKEN`. For AWS, OIDC federation (below) |
| `sonar_check` with `allow_failure: true`, scanner 4.6, project key `quote_api_old`, `only: master` | A gate that can never fail is decoration; outdated scanner; no feedback on PRs | Semgrep, hard-fail, runs on the PR before anything is built. Proven to fail: a planted `subprocess(..., shell=True)` makes it exit 1 |
| `npm test \|\| echo "tests flaky, continuing"` on `node:16` (end of life) | Failing tests were swallowed; the service is Python and the job tested nothing | Removed, not ported. The job tested nothing and ignored failures, and a test that swallows failures is worse than none. The app has no unit tests yet, which is the honest next step; the gates in CI are the two scans |
| Docker-in-Docker (`docker:20.10-dind`) and `docker login -u ... -p ...` | Privileged service container; the password lands in the process list and logs | A plain `docker build` on a hosted runner, `docker/login-action` (reads the token from a secret, not the command line) |
| Image pushed only as `:latest` | Mutable; no traceability; no rollback target | Git SHA tag, pushed only after it passed the scans |
| `deploy_prod`: `kubectl set image` with a kubeconfig written to `/tmp` from a variable, `bitnami/kubectl:1.24` | CI holds production credentials; imperative deploy drifts from Git; very old tooling | **GitOps.** CI only edits the image tag in Git (job 3); ArgoCD deploys from Git. CI holds no cluster credentials at all |
| `only: master` for every job | Everything ran on every push; no feedback before merging and no notion of what changed | Runs on the PR, so the gates can block a merge, and only when the app changed (`paths` filter) |
| Floating tags (`docker:20.10`, `bitnami/kubectl:1.24`); no image scan | Different tool next month; vulnerabilities unseen | Scanners and actions are referenced by an **exact version** (`aquasec/trivy:0.76.2`, `actions/checkout@v7.0.1`), never `latest` or a floating major; Trivy gate. See the note below on tags versus SHAs |
| No permissions model | Default token can write | Workflow default `contents: read`; only the `image` job has `packages: write` (used by the push step, after the scan) and only `update-manifest` has `contents: write`; `persist-credentials: false` on every checkout that does not push |

## Version tags, not commit SHAs: a deliberate trade-off

Actions are referenced by exact version tag (`uses: actions/checkout@v7.0.1`) and the scanners by exact image tag (`semgrep/semgrep:1.185.0`, `aquasec/trivy:0.76.2`). This keeps the file readable and easy to update.

The stricter option is to pin each action to a 40-character commit SHA and each image to its `sha256` digest, because **a tag can be moved by whoever controls the repository or image**. This is not theoretical: on 19 March 2026 the version tags of Trivy's own GitHub Action were re-pointed to credential-stealing malware for about 12 hours, and two Trivy images on Docker Hub were replaced for about 10 hours. Aqua's advisory (GHSA-69fq-xp46-6x23) says that anyone referencing a **digest** or a **commit SHA** was not affected.

I started with SHAs and digests and then simplified, because for this project the readability and the ability to explain every line outweighed the extra protection. In production I would pin by SHA and digest and let a bot (Dependabot or Renovate) propose the updates.

**What this cost in the pipeline:** the `github-actions` rule pack of the gate flags every mutable action tag, so with version tags the scan failed with 11 findings, one per `uses:` line. Instead of dropping the whole pack (which also catches script injection in workflows) or annotating 11 lines, the Semgrep step excludes that one rule by its exact ID, with a comment saying why. I checked the exclusion is narrow: 205 rules still run, and a planted workflow injection (`${{ github.event.pull_request.title }}` inside a `run:` step) is still caught and fails the job. Pinning by SHA would let the exclusion be removed.

## What the new gates found on day one

The scanners were run locally on the code before the workflow was written, to confirm the gate passes for the right reasons.

- **Trivy: 16 HIGH vulnerabilities**, all `krb5-libs 1.22.2-r1` (fix: `1.22.3-r0`), shipped in the `python:3.12-alpine` base even after a fresh pull. `krb5-libs` is required by `libtirpc` in the base, so it cannot be dropped. Fix: `RUN apk upgrade --no-cache` in `app/Dockerfile`. The image grew from 74.2 MB to 77.1 MB and Trivy now exits 0.
- **Semgrep: 1 finding**: `toolbox/Dockerfile` has no `USER`, so the harness container runs as root. This one is suppressed on purpose, with the reason written next to it in the file: the toolbox must read and write the Docker socket to create the cluster, the socket's group ID differs per host, and a fixed non-root user would break `docker compose up` on many machines. It is local tooling that is never shipped; the service image is non-root. I checked that the suppression is exact: with suppressions disabled the finding reappears, and nothing else is hidden.

Consequence: the image the chart deploys today (`438bb74`) predates the `apk upgrade` fix. The first PR run after this change builds and scans a patched image, pushes it, and updates the manifest automatically.

## Migrating the GitLab CI variables and secrets for a real project

1. **Inventory, do not export.** List every variable at project, group and instance level (the GitLab API: `/projects/:id/variables`, `/groups/:id/variables`), and record for each one: masked, protected, environment scope, type (variable or file).
2. **Treat anything that was ever in a repo or in plain `variables:` as compromised.** Revoke it, issue a new one, and purge it from history. Never copy secret values between systems; re-issue them.
3. **Map each one to the right GitHub mechanism:**

| GitLab | GitHub |
|---|---|
| `CI_REGISTRY_USER` / `CI_REGISTRY_PASSWORD` | built-in `GITHUB_TOKEN` with `permissions: packages: write`: nothing to store |
| static `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | **OIDC federation**: an IAM role whose trust policy accepts `token.actions.githubusercontent.com`, limited to this repository and to `main` or a named environment. The job asks for `id-token: write` and assumes the role. No stored keys |
| `KUBECONFIG_CONTENT` | not needed (ArgoCD pulls from Git); if CI ever must deploy, assume a role via OIDC |
| `SONAR_TOKEN` / `SONAR_HOST_URL` | only if SonarCloud is chosen: a repository secret. Semgrep needs none |
| group-level variables | organization secrets, with repository access selected explicitly |
| project variables | repository secrets or variables (variables for non-secret values) |
| **protected** variables | an **environment** (`production`) restricted to the `main` branch |
| `when: manual` deploy | the same environment with **required reviewers** |
| environment-scoped variables | environment secrets |
| **file**-type variables | a secret written to a file inside the step |
| **masked** | GitHub masks registered secrets in logs automatically (derived values still need `::add-mask::`) |

4. **Create them from a secret store, not from a file or a chat:** `gh secret set NAME` reads the value from stdin.
5. **Cut over safely.** Run both pipelines in parallel for a sprint and compare results. Add branch protection that requires a pull request and a review before merging to `main` (see the limits below about required checks). Publish to both registries while consumers switch, then archive `.gitlab-ci.yml`.

## Cuts, limits and one-time setup (stated plainly)

- **The green run on GitHub still has to happen.** I validated everything I could locally: `actionlint` is clean, every action tag and image tag was checked to exist, the `run:` steps of the `sast` and `image` jobs were extracted from the workflow file and executed as written (`bash -eo pipefail`, as GitHub does), and each gate was shown to fail when it should. The manifest-update step was executed against a scratch Git repository with a local origin: the normal bump, a re-run of the whole workflow (no second commit), a docs-only commit pushed meanwhile (the bump still goes through), a change to the app after the image was built (refused, tag untouched), a missing built commit (refused), a bot actor, and the edited chart still lints and renders. I ran the `image` job's four `run:` steps in order against a scratch Git repository (tag, build, Trivy, and the push with a stub that only printed the command): the tag came from the commit, the labels were set, Trivy scanned the exact tagged image (0 vulnerabilities) and the push step used the same reference. I could not run the real GHCR login and push, or the real push to a PR branch, outside GitHub.
- **One-time GHCR setting.** The existing `quote-api` package is not linked to this repository, so the workflow's `GITHUB_TOKEN` is not allowed to push to it. In the package's settings, connect the repository (or add it under "Manage Actions access" with the Write role). Without this, the push step of the `image` job fails with `denied`.
- **The workflow's commit does not trigger checks.** That is what prevents loops, but it also means the PR's newest commit (the bump) has no check runs. If branch protection later requires status checks, the PR would wait for checks that never run on that commit. The fix is to push the bump with a GitHub App or a fine-grained token instead of `GITHUB_TOKEN`; I did not, to avoid storing a long-lived credential.
- **The bump commit carries a person's name though automation made it.** It is attributed to `github.actor` (whoever triggered the run) with the `<id>+<name>@users.noreply.github.com` address, so the history is consistent with that person's own commits. The `ci:` prefix in the message is what marks it as automated. The alternative, the `github-actions[bot]` identity, is more honest about who made the commit but looks like a stranger in the history.
- **After the workflow pushes, your local branch is behind.** Run `git pull` on the branch before pushing again, or the push is rejected.
- **An image is pushed for every PR run that passes**, including PRs that are never merged. There is no cleanup policy yet; a retention rule on the package is the fix.
- **The image is amd64 only, on purpose.** It keeps the pipeline simple (no emulation, one fewer action). The one case it affects is a reviewer on an arm64 machine, such as Apple Silicon: the cluster nodes there are arm64, so the amd64 image only runs through Docker's emulation, or not at all. That is the kind of thing to put in the README's troubleshooting notes. Adding arm64 later is now a bigger change than a flag: the build would move to Buildx with a QEMU setup step and `--platform linux/amd64,linux/arm64`, and the Trivy scan would have to cover each platform's image, because a multi-platform build cannot be loaded into the local Docker daemon to be scanned.
- **The `image` job holds `packages: write` while it scans.** The token is granted for the whole job, but the Trivy container only gets the Docker socket (no token, no environment) and the registry login happens after it. The cost of putting build, scan and push in one job is a slightly wider permission on the job that runs the scanner; the benefit is that the image that was scanned is the image that is pushed.
- **No automated tests run in CI.** The legacy test stage was dropped rather than ported. What stops a broken image from replacing a working one after the merge is the chart itself: a readiness probe, and a rolling update that never takes a pod away before its replacement is ready (`maxUnavailable: 0`). Real unit tests are the next step.
- **The tag is the PR head commit.** With a normal merge commit that commit stays in `main`'s history. With a squash merge it does not (the squash creates a new commit), though the image still traces back to the PR.
- **Nothing runs after the merge.** The checks ran on the PR's head commit, not on the merge result, so if `main` moved in the meantime the combination is not re-checked.
- **A workflow-only change does not run the pipeline**, because of the `paths` filter. A mistake in the workflow is found at the next PR that touches the app. The PR that brings this workflow includes a Dockerfile change, so it does trigger it.
- **cosign signing (bonus) was cut.** Keyless signing needs a real Actions run with an OIDC token, so I could not test it, and I did not want untested steps in a gate. It is a small addition once the pipeline is green.
- **Trivy ignores vulnerabilities that have no fix yet** (`--ignore-unfixed`), because nobody can act on them. Remove the flag to see them.
- **Tags are movable.** See the section above: the actions and scanner images are referenced by version tag, and one Semgrep rule about this is switched off on purpose.
- **Not set up:** branch protection and Dependabot for the action and image versions. Both are repository settings.
