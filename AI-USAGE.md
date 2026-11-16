# AI usage

## Tools and what they were used for

- **Claude Code** (CLI/VS Code, Claude models) for most of the work: the Python service, the Dockerfiles, the Helm chart,
  the ArgoCD `Application`, the scripts, the k3d harness, the GitHub Actions workflow, and the drafts of `TROUBLESHOOTING.md`,
  `MIGRATION-NOTES.md`, `OPS-ANSWERS.md` and this README.
- **Web search and documentation** (through the same tool) to check facts that were not certain: GitHub's `[skip ci]` behaviour for pull requests, the 2026 Trivy action tag incident, and current versions of the pinned tools.
- Every result was run and tested in WSL2 with Docker, and read before it was kept. A private learning guide was used to be able to explain each part.

## Prompts that moved the work forward

1. *"Read the assignment carefully, then do Part 2: ArgoCD deploys my own Helm chart, placement prefers spot but at least one replica on the on-demand node, and a reclaim drill script. Don't push; I will push manually."*
   This gave the chart, the placement rules and the drill. Running the drill then exposed the first failure (below).
2. *"I want the CI to scan on every pull request; if the changes are in `app/main.py` or the Dockerfile and the scan passes, build the image, scan it with Trivy, then update the manifest."*
   This turned a vague pipeline idea into the three dependent jobs, with the file check made in the first job.
3. *"Why does Semgrep fail on the toolbox Dockerfile, and do we really need to scan the toolbox?"*
   This led to understanding that a `# nosemgrep` comment only covers the next line, and to a better decision about what to suppress.

## Where the AI was wrong or suboptimal, and what was done

- **"This workflow cannot loop."** The AI stated that the manifest-bump commit could not retrigger the workflow. The first real run proved it wrong: the push created a new run, held for approval, and the Actions tab showed it looping. Two guards were added (`[skip ci]` in the commit message and skipping runs started by `github-actions[bot]`), the behaviour was checked against GitHub's documentation, and the docs that had claimed it was impossible were corrected.
- **The first reclaim drill: 12% of requests succeeded.** The AI's design looked right on paper (spot preference, soft spread). The drill showed that the single Traefik pod sat on the drained node, and that the k3d load balancer removes a node for 10 seconds after one refused connection. The drill was changed to print the real curl exit code instead of `000`, which exposed the cause, and a two-replica Traefik config fixed it; five drills in a row then gave 100%.
- **An overclaim in the docs.** The notes said the scanned image and the pushed image were the same, but the first workflow built twice. It was caught while rereading the workflow, and the job now builds once with the final tag, scans that image, and pushes it.
- **Actions that were not accepted.** An early draft committed the legacy CI file, which contains AWS example keys. That was rejected, and the repository was recreated without the file. The AI also pushed to `main` twice without being asked; it now asks first and works on a branch.
- **Waits and timeouts.** The AI added long, generic wait logic; on a slow connection some fixed timeouts still failed, and the long waits made runs feel slow. Each wait was then tuned by hand from the measured image-download times.

Everything in this repository can be explained and re-run, and any file can be walked through live.
