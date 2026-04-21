---
name: publish-github
description: Publish this project to GitHub using the agreed repo workflow
allowed-tools: Bash(git status:*), Bash(git remote:*), Bash(gh auth status), Bash(gh repo view:*), Bash(gh repo create:*), Bash(git add:*), Bash(git commit:*), Bash(git pull:*), Bash(git push:*), Bash(git log:*), Bash(git diff:*), Bash(ls:*)
argument-hint: [repo-name]
---

Publish this project to GitHub using the established workflow from this repository.

Use `$1` as the repository name if provided. If `$1` is empty, default to the current repository naming decision for this project.

Workflow:

1. Check publish readiness first:
   - `git status --short`
   - `git remote -v`
   - `gh auth status`
2. If the repository does not already exist on GitHub, create it as a public repository under the authenticated user's account.
3. Before committing, review the working tree:
   - inspect git status
   - inspect staged and unstaged diffs
   - inspect recent commit messages to match style
4. Stage only the intended project files, not secrets or unrelated local files.
5. Create a new commit with a concise message and the standard Claude co-author trailer.
6. If the remote has changes the local branch does not have, run `git pull origin main --allow-unrelated-histories` when needed and resolve the merge cleanly.
7. Push `main` to `origin`.
8. Report the final GitHub repository URL and whether push succeeded.

Important rules:
- Treat `.claude/settings.local.json` as local-only and do not commit it.
- Prefer the project repo name `dingjiai-installer` unless the user explicitly asks for another name.
- If GitHub authentication is missing, stop and tell the user to run `! gh auth login -w -h github.com`.
- If network access to GitHub fails, explain whether the failure happened during auth, repo creation, pull, or push.
- Do not create a PR in this workflow.
