import { FileTree } from "@/components/ide/file-tree";
import { GitPane } from "@/components/ide/git-pane";
import { PaneError } from "@/components/ide/pane-error";
import { ProblemsPane } from "@/components/ide/problems-pane";
import { SearchPane } from "@/components/ide/search-pane";
import { SettingsPane } from "@/components/ide/settings-pane";
import { useChrome } from "@/lib/workspace/chrome";

export function Sidebar() {
  const side = useChrome((s) => s.side);
  return (
    <aside className="sidebar">
      <PaneError name="Painel">
        {side === "files" ? <FileTree /> : null}
        {side === "search" ? <SearchPane /> : null}
        {side === "git" ? <GitPane /> : null}
        {side === "problems" ? <ProblemsPane /> : null}
        {side === "settings" ? <SettingsPane /> : null}
      </PaneError>
    </aside>
  );
}