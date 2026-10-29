/*
 * Derived from cmattatall/revdiff's Amp plugin; maintained here as readiff.
 * MIT License
 * Copyright (c) 2026 Umputun
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */
import type { PluginAPI, PluginCommandContext, PluginThread, ThreadMessageID } from '@ampcode/plugin'

import { createHash, randomBytes } from 'node:crypto'
import { lstat, mkdir, mkdtemp, realpath, rename, rm, writeFile } from 'node:fs/promises'
import { createServer, type Server, type ServerResponse } from 'node:http'
import { homedir } from 'node:os'
import { isAbsolute, join, relative } from 'node:path'

export const description = 'Readiff: receive editor review feedback, propose branch splits, and prepare and publish reviewable branches in the current Amp thread.'

const MAX_BODY = 1024 * 1024
const MAX_ID = 256

type ActivityState = 'idle' | 'running' | 'awaiting-approval' | 'error' | 'unknown'
type ActivitySnapshot = {
  version: 1; root: string; thread: string; sequence: number
  state: ActivityState; title: string; tool: string | null
  files_revision: number
}
type StreamClient = {
  response: ServerResponse; pending: string | null; heartbeat: NodeJS.Timeout
}
type Activity = {
  call(id: string, tool: string): void
  result(id: string, filesChanged: boolean): void
  subscribe(response: ServerResponse): void
  dispose(): void
}
type Connection = { server: Server; directory: string; descriptor: string; root: string; activity: Activity }
type Outcome = { content: string; result: Promise<Set<ThreadMessageID>>; confirmed: boolean }

const HEARTBEAT_MS = 15_000
const MAX_STREAM_BUFFER = 64 * 1024

const branchSplitGuidance = `Optimize for human reviewability, not diff size. There is no line-count cap.

Use any explicitly named scope. Otherwise identify this thread's work, including relevant uncommitted changes and commits relative to the appropriate base. Inspect repository guidance, Git state, and publication status. Do not assume all changes in a shared checkout belong to this task. Ask if ownership or the base is ambiguous.

Shape the stack around actual dependencies. Orthogonal changes may form independent branches based on the target branch or a shared prerequisite. Use a linear chain when each PR depends on the preceding PR. Each PR must be valid with its ancestors, without requiring descendants or sibling branches. Review its incremental diff against its parent, not the cumulative diff against the target branch.

Give every branch in the stack, including all branches based directly on the target, a common task-specific prefix so the branches are easy to search and filter. For example: auth-refresh/foundation, auth-refresh/api, and auth-refresh/ui. Keep the target branch's existing name, such as main.

PR descriptions must explain that PR's purpose, approach, and validation. They may describe the overarching goal and how this PR contributes to it, while distinguishing what this PR delivers from future work. Never mention that it is part of a PR stack, its position in the stack, or how large the stack is. Let gh stack supply the stack relationships in GitHub's UI.

Each PR should have one coherent purpose. Order by actual dependencies, not mandatory architectural layers. Put necessary, behavior-preserving preparatory refactors before the changes they enable and keep them separate from behavior changes. Do not add unrelated cleanup or force a split that makes the work harder to understand. One PR is acceptable when further splitting would be artificial.

Plan splits at the hunk level and identify intermediate versions when needed. File boundaries and existing commits are not mandatory PR boundaries. Keep tests, fixtures, documentation, and configuration with the behavior or contract they establish. Do not defer required tests to a final testing PR.

Early PRs may contain unused preparatory code when a later PR in this stack needs it, it can be meaningfully reviewed and tested now, and it has no unintended runtime effects or premature public exposure. Do not weaken checks, add dummy callers, or introduce speculative abstractions to make a boundary pass.

Show a table in dependency order with branch names, parent bases, proposed PR titles, and incremental diff sizes as +added / -deleted lines for every branch. Measure each slice against its own parent, including in-scope uncommitted and untracked content. Use Git diff statistics where measurable, label estimates explicitly, and report binary changes separately from line counts. Show the sum of incremental additions and deletions, counting each branch once rather than summing cumulative ancestor diffs. These counts describe review size, not a splitting limit.`

