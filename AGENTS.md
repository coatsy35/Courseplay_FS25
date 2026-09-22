# Project preferences

- Use concise British English.
- After each fix or change, run release checks and provide the new numbered test ZIP with a direct link. If checks fail, fix them before packaging.
- Keep the live `FS25_Courseplay.zip` separate from test builds. Retain the test ZIP filename and in-game identity between numbered builds.
- Use `docs/implement-profiles.md` for Implement Profiles packaging. For the unloader-coordinator branch, use `dist/unloader-coordinator/FS25_Courseplay_UnloaderCoordinatorTest.zip` and the in-game title `CoursePlay - Unloader Coordinator Test`.

# Subagent workflow

- Handle simple, tightly scoped tasks directly. Do not spawn subagents solely because they are available.
- For a task with independent investigation that would materially improve the result, use at most two subagents. Prefer read-only work such as a timestamped log trace, screenshot/geometry inspection, or review of the relevant code and regression coverage.
- Give each subagent a narrow question, the relevant file paths and time window, and only the context it needs. Request a short conclusion with supporting log lines or code locations. Do not pass the full conversation or an entire log when a focused excerpt will do.
- Choose the least costly suitable model and reasoning effort when available: use a fast model for narrow searches and a stronger model for ambiguous code or geometry analysis. Avoid high reasoning effort by default; raise it only when the task warrants it. Do not add an agent for work that cannot proceed independently.
- The lead agent owns implementation, integration, release checks and the test ZIP. Avoid concurrent edits to the same files. Cross-check subagent findings against the original log, screenshots and code before changing behaviour; reject unsupported explanations and request a targeted recheck only when evidence is missing.
- Keep the final answer focused on the cause, change, checks and remaining in-game validation. Subagents can reduce main-thread noise but may increase total token use.
