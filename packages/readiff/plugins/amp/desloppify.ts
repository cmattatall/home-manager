import type { PluginAPI } from '@ampcode/plugin'

export const description = 'Loads readable-code and plain-English guidance on every turn and adds a desloppify command.'

const guidance = `Apply these preferences when writing or changing code, tests, comments, documentation, and replies. They do not expand the task's scope.

Readable code
- Assume humans need to read, review, and maintain the code without this conversation. Optimize for their understanding, not line count or cleverness.
- Prefer self-documenting code over explanatory comments. Use well-named variables that describe the values they hold, and blank lines to visually separate logical steps. Improve names and structure before adding a comment to explain confusing code.
- Do not write giant one-liners. Break dense conditions, nested comprehensions, chained operations, and shell pipelines into named intermediate values and explicit steps. Use branches and guard clauses to make decisions easy to follow. Keep simple expressions simple.
- Name functions for what they actually do. Put important type declarations before the implementation that uses them, following the language's conventions. If a file becomes hard to organize, split distinct responsibilities rather than scatter declarations or extract arbitrary fragments.
- Inspect existing types, helpers, and lifecycle owners before adding new ones. Adapt the source of truth when it can serve the consumers. Avoid duplicate models, derived flags stored as independent state, parallel lookup maps, and interfaces that merely project an existing interface's subset. A new abstraction must have a distinct responsibility that the existing design cannot clearly express.
- Keep public APIs narrow. Do not export implementation details just to test them. Keep configuration resolution, argument parsing, and process lifecycle separate when they have different owners. Use the framework's existing lifecycle and dependency mechanisms instead of building another one.
- Add validation and recovery for concrete failure modes at real boundaries. Do not pile on nil checks for required dependencies, speculative input handling, silent fallbacks, or compatibility scaffolding without a supported requirement. Retain security protections, required validation, and documented fallback behavior. Simplify the design before adding machinery around it.
- Give scripts explicit, named inputs when several arguments would otherwise be opaque or depend on hidden environment state. Prefer straightforward control flow over a clever parser or pipeline when it makes the operation easier to follow.

Comments, documentation, and replies
- Write plain technical English. Use familiar words and short sentences. Do not use semicolons to join English clauses. This does not restrict programming syntax or quoted source text.
- Comments and documentation should primarily explain WHY: non-obvious reasons, constraints, and operational purposes. Explanations of WHAT should be far rarer and always describe behavior, interfaces, or concepts that actually exist. Remove comments that repeat the code, but keep useful explanations.
- Comments must never describe what the code does NOT do. When removing behavior or functionality, remove its obsolete comments and documentation too. Do not replace deleted behavior with prose announcing that it no longer happens. Comments and documentation describe the current system, not the history of requests that produced it.
- READMEs are for humans, not agents. Explain the module's public interface and the actions humans must perform to use it. Cover the paradigms, concepts, shell commands, public APIs, and examples needed to interact with the module. Never include implementation details in a README. Put agent instructions in agent guidance files and internal implementation explanations alongside the code.
- Document each fact in one place. Keep examples that help someone use the interface. Remove repeated README paragraphs. PR descriptions explain the purpose and approach at a high level, not every edit.
- Keep commentary terse. State the result, material uncertainty, or decision that needs attention. Avoid inflated terminology, self-congratulation, and repeating the diff. When asked what command to type, give the command rather than executing it unless execution was also requested.

Tests and cleanup
- Use tests to protect behavior people rely on. Exercise meaningful failure cases and boundaries with readable inputs and independently derived expectations. Do not change production contracts merely to satisfy a mock.
- Keep temporary probes and development-loop checks out of the final change. If testing requires elaborate scaffolding or tests of tests, reconsider the design before adding more. Preserve meaningful regression coverage rather than treating simplicity as an excuse not to verify.
- Treat emphatic feedback as a concrete correction to apply throughout the current scope. Fix the cause, not just the quoted line. Do not turn an objection to one unnecessary check, comment, or abstraction into a blanket ban on all of them.`

const cleanupRequest = `Desloppify the current work: simplify its structure and make it read like a human wrote it, while preserving behavior and public contracts.

Use any scope I have explicitly named. Otherwise inspect this thread's changes, including its uncommitted edits and branch diff against the appropriate base. Do not assume every change in a shared checkout belongs to this thread. If the scope cannot be identified, ask for the target rather than sweeping the repository.

Read the surrounding code and relevant callers before editing. Apply the coding and writing preferences supplied by the plugin. Remove unnecessary concepts before polishing their syntax. Keep useful comments, safeguards, and regression tests. Do not introduce features, change supported behavior, or delete meaningful tests to make the patch smaller. Flag any simplification that would require a behavior change instead of silently making it.

Make the edits, then run the relevant formatter, checks, and existing tests. Review the final diff for accidental behavior changes and unrelated edits. Remove scratch probes. Report the meaningful simplifications and what was verified in a short response. Leave unrelated work and staging untouched. This command does not authorize committing, pushing, or deploying.`

export default function (amp: PluginAPI): void {
  // Every turn keeps the preferences available after compaction or reconnecting.
  amp.on('agent.start', () => ({
    message: { content: guidance, display: false },
  }))

  amp.registerCommand('desloppify', {
    category: 'code', title: 'desloppify', description: 'Simplify the current work without changing its behavior.',
  }, async (ctx) => {
    if (!ctx.thread) {
      await ctx.ui.notify('Start or open a thread before running desloppify.')
      return
    }
    await ctx.thread.appendUserMessage({ type: 'user-message', content: cleanupRequest })
  })
}
