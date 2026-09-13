export type FileMap = Record<string, string>;

export type Commit = {
  id: string;
  message: string;
  at: number;
  files: FileMap;
};

export type TermLine = {
  id: string;
  kind: "in" | "out" | "err" | "ok";
  text: string;
};

export type StashEntry = {
  id: string;
  message: string;
  files: FileMap;
  staged: string[];
  stagedBlobs?: FileMap;
};

export type BranchSnap = {
  files: FileMap;
  commits: Commit[];
  staged: string[];
  stagedBlobs?: FileMap;
  lastPushedId: string | null;
  origin: Commit | null;
};

export type BlameLine = {
  line: number;
  text: string;
  id: string;
  message: string;
  at: number;
};

export type Conflict = {
  path: string;
  ours: string;
  theirs: string;
};