const branchSplitProposeRequest = `Propose how to split the current work into reviewable branches and PRs. This is a read-only planning request. Leave files, staging, branches, worktrees, and remote state unchanged. Do not create commits, register branches, push, or open PRs.

${branchSplitGuidance}

Explain the proposed boundaries and validation needed for each branch. Report assumptions, ownership ambiguities, and blockers. Distinguish planned checks from checks already run. Finish with the proposal only and wait for an execution request.`

const branchSplitPushRequest = `Split the current work into reviewable branches and publish the resulting PRs after explicit publication approval. Reuse a proposal already agreed in this thread, adjusting it only when the current work or validation requires it.

${branchSplitGuidance}

When the repository remote is hosted on GitHub, use gh stack to create and manage the stack. Inspect gh stack --help and the relevant subcommand help before use. If it is unavailable, report the blocker rather than substituting a manual GitHub PR workflow.

Split interleaved hunks and reconstruct intermediate versions as needed to implement the boundaries.

Preserve the intended final behavior and public contracts of the original work. Before restructuring, capture a recoverable snapshot of both content and staging, including staged, unstaged, and untracked changes. Preserve unrelated changes and their staging and keep existing published refs untouched. This command authorizes creating local branches and commits and restructuring only in-scope unpublished work. Pushing, creating or updating remote PRs, rewriting published history, deploying, or discarding work require separate explicit approval. If safe restructuring is blocked, return the proposed stack and the specific blocker.

At every proposed PR tip, run the applicable build/type checks, formatting checks, lint, and tests using only that PR and its ancestors. Repair invalid boundaries by moving related changes together or merging PRs, not by disabling checks. Report pre-existing failures and unavailable checks accurately. Compare the final combined change across all tips with the captured original, explain any differences, and verify preserved behavior.

Finish stack preparation in the user's active checkout. Temporary worktrees may be used for reconstruction and validation, but the final handoff must leave the active checkout on a stack tip with no duplicate in-scope changes. For a linear stack, use its top branch. For a branched stack, select one tip and report which in-scope work is on the other tips. Before switching, verify that every in-scope staged, unstaged, and untracked change is represented across the final stack branches. If preserving unrelated changes and their staging prevents switching safely, report the specific blocker.

Separate local preparation from publication. Local completion requires registered gh stack branches for GitHub repositories, validated incremental boundaries, and a reconciled active checkout. If publication approval is missing, finish local preparation and ask for approval to publish to the specific remote. Open PRs as ready for review unless the user explicitly requests draft PRs. Select submission options accordingly rather than relying on tool defaults. After publication approval, submit with gh stack and verify the remote PR bases, descriptions, and draft status. Correct any newly opened PR whose draft status differs from the requested state.

Report measured diff sizes for the completed branches in the table, validation results at each boundary, any blockers, and published PR links when available. Include the active branch, remaining staged, unstaged, and untracked changes and their ownership, and whether the stack is local or published.`

async function containsFeedback(thread: PluginThread, content: string, before: Set<ThreadMessageID>): Promise<boolean> {
  // Read full history so compaction and later tool results cannot hide delivery.
  for (let offset = 0; ; offset += 20) {
    const messages = await thread.messages({ full: true, from: 'end', offset, limit: 20, roles: ['user'] })
    // Remember a whole page so the boundary does not depend on page ordering.
    const newer = messages.filter(message => !before.has(message.id))
    if (newer.some(message => message.role === 'user' && message.content.some(block => block.type === 'text' && block.text === content))) {
      return true
    }
    if (newer.length !== messages.length || messages.length < 20) return false
  }
}

