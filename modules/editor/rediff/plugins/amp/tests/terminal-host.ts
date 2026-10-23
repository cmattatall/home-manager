// A separate plugin host, with no shared memory or terminal state with the editor.
import { pathToFileURL } from 'node:url'
import plugin from '../readiff.ts'

const [root, id] = process.argv.slice(2)
const handlers = new Map<string, (event: unknown, context: any) => unknown>()
const disposers: Array<() => Promise<void>> = []
const observable = (value: string) => ({
  get: async () => value,
  subscribe: () => ({ unsubscribe() {} }),
})
function createThread(id: string) {
  const messages: any[] = []
  return {
    id, title: observable(id), state: observable('idle'),
    messages: async ({ offset = 0, limit = 10 } = {}) => {
      const end = Math.max(0, messages.length - offset)
      return messages.slice(Math.max(0, end - limit), end)
    },
    appendUserMessage: async (message: { content: string }) => {
      messages.push({ id: messages.length, role: 'user', content: [{ type: 'text', text: message.content }] })
      process.send!({ thread: id, message })
    },
  }
}
const threads = new Map([[id, createThread(id)]])
const activeThread = { current: { id } }
await plugin({
  activeThread,
  threads: { get: (id: string) => threads.get(id) },
  helpers: { filePathFromURI: (uri: URL) => decodeURIComponent(uri.pathname) },
  logger: { log() {} },
  on(event: string, handler: (event: unknown, context: any) => unknown) {
    handlers.set(event, handler)
    return { unsubscribe() {} }
  },
  registerCommand() { return { unsubscribe() {} } },
  onDispose(dispose: () => Promise<void>) {
    disposers.push(dispose)
    return { unsubscribe() {} }
  },
} as any)
await handlers.get('session.start')!({}, {
  system: { workspaceRoot: pathToFileURL(root) },
  thread: threads.get(id),
})
process.send!({ ready: true })
process.on('message', async (message: { thread?: string } | string) => {
  if (typeof message !== 'string' && message.thread) {
    const id = message.thread
    if (!threads.has(id)) threads.set(id, createThread(id))
    activeThread.current = { id }
    await handlers.get('session.start')!({}, {
      system: { workspaceRoot: pathToFileURL(root) },
      thread: threads.get(id),
    })
    return
  }
  await Promise.all(disposers.map(dispose => dispose()))
  process.disconnect()
})
