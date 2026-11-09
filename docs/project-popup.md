# Projects popup

Press **Cmd+Shift+P** to browse recent projects and the current repository's Git
worktrees. Each Git project shows its folder name and current branch. Detached
checkouts show a short commit ID. The second line shows the directory, and row
indicators identify the **Current**, already **Open**, and **Locked** workspaces.

A Git project with one checkout uses a single compact row showing its directory,
branch (or detached commit), and status indicators, without a separate project
heading. Projects with multiple known worktrees retain the grouped layout below.
Searching for one branch does not collapse a multi-worktree project.

Workspaces belonging to the same repository appear together under a project
heading, with the main checkout's name and path and a workspace count. Indented
rows, branch icons, and a shared vertical guide show their relationship. Separate
repositories with the same folder name remain separate groups. Arrow keys move
between workspaces, skipping the headings.

Type a project name, branch name, or directory fragment to filter the list.
Matching workspaces stay grouped; headings show how many workspaces match when
the search hides others. The shared project directory is searchable too.
Existing command-palette prefixes such as `>` and `@` still select their normal
modes. Select a project to focus its existing window or open the checkout using
TextMate's normal project session restoration. Selecting a different worktree
does not change branches in your current checkout.

The list includes open projects and related worktrees even if they are absent
from Recent Projects. Non-Git projects continue to work. Git discovery excludes
bare repositories and missing/stale linked checkouts. Projects opened at a
subdirectory inherit the enclosing worktree's branch.

Saved subdirectories of a Git checkout are folded into one workspace entry at
the checkout root. Selecting it focuses an existing window for that checkout,
including a window opened at a subdirectory. Independent nested Git repositories
remain separate workspaces.

Right-click a workspace for **Hide Workspace** or **Hide Project**. The first
hides that checkout; the second hides every workspace belonging to its project,
including worktrees discovered later. Right-clicking a project heading also
offers **Hide Project**. The **…** visibility menu beside the search field offers
the same actions for the selected row.

To restore entries, choose **Show Hidden Workspaces** in the visibility menu.
Hidden rows have an eye-slash marker; right-click one and choose **Show Workspace**
or **Show Project**. **Restore All Hidden Entries** clears all hide preferences.
Hiding is saved across app restarts and affects only this popup. It does not
close windows, change project history, modify Git, or delete directories.

Cached information appears immediately. Git metadata refreshes in the background
each time the popup opens, preserving the search text and selected workspace.
Branch changes made outside TextMate appear on the next refresh. Worktree
directories are resolved to canonical paths so symbolic links do not create
duplicate entries. Git queries have a two-second timeout per repository and do
not modify files or the index.

The popup is implemented natively. Commands for creating, opening, listing, and
removing worktrees are provided separately by the Git bundle in the
`git-tmbundle` repository.
