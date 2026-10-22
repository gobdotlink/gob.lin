# Agent instructions

- Do not add docs to the repository: no reports, plans, reviews, triage, evidence, investigation notes or summaries. Edit existing docs only when your change makes them wrong, or when asked.
- Put everything temporary (notes, scratch scripts, plans, logs, screenshots, review output) in `.context/` at the root of the worktree you are working in. It is gitignored; never force-add it.
- Never commit machine-specific details: absolute paths, usernames, private repository names, or agent and tool configuration. The same applies to commit messages and pull request descriptions.
- Follow `CONTRIBUTING.md`, and read `DESIGN.md` before changing anything a person sees.
