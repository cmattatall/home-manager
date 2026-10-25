import assert from 'node:assert/strict'
import { test } from 'node:test'
import plugin from '../desloppify.ts'

function loadPlugin() {
  const events = new Map<string, (event: any) => any>()
  const commands = new Map<string, (ctx: any) => Promise<void>>()
  plugin({
    on: (event, handler) => events.set(event, handler),
    registerCommand: (id, _options, handler) => commands.set(id, handler),
  } as any)
  return { events, commands }
}

test('guidance reaches every thread and turn without an editor or workspace', async () => {
  const { events } = loadPlugin()
  const start = events.get('agent.start')!
  const first = await start({ thread: { id: 'T-first' } })
  const second = await start({ thread: { id: 'T-second' } })
  const resumed = await start({ thread: { id: 'T-first' } })

  assert.equal(first.message.display, false)
  assert.match(first.message.content, /Do not use semicolons to join English clauses/)
  assert.match(first.message.content, /Retain security protections/)
  assert.deepEqual(second, first)
  assert.deepEqual(resumed, first)
})

test('desloppify submits a scoped cleanup and requires an active thread', async () => {
  const { commands } = loadPlugin()
  const messages: any[] = []
  const notifications: string[] = []
  const cleanup = commands.get('desloppify')!
  await cleanup({ thread: { appendUserMessage: async (message) => messages.push(message) } })

  assert.equal(messages.length, 1)
  assert.equal(messages[0].type, 'user-message')
  assert.match(messages[0].content, /preserving behavior and public contracts/)
  assert.match(messages[0].content, /ask for the target rather than sweeping the repository/)
  assert.match(messages[0].content, /run the relevant formatter, checks, and existing tests/)
  assert.match(messages[0].content, /does not authorize committing, pushing, or deploying/)

  await cleanup({ ui: { notify: async (message) => notifications.push(message) } })
  assert.deepEqual(notifications, ['Start or open a thread before running desloppify.'])
  assert.equal(messages.length, 1)
})
