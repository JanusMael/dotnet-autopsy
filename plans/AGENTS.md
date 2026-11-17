# AGENTS.md — `plans/`

Plans for multi-step work, one file each, named `NNNNN-slug.md`: five digits, numbered in order.

## Rules

| Rule | Why |
|---|---|
| A draft is revised in place until the developer approves it | Until then it is still being written |
| An approved plan is committed on its own, before the work it describes begins | The approval is then a commit that review can point at |
| An approved plan is never edited. Superseding it means a new number that references the old one | It records what was agreed; editing it rewrites that record |
| Drift from an approved plan is recorded in `PROGRESS.md`, not in the plan | The plan stays as approved; the work state carries what changed and why |
| An approved plan's links are specification, not navigation, and are left alone when they stop resolving | They say what the plan referred to when it was approved |

A plan's status line says whether it is a draft or approved.