async function createActivity(amp: PluginAPI, thread: PluginThread, root: string): Promise<Activity> {
  let state: ActivityState = 'unknown'
  let title = ''
  let observedState = false
  let observedTitle = false
  let sequence = 0
  let filesRevision = 0
  const tools = new Map<string, string>()
  const clients = new Set<StreamClient>()

  const line = (): string => JSON.stringify({
    version: 1, root, thread: thread.id, sequence,
    state: state === 'awaiting-approval' || state === 'error' ? state : tools.size ? 'running' : state,
    title, tool: tools.size ? [...tools.values()].at(-1)! : null,
    files_revision: filesRevision,
  } satisfies ActivitySnapshot) + '\n'
  const write = (client: StreamClient, value: string): void => {
    if (client.response.destroyed || client.response.writableEnded) return
    if (client.pending !== null) {
      if (value === '\n') return // A heartbeat must not overwrite a pending state change.
      client.pending = value
      if (client.response.writableLength > MAX_STREAM_BUFFER) client.response.destroy()
      return
    }
    if (!client.response.write(value)) client.pending = ''
  }
  const publish = (): void => {
    sequence++
    const value = line()
    for (const client of clients) write(client, value)
  }
  const subscriptions = [
    thread.state.subscribe((value) => {
      observedState = true
      state = value
      if (value === 'idle' || value === 'error') tools.clear()
      publish()
    }),
    thread.title.subscribe((value) => { observedTitle = true; title = value ?? ''; publish() }),
  ]
  // Subscribe before reading so an in-flight get cannot overwrite a newer event.
  await Promise.all([
    thread.state.get().then((value) => { if (!observedState) state = value }).catch(() => {}),
    thread.title.get().then((value) => { if (!observedTitle) title = value ?? '' }).catch(() => {}),
  ])
  // A CLI can detach from a thread without another state event. Re-read the host
  // state so that missed events recover and detached threads do not stay "idle".
  let disposed = false
  let refreshing = false
  const refresh = setInterval(async () => {
    if (refreshing) return
    refreshing = true
    const previous = sequence
    let value: ActivityState = 'unknown'
    try { value = await amp.threads.get(thread.id).state.get() } catch { /* Detached threads cannot be observed by this host. */ }
    refreshing = false
    if (disposed || sequence !== previous) return
    const clearTools = value === 'idle' || value === 'error' || value === 'unknown'
    if (state === value && !(clearTools && tools.size)) return
    state = value
    if (clearTools) tools.clear()
    publish()
  }, HEARTBEAT_MS)
  refresh.unref()
  return {
    call(id, tool) { tools.set(id, tool); publish() },
    result(id, filesChanged) {
      const tracked = tools.delete(id)
      // Retain invalidations in every snapshot, including after stream coalescing/reconnect.
      if (filesChanged) filesRevision++
      if (tracked || filesChanged) publish()
    },
    subscribe(response) {
      const client = { response, pending: null } as StreamClient
      client.heartbeat = setInterval(() => write(client, '\n'), HEARTBEAT_MS)
      client.heartbeat.unref()
      clients.add(client)
      response.on('drain', () => {
        if (client.pending === null) return
        const pending = client.pending
        client.pending = null
        if (pending) write(client, pending)
      })
      const close = () => { clearInterval(client.heartbeat); clients.delete(client) }
      response.once('close', close)
      write(client, line())
    },
    dispose() {
      disposed = true
      clearInterval(refresh)
      for (const subscription of subscriptions) subscription.unsubscribe()
      for (const client of clients) {
        clearInterval(client.heartbeat)
        client.response.end()
      }
      clients.clear()
    },
  }
}

async function showConnection(thread: PluginThread, descriptor: string): Promise<void> {
  await thread.appendUserMessage({
    type: 'user-message',
    content: [
      'Readiff is connected. Setup information for the human user, not a request for the agent to run commands or edit files.',
      'In rediff, open this same checkout and run :harness connect amp.',
      `If multiple sessions match, select thread ${thread.id} in the picker.`,
      'Then :w in the Review tree or diff sends saved annotations to this thread.',
      '',
      `Connection: ${descriptor}`,
      'This connection is valid until the plugin disconnects or reloads. Run readiff: connect again to show setup information.',
    ].join('\n'),
  })
}

