# AI usage

## Tools and what I used them for

- **Claude Code** (CLI/VS Code, Claude models) for most of the work: the Python service, the Dockerfiles, the Helm chart,
  the ArgoCD `Application`, the scripts, the k3d harness, the GitHub Actions workflow, and the drafts of `TROUBLESHOOTING.md`,
  `MIGRATION-NOTES.md`, `OPS-ANSWERS.md` and this README.
- **Web search and documentation** (through the same tool) to check facts I was not sure of: GitHub's `[skip ci]` behaviour for pull requests, the 2026 Trivy action tag incident, and current versions of the tools I pin.
- I ran, read and tested the results myself in WSL2 with Docker. I kept a private learning guide to be able to explain each part.

## Prompts that moved me forward

1. *"Read the assignment carefully, then do Part 2: ArgoCD deploys my own Helm chart, placement prefers spot but at least one replica on the on-demand node, and a reclaim drill script. Don't push; I will push manually."*
   This gave the chart, the placement rules and the drill. I then ran the drill myself and found the first failure (below).
2. *"I want the CI to scan on every pull request; if the changes are in `app/main.py` or the Dockerfile and the scan passes, build the image, scan it with Trivy, then update the manifest."*
   This turned a vague pipeline idea into the three dependent jobs, with the file check made in the first job.
3. *"Why does Semgrep fail on the toolbox Dockerfile, and do we really need to scan the toolbox?"*
   This led to understanding that a `# nosemgrep` comment only covers the next line, and to a better decision about what to suppress.

## Where the AI was wrong or suboptimal, and what I did

- **"This workflow cannot loop."** The AI told me the manifest-bump commit could not retrigger the workflow. The first real run proved it wrong: the push created a new run, held for approval, and I saw it looping in the Actions tab. We added two guards (`[skip ci]` in the commit message and skipping runs started by `github-actions[bot]`), checked the behaviour against GitHub's documentation, and rewrote the docs that had claimed it was impossible.
- **The first reclaim drill: 12% of requests succeeded.** The AI's design looked right on paper (spot preference, soft spread). The drill showed that the single Traefik pod sat on the drained node, and that the k3d load balancer removes a node for 10 seconds after one refused connection. The drill was changed to print the real curl exit code instead of `000`, which exposed the cause, and we added a two-replica Traefik config; five drills then gave 100%.
- **An overclaim in the docs.** The notes said the scanned image and the pushed image were the same, but the first workflow built twice. I caught it while rereading the workflow, and we changed it to build once with the final tag, scan that image, and push it.
- **Secrets and actions that I did not accept.** An early draft included the legacy CI file with AWS example keys in the repository; I objected, the repo was deleted and recreated without it. The AI also pushed to `main` twice without being asked; I told it to ask first, and it now works on a branch.
- **Waits and timeouts.** The AI added long, generic wait logic; on my slow connection some fixed timeouts still failed, and the long waits made runs feel slow. I tuned each wait by hand from the measured image-download times.

Everything in this repository I can explain and re-run; I am happy to walk through any file live.
