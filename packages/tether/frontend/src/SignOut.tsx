import { useState } from "react";
import { useMutation } from "@tanstack/react-query";
import * as Dialog from "@radix-ui/react-dialog";
import { api } from "./api";
import {
  deleteRecovery,
  recoveryDrafts,
  saveRecovery,
  type RecoveryDraft,
} from "./recovery";
import styles from "./Workbench.module.css";

export function SignOut({ owner }: { owner: string }) {
  const [open, setOpen] = useState(false);
  const [allBrowsers, setAllBrowsers] = useState(false);
  const [drafts, setDrafts] = useState<RecoveryDraft[] | null>(null);
  const [loadError, setLoadError] = useState("");
  const logout = useMutation({
    mutationFn: async (action: "save" | "export" | "discard") => {
      const remaining = await recoveryDrafts(owner);
      if (action === "save") {
        for (const draft of remaining) {
          await saveRecovery({ ...draft, submission: "pending" });
          const endpoint =
            draft.machine && draft.machine !== "local"
              ? `machines/${draft.machine}/worktrees/${draft.worktree}`
              : `worktrees/${draft.worktree}`;
          await api(`${endpoint}/annotations`, {
            method: "POST",
            body: JSON.stringify(draft.input),
          });
          await deleteRecovery(draft.input.id);
        }
      }
      if (action === "export") {
        const file = new Blob([JSON.stringify(remaining, null, 2)], {
          type: "application/json",
        });
        const url = URL.createObjectURL(file);
        const link = document.createElement("a");
        link.href = url;
        link.download = "tether-drafts.json";
        link.click();
        setTimeout(() => URL.revokeObjectURL(url), 1000);
      }
      await api("logout", {
        method: "POST",
        body: JSON.stringify({ all: allBrowsers }),
      });
      for (const draft of remaining) await deleteRecovery(draft.input.id);
      sessionStorage.clear();
      window.location.assign("/");
    },
  });

  async function show() {
    setOpen(true);
    setDrafts(null);
    setLoadError("");
    try {
      setDrafts(await recoveryDrafts(owner));
    } catch (error) {
      setLoadError((error as Error).message);
    }
  }

  return (
    <Dialog.Root
      open={open}
      onOpenChange={(next) => {
        if (!logout.isPending) setOpen(next);
      }}
    >
      <button onClick={() => void show()}>Sign out</button>
      <Dialog.Portal>
        <Dialog.Overlay className={styles.overlay} />
        <Dialog.Content className={styles.dialog}>
          <Dialog.Title>Sign out of Tether</Dialog.Title>
          <Dialog.Description>
            {drafts?.length
              ? `Recovery drafts in this browser: ${drafts.length}. Choose how to keep them before signing out.`
              : "Signing out clears this browser’s review cache. Saved annotations remain in their worktree services."}
          </Dialog.Description>
          <label>
            <input
              type="checkbox"
              checked={allBrowsers}
              onChange={(event) => setAllBrowsers(event.target.checked)}
            />{" "}
            Revoke all browser sessions
          </label>
          {allBrowsers && (
            <p>
              Disconnected browsers retain their local drafts until they
              reconnect or clear their storage.
            </p>
          )}
          {(loadError || logout.error) && (
            <p role="alert">{loadError || logout.error?.message}</p>
          )}
          <div className={styles.logoutActions}>
            {!!drafts?.length && (
              <>
                <button
                  disabled={
                    logout.isPending ||
                    drafts.some((draft) => !draft.input.text.trim())
                  }
                  onClick={() => logout.mutate("save")}
                >
                  Save annotations and sign out
                </button>
                <button
                  disabled={logout.isPending}
                  onClick={() => logout.mutate("export")}
                >
                  Export drafts and sign out
                </button>
              </>
            )}
            <button
              disabled={!drafts || logout.isPending}
              onClick={() => logout.mutate("discard")}
            >
              {drafts?.length
                ? "Discard drafts and sign out"
                : "Sign out this browser"}
            </button>
            <Dialog.Close asChild>
              <button disabled={logout.isPending}>Cancel</button>
            </Dialog.Close>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
