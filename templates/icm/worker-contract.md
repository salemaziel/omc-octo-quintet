# Worker Stage Contract: {{WORKER_NAME}}

One job: {{SUBTASK}}

## Role & Provider
- **Worker**: {{WORKER_NAME}}
- **Provider CLI**: {{PROVIDER}}
- **Assigned Role**: {{ROLE}}
- **Team Goal**: {{GOAL}}

## Recommended Skills & Disciplines
> **Advisory**: If available in your environment, invoke or reference these skills. If not installed or if external helper scripts are unavailable, embody the underlying methodology directly using standard repository tools.
{{RECOMMENDED_SKILLS}}

## Inputs
- **Working (this run)**: {{WORKING_INPUTS}}
- **Reference (stable)**: {{ROLE_FILE_PATH}}
- **Reference (stable)**: Repository architecture, conventions, and test commands

## Process
1. Internalize assigned role constraints from reference instructions.
2. Review the working inputs and target files.
3. Implement the assigned subtask strictly within target files.
4. Verify changes locally using test/build suites.
5. Summarize work completed into '{{OUTPUT_DIR}}/summary.md'.
6. Write 'done' to '{{STATUS_FILE}}'.

## Target Files & Boundaries
- **Target Files**: {{TARGET_FILES}}
- **Strict Constraint**: Never edit files outside your assignment scope without coordinator approval.

## Outputs
- Code modifications applied to workspace or worktree branch
- '{{OUTPUT_DIR}}/summary.md' (bulleted list of changes and test outcomes)
- '{{STATUS_FILE}}' (set to 'done')

## Human Check
Inspect git diff for assigned files and verify local test commands pass before claiming completion.
