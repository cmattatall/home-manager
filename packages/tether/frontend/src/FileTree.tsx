import { useMemo, useState } from "react";
import type { ChangedFile } from "./protocol";
import styles from "./Workbench.module.css";

interface Directory {
  path: string;
  folders: Map<string, Directory>;
  files: ChangedFile[];
}

interface FileTreeProps {
  files: ChangedFile[];
  selected: string;
  disabled: boolean;
  onSelect: (path: string) => void;
}

export function FileTree({ files, ...selection }: FileTreeProps) {
  const root = useMemo(() => {
    const root: Directory = { path: "", folders: new Map(), files: [] };
    for (const file of files) {
      const parts = file.path.split("/");
      let directory = root;
      for (const name of parts.slice(0, -1)) {
        let child = directory.folders.get(name);
        if (!child) {
          child = {
            path: `${directory.path}${name}/`,
            folders: new Map(),
            files: [],
          };
          directory.folders.set(name, child);
        }
        directory = child;
      }
      directory.files.push(file);
    }
    return root;
  }, [files]);

  return (
    <ul className={styles.fileTree} aria-label="Worktree files">
      <DirectoryEntries directory={root} {...selection} />
    </ul>
  );
}

function DirectoryEntries({
  directory,
  ...selection
}: Omit<FileTreeProps, "files"> & { directory: Directory }) {
  return (
    <>
      {[...directory.folders.entries()]
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([name, child]) => (
          <Folder
            key={child.path}
            name={name}
            directory={child}
            {...selection}
          />
        ))}
      {[...directory.files]
        .sort((left, right) => left.path.localeCompare(right.path))
        .map((file) => (
          <li key={file.path}>
            <button
              title={file.path}
              disabled={selection.disabled}
              aria-current={
                selection.selected === file.path ? "page" : undefined
              }
              className={selection.selected === file.path ? styles.active : ""}
              onClick={() => selection.onSelect(file.path)}
            >
              <span className={styles.fileName}>
                {file.path.split("/").at(-1)}
              </span>
              {file.status && (
                <span className={styles.fileStatus}>{file.status}</span>
              )}
            </button>
          </li>
        ))}
    </>
  );
}

function Folder({
  name,
  directory,
  ...selection
}: Omit<FileTreeProps, "files"> & { name: string; directory: Directory }) {
  const [expanded, setExpanded] = useState(true);
  return (
    <li>
      <button
        title={directory.path}
        aria-expanded={expanded}
        onClick={() => setExpanded(!expanded)}
      >
        <span aria-hidden="true">{expanded ? "▾" : "▸"}</span>
        <span className={styles.fileName}>{name}</span>
      </button>
      {expanded && (
        <ul>
          <DirectoryEntries directory={directory} {...selection} />
        </ul>
      )}
    </li>
  );
}
