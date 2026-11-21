import { useState } from "react";
import { useInfiniteQuery } from "@tanstack/react-query";
import { api } from "./api";
import type { SourceDirectory } from "./protocol";
import styles from "./Workbench.module.css";

interface ExplorerProps {
  endpoint: string;
  selected: string;
  disabled: boolean;
  onSelect: (path: string) => void;
}

export function Explorer(props: ExplorerProps) {
  return (
    <ul className={styles.fileTree} aria-label="Repository files">
      <DirectoryContents path="" {...props} />
    </ul>
  );
}

function DirectoryContents({
  path,
  ...props
}: ExplorerProps & { path: string }) {
  const listing = useInfiniteQuery({
    queryKey: [props.endpoint, "sourceDirectory", path],
    initialPageParam: 0,
    queryFn: ({ pageParam, signal }) =>
      api<SourceDirectory>(
        `${props.endpoint}/sourceDirectory?${new URLSearchParams({
          path,
          offset: String(pageParam),
        })}`,
        { signal },
      ),
    getNextPageParam: (page) => page.nextOffset ?? undefined,
  });
  return (
    <>
      {listing.data?.pages.flatMap((page) =>
        page.entries.map((entry) =>
          entry.directory ? (
            <ExplorerFolder key={entry.path} path={entry.path} {...props} />
          ) : (
            <li key={entry.path}>
              <button
                title={entry.path}
                disabled={props.disabled}
                aria-current={
                  props.selected === entry.path ? "page" : undefined
                }
                className={props.selected === entry.path ? styles.active : ""}
                onClick={() => props.onSelect(entry.path)}
              >
                <span className={styles.fileName}>
                  {entry.path.split("/").at(-1)}
                </span>
              </button>
            </li>
          ),
        ),
      )}
      {listing.isFetching && (
        <li className={styles.loading} role="status">
          Loading folder…
        </li>
      )}
      {listing.error && (
        <li>
          <p className={styles.error} role="alert">
            {listing.error.message}
          </p>
          <button onClick={() => void listing.refetch()}>Retry folder</button>
        </li>
      )}
      {listing.data?.pages[0].entries.length === 0 && (
        <li className={styles.loading}>Empty folder</li>
      )}
      {listing.hasNextPage && (
        <li>
          <button
            disabled={listing.isFetching}
            onClick={() => void listing.fetchNextPage()}
          >
            Load more entries
          </button>
        </li>
      )}
    </>
  );
}

function ExplorerFolder({ path, ...props }: ExplorerProps & { path: string }) {
  const [expanded, setExpanded] = useState(false);
  return (
    <li>
      <button
        title={`${path}/`}
        aria-expanded={expanded}
        onClick={() => setExpanded(!expanded)}
      >
        <span aria-hidden="true">{expanded ? "▾" : "▸"}</span>
        <span className={styles.fileName}>{path.split("/").at(-1)}</span>
      </button>
      {expanded && (
        <ul>
          <DirectoryContents path={path} {...props} />
        </ul>
      )}
    </li>
  );
}