async function closeServer(server: Server): Promise<void> {
  if (!server.listening) return
  server.closeAllConnections()
  await new Promise<void>((resolve) => server.close(() => resolve()))
}

export default async function readiffPlugin(amp: PluginAPI): Promise<void> {
  const connections = new Map<string, Connection>()
  const connecting = new Map<string, Promise<void>>()
  const disconnected = new Set<string>()
  const terminal = process.env.REDIFF_TERMINAL_ID

  async function remember(thread: string, root: string): Promise<void> {
    const directory = join(process.env.XDG_STATE_HOME || join(homedir(), '.local/state'), 'rediff/amp')
    await mkdir(directory, { recursive: true, mode: 0o700 })
    const path = join(directory, createHash('sha256').update(root).digest('hex') + '.json')
    const temporary = path + '.' + randomBytes(8).toString('hex')
    try {
      await writeFile(temporary, JSON.stringify({ root, thread }), { mode: 0o600, flag: 'wx' })
      await rename(temporary, path)
    } finally {
      await rm(temporary, { force: true })
    }
  }

  async function disconnect(threadID: string): Promise<boolean> {
    const connection = connections.get(threadID)
    if (!connection) return false
    connections.delete(threadID)
    connection.activity.dispose()
    await rm(connection.directory, { recursive: true, force: true })
    await closeServer(connection.server)
    return true
  }

  async function connect(ctx: PluginCommandContext, announce: boolean): Promise<void> {
    if (!ctx.thread) {
      await ctx.ui.notify('Start a thread before connecting readiff.')
      return
    }
    const existing = connections.get(ctx.thread.id)
    if (existing) {
      if (announce) await showConnection(ctx.thread, existing.descriptor)
      return
    }
    const workspaceURI = ctx.system.workspaceRoot
    if (!workspaceURI) {
      await ctx.ui.notify('Open a workspace before connecting readiff.')
      return
    }

    const root = await realpath(amp.helpers.filePathFromURI(workspaceURI))
    const token = randomBytes(32).toString('hex')
    const outcomes = new Map<string, Outcome>()
    const thread: PluginThread = ctx.thread
    // A title is optional metadata; failure to read it must not prevent review.
    const title = await thread.title.get().catch(() => null)
    const activity = await createActivity(amp, thread, root)

    const server = createServer((request, response) => {
      void (async () => {
        const feedback = request.url === '/feedback'
        const events = request.url === '/events'
        if ((!feedback && !events) || (events ? request.method !== 'GET' : !['GET', 'POST'].includes(request.method ?? ''))) {
          response.writeHead(404).end('not found')
          return
        }
        if (request.headers.origin !== undefined) {
          response.writeHead(403).end('browser origins are not accepted')
          return
        }
        if (request.headers.authorization !== `Bearer ${token}`) {
          response.writeHead(401).end('unauthorized')
          return
        }
        if (events) {
          response.writeHead(200, {
            'Content-Type': 'application/x-ndjson',
            'Cache-Control': 'no-cache',
            Connection: 'keep-alive',
          })
          activity.subscribe(response)
          return
        }
        if (request.method === 'GET') {
          // Lifecycle events also belong to background threads and may not replay
          // on plugin reload. Only the host's UI focus identifies this terminal.
          response.writeHead(200, { 'Content-Type': 'application/json' })
            .end(JSON.stringify({ version: 1, root, thread: thread.id,
              ...(terminal && amp.activeThread.current?.id === thread.id ? { terminal } : {}),
            }))
          return
        }

        const chunks: Buffer[] = []
        let size = 0
        for await (const chunk of request) {
          size += chunk.length
          if (size > MAX_BODY) {
            response.writeHead(413).end('body too large')
            return
          }
          chunks.push(chunk)
        }
        let body: unknown
        try {
          body = JSON.parse(Buffer.concat(chunks).toString('utf8'))
        } catch {
          response.writeHead(400).end('invalid JSON')
          return
        }
        if (
          typeof body !== 'object' || body === null || Array.isArray(body) ||
          typeof (body as { id?: unknown }).id !== 'string' ||
          (body as { id: string }).id.length === 0 || (body as { id: string }).id.length > MAX_ID ||
          typeof (body as { content?: unknown }).content !== 'string' ||
          (body as { content: string }).content.trim().length === 0
        ) {
          response.writeHead(400).end('expected a bounded id and nonempty content')
          return
        }
        const { id, content } = body as { id: string; content: string }
        const previous = outcomes.get(id)
        if (previous && previous.content !== content) {
          response.writeHead(409).end('id was already used with different content')
          return
        }
        // Resolve an explicit thread handle, not a saved invocation context.
        const target = amp.threads.get(thread.id)
        const outcome = previous ?? {
          content,
          confirmed: false,
          result: (async () => {
            const before = await target.messages({ full: true, from: 'end', limit: 20, roles: ['user'] })
            await target.appendUserMessage({ type: 'user-message', content }, { steer: true })
            return new Set(before.map(message => message.id))
          })(),
        }
        if (!previous) outcomes.set(id, outcome)
        try {
          const before = await outcome.result
          // appendUserMessage can resolve while feedback is only queued. Never
          // let that alone clear editor notes. Retries inspect, never re-append.
          if (!outcome.confirmed && await containsFeedback(target, content, before)) outcome.confirmed = true
          if (!outcome.confirmed) {
            response.writeHead(202).end('feedback is not yet visible in the target thread; retry the same submission to check delivery')
            return
          }
          response.writeHead(204).end()
        } catch (error) {
          amp.logger.log('readiff feedback append failed; id remains cached', id, error)
          response.writeHead(500).end('feedback outcome is uncertain; check the thread before reconnecting and resending')
        }
      })().catch((error) => {
        amp.logger.log('readiff request failed', error)
        if (!response.headersSent) response.writeHead(500)
        response.end('internal error')
      })
    })

    await new Promise<void>((resolve, reject) => {
      server.once('error', reject)
      server.listen(0, '127.0.0.1', () => {
        server.off('error', reject)
        resolve()
      })
    }).catch((error) => {
      activity.dispose()
      throw error
    })
    const address = server.address()
    if (!address || typeof address === 'string') throw new Error('readiff server has no TCP address')
    const directory = await (async () => {
      const registry = join(homedir(), '.cache/rediff/amp')
      await mkdir(registry, { recursive: true, mode: 0o700 })
      const info = await lstat(registry)
      if (!info.isDirectory() || (info.mode & 0o077) !== 0 || info.uid !== process.getuid?.()) {
        throw new Error('readiff connection registry must be a private directory owned by you')
      }
      return mkdtemp(join(registry, 'session-'))
    })().catch(async (error) => {
      activity.dispose()
      await closeServer(server)
      throw error
    })
    const descriptor = join(directory, 'connection.json')
    try {
      await writeFile(descriptor, JSON.stringify({
        version: 1,
        url: `http://127.0.0.1:${address.port}/feedback`,
        token,
        root,
        thread: thread.id,
        capabilities: ['activity'],
        ...(title ? { title } : {}),
      }), { mode: 0o600 })
      connections.set(thread.id, { server, directory, descriptor, root, activity })
      await remember(thread.id, root).catch((error) => amp.logger.log('readiff session history failed', error))
    } catch (error) {
      activity.dispose()
      await closeServer(server)
      await rm(directory, { recursive: true, force: true })
      throw error
    }
    if (announce) await showConnection(thread, descriptor)
  }

  async function ensureConnection(ctx: PluginCommandContext, announce: boolean): Promise<void> {
    if (!ctx.thread) return connect(ctx, announce)
    const id = ctx.thread.id
    const pending = connecting.get(id)
    if (pending) {
      await pending
      const connection = connections.get(id)
      if (announce && connection) await showConnection(ctx.thread, connection.descriptor)
      return
    }
    const task = connect(ctx, announce)
    connecting.set(id, task)
    try { await task } finally { connecting.delete(id) }
  }

  async function autoConnect(_event: unknown, ctx: PluginCommandContext): Promise<void> {
    if (!ctx.thread || !ctx.system.workspaceRoot || disconnected.has(ctx.thread.id)) return
    try {
      await ensureConnection(ctx, false)
    } catch (error) {
      amp.logger.log('readiff automatic connection failed', error)
    }
  }
  amp.on('session.start', async (event, ctx) => {
    const existing = connections.get(ctx.thread.id)
    await autoConnect(event, ctx)
    // Switching back to an already-connected thread makes it the last session too.
    if (existing) await remember(ctx.thread.id, existing.root).catch((error) => amp.logger.log('readiff session history failed', error))
  })
  // Also registers after reloading the plugin in an already-open session.
  amp.on('agent.start', autoConnect)
  amp.on('tool.call', (event) => {
    connections.get(event.thread.id)?.activity.call(event.toolUseID, event.tool)
    return { action: 'allow' }
  })
  amp.on('tool.result', (event) => {
    const connection = connections.get(event.thread.id)
    if (!connection) return
    let filesChanged = false
    try {
      filesChanged = (amp.helpers.filesModifiedByToolCall(event) ?? []).some((uri) => {
        const path = relative(connection.root, amp.helpers.filePathFromURI(uri))
        return path !== '' && path !== '..' && !path.startsWith('../') && !isAbsolute(path)
      })
    } catch (error) {
      amp.logger.log('readiff file-change detection failed', error)
    }
    // Error/cancelled tools may have partially applied edits; Git decides what actually changed.
    connection.activity.result(event.toolUseID, filesChanged)
  })
  amp.registerCommand('readiff-connect', {
    category: 'readiff', title: 'connect', description: 'Connect editor review feedback to this thread',
  }, async (ctx) => {
    if (ctx.thread) {
      disconnected.delete(ctx.thread.id)
    }
    await ensureConnection(ctx, true)
  })
  amp.registerCommand('readiff-disconnect', {
    category: 'readiff', title: 'disconnect', description: 'Disconnect editor review feedback from this thread',
  }, async (ctx) => {
    if (!ctx.thread) return void await ctx.ui.notify('No current thread to disconnect.')
    disconnected.add(ctx.thread.id)
    await connecting.get(ctx.thread.id)
    const removed = await disconnect(ctx.thread.id)
    await ctx.ui.notify(removed ? 'Readiff disconnected.' : 'Readiff is not connected to this thread.')
  })
  for (const command of [
    {
      name: 'branch-split-propose',
      description: 'Propose reviewable branches with per-branch diff sizes without changing the repository.',
      request: branchSplitProposeRequest,
    },
    {
      name: 'branch-split-push',
      description: 'Split and validate reviewable branches with diff sizes, then publish after explicit approval.',
      request: branchSplitPushRequest,
    },
  ]) {
    amp.registerCommand(`readiff-${command.name}`, {
      category: 'readiff', title: command.name, description: command.description,
    }, async (ctx) => {
      if (!ctx.thread) {
        await ctx.ui.notify(`Start or open a thread before running ${command.name}.`)
        return
      }
      await ctx.thread.appendUserMessage({ type: 'user-message', content: command.request })
    })
  }
  amp.onDispose(async () => {
    await Promise.allSettled(connecting.values())
    await Promise.all([...connections.keys()].map(disconnect))
  })
}
