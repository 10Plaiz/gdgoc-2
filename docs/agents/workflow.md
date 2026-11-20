# Workflow

The process every agent follows in this repo, whether it's Claude Code, Codex, Antigravity, Gemini CLI, Cursor, Copilot or any other. It is built on [Matt Pocock's skills](https://github.com/mattpocock/skills), which are committed to the repo.

## Using the skills

The skills live in two identical copies:

- `.agents/skills/` is read by Codex, Antigravity, Gemini CLI, Cursor and Copilot.
- `.claude/skills/` is read by Claude Code.

To run a skill:

- **Your agent supports skills:** invoke it by name, for example `/grill-with-docs` in Claude Code, or "use the grill-with-docs skill".
- **Your agent doesn't support skills:** open `.agents/skills/<name>/SKILL.md` and follow it as instructions. When a skill says "call the Skill tool with X", open X's `SKILL.md` the same way.
- **Unsure which skill fits:** open `ask-matt`. It maps every skill to the situation it's for.

The skills are pinned in `skills-lock.json`. Update them with `npx skills update -p`, and commit the changes to both folders. `docs/agents/` is already configured, so `setup-matt-pocock-skills` only needs to be re-run to switch issue trackers.

## Step 0: Review GitHub (required, every session)

Before doing any work, run this and summarise the result for the user:

```bash
git remote -v
git fetch --all --prune
git status -sb
git log --oneline --graph --all -15
gh pr list -R RedzerRiley/gdgoc-website-2526 --state open
gh run list -R RedzerRiley/gdgoc-website-2526 --limit 5
gh api repos/RedzerRiley/gdgoc-website-2526 -q .has_issues
```

Report:

- the current branch, and how far ahead or behind it is compared with the canonical `dev`;
- open PRs on the canonical repo;
- recent CI results;
- whether issues are turned on (see [`issue-tracker.md`](issue-tracker.md)).

**This step reports only.** Pull, rebase, push or reset only when the user asks.

The step is done when the user has seen the summary.

## Step 1: Pick the lane

Choose the lane by the size of the work:

| Work | Lane |
| --- | --- |
| Trivial: a typo, copy edit or one-line style fix | Implement, then **Verify**, then **Ship** |
| Fits in one session | `grill-with-docs`, then `implement` in the same context, then **Verify** and **Ship** |
| Needs several sessions | the **Full flow** below |
| Something is broken | `diagnosing-bugs` (a red reproduction first, then the fix and a regression test), then **Ship**, then `retro` |
| A raw bug report or request someone else filed | `triage` until it's labelled `ready for AI`, then `implement` |

When the size is unclear, ask the user.

## Full flow (multi-session builds)

1. **`grill-with-docs`** interviews the user until every decision is settled. It records terms in `GLOSSARY.md` and decisions in `docs/adr/` as it goes.
   - If a question can only be settled by running code, use `handoff`, then `prototype` in a fresh session, then `handoff` back.
2. **`to-spec`** turns the conversation into a spec in the issue tracker.
3. **`to-tickets`** splits the spec into tracer-bullet tickets, each listing what blocks it.
   - Keep steps 1–3 in **one unbroken context window**.
4. **`implement`** works one ticket per fresh context, starting with tickets that have no open blockers. Each ticket is driven test-first with `tdd`, then checked with `code-review`.
   - Alternatively, `implement-spec` runs the whole ticket graph in one go.
5. **Verify**, then **Ship**.
6. **`retro`** runs in the same session, before clearing. It turns mistakes into automated checks or written standards.

## Branch, verify, ship

**Branch.** Base every branch on the canonical `dev`. The remote's name varies: it's `upstream` in a fork and `origin` in a direct clone.

```bash
git switch -c <type>/<short-slug> upstream/dev
```

`<type>` is one of `feat`, `fix`, `ui`, `chore` or `docs`.

**Verify.** Run these inside `gdgoc/`. Both must pass:

- `npm run lint`
- `npm run build`

There is no test runner yet. The first ticket on the backlog is **"Set up Vitest + React Testing Library"**. Until it lands, `tdd` steps fall back to Verify. Once it lands, add `npm test` to this list.

**Ship.** First, run the privacy check in `AGENTS.md` → *Privacy and safety*: no secrets and no real personal data in the diff. Then push to your fork and open a PR against the canonical `dev`:

```bash
gh pr create -R RedzerRiley/gdgoc-website-2526 --base dev --head <your-user>:<branch>
```

The `pr` skill shapes the PR body. Maintainers promote `dev` to `main`.

## Origin

This workflow is the process the repo was set up with on 2026-11-19:

1. Reviewed GitHub (origin and upstream).
2. Ran `setup-matt-pocock-skills` to configure the tracker, labels and domain docs.
3. Wrote `AGENTS.md`.
4. Used `ask-matt` to map the skills, then `grilling` to settle the decisions below.

| Decision | Choice |
| --- | --- |
| How agents get the skills | Committed to the repo (`.agents/skills/` + `.claude/skills/`), pinned in `skills-lock.json` |
| Which skills are included | 17 core workflow skills, not the whole set |
| Where the workflow is written | A short summary in `AGENTS.md`, the full version in this file |
| Where tickets go | Local `.scratch/` until upstream issues are turned on, then GitHub issues on the canonical repo |
| Testing | Vitest + React Testing Library is the first ticket; lint + build are the check until then |
| Branching | Base on the canonical `dev`, open PRs to `dev` |
| Step 0 (review GitHub) | Required every session, report only |
| Small changes | A fast lane: spec and tickets only for multi-session builds |

To change one of these decisions, update this table and the matching section in the same PR.
