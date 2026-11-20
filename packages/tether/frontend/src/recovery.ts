import { openDB } from "idb";
import type { AnnotationInput, Comparison, Source } from "./protocol";

export interface RecoveryDraft {
  owner: string;
  worktree: string;
  machine?: string;
  input: AnnotationInput;
  submission: "editing" | "pending";
  source: Source;
  comparison?: Comparison;
  expiresAt: string;
}

const database = openDB("tether-recovery", 1, {
  upgrade(database) {
    database.createObjectStore("drafts", { keyPath: "input.id" });
  },
});

let writes: Promise<void> = Promise.resolve();

export function expiresAfterThreeMonths(): string {
  const now = new Date();
  const day = now.getUTCDate();
  now.setUTCDate(1);
  now.setUTCMonth(now.getUTCMonth() + 3);
  const lastDay = new Date(
    Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 0),
  ).getUTCDate();
  now.setUTCDate(Math.min(day, lastDay));
  return now.toISOString();
}

export function saveRecovery(draft: RecoveryDraft): Promise<void> {
  writes = writes
    .catch(() => {})
    .then(async () => {
      const db = await database;
      const transaction = db.transaction("drafts", "readwrite");
      await transaction.store.put(draft);
      await transaction.done;
    });
  return writes;
}

export async function recoveryDrafts(
  owner: string,
  worktree?: string,
  machine = "local",
): Promise<RecoveryDraft[]> {
  await writes;
  const db = await database;
  const drafts: RecoveryDraft[] = await db.getAll("drafts");
  const current: RecoveryDraft[] = [];
  for (const draft of drafts) {
    if (draft.expiresAt <= new Date().toISOString()) {
      await db.delete("drafts", draft.input.id);
    } else if (
      draft.owner === owner &&
      (!worktree ||
        (draft.worktree === worktree && (draft.machine ?? "local") === machine))
    ) {
      current.push(draft);
    }
  }
  return current;
}

export async function deleteRecovery(id: string): Promise<void> {
  await writes;
  const db = await database;
  await db.delete("drafts", id);
}
