# Compare

Compare shows the differences between two folders, usually two Git worktrees of the same repository, and copies changes between them in either direction. `Applications/Compare` builds `Compare.app`, a helper app embedded in TextMate's app bundle. It runs as a separate process and uses TextMate's settings and file browser components.

## Opening a comparison

When the project in the front window belongs to a Git repository with more than one worktree, **Text → Compare To** lists the other worktrees by folder name and branch. Choose one to compare it with the project's worktree. The project's worktree is always on the left, and the comparison opens on the project's folder within it. The menu item is hidden when there is no other worktree. TextMate notices worktrees being added or removed (including from its own terminal), when the project changes, and when TextMate becomes active.

From the command line, run `tm-compare <left-folder> <right-folder>`, optionally with `--focus <relative-path>` to open on a folder inside them. Any two folders can be compared; without Git, every file in them is listed. Comparing the same pair again brings its window to the front.

## Files tab

The first tab, **Files**, shows the two folders side by side as trees that look like TextMate's file browser. Every row lines up across the two sides: an entry missing on one side shows as a dimmed placeholder there. Expanding, collapsing, selecting and scrolling on one side does the same on the other. Each header shows the folder's name, its branch and its location.

Row backgrounds show what differs:

| Color | Meaning |
|---|---|
| None | Identical |
| Amber | File contents differ |
| Light amber | Folder contains differences |
| Green | Only on this side (the other side shows a grey placeholder) |
| Red | A file on one side and a folder or link on the other |

Above the trees:

- **Changed**, **Left Only**, **Right Only** and **All** choose which entries are shown. Changed is the default and hides identical entries.
- **Ignored Files** also compares files that `.gitignore` excludes. By default the comparison uses Git's list of tracked and untracked files, so build output and other ignored files are left out.
- The summary counts modified entries, entries only on each side, and type changes.
- **Filter by name** narrows both trees to entries whose names contain the text (ignoring case and accents), expanding to show them. A matching folder shows everything inside it. Clearing the field restores the folders that were expanded before.
- The refresh button (**File → Compare Again**, ⌘R) compares everything again.

Comparisons stay current: when a compared file changes on disk, or a new file appears that is not ignored, Compare compares again. Changes inside `.git` and to ignored files do not trigger a comparison. Expanded folders are remembered for each pair of folders.

Files are compared byte for byte; symbolic links by their targets. Submodules and nested repositories are listed but not compared. A change to a file's permissions alone is not shown as a difference.

## File tabs

Double-click a file in either tree, or select it and press ⌘↓ or ⌘O (**File → Open File Comparison**), to compare its contents in a tab of its own. Opening a file that already has a tab selects it. Double-clicking a folder expands or collapses it. Several selected files open together.

Both versions are shown side by side with line numbers. Rows line up: a line only on one side shows as a grey gap on the other.

- Changed lines are amber on both sides, with the part that differs in a stronger amber.
- Lines only on one side are green.
- The header shows the file's path, how many changes there are and how many lines they affect, and notes different line endings (CRLF) or a missing newline at the end of a file.
- **Go → Next Change** (⌃⌘↓) and **Previous Change** (⌃⌘↑), or the chevrons in the header, move between changes. Opening a file shows its first change.

Binary files, files over 8 MB, folders, symbolic links (their targets are described instead), submodules and entries that are a file on one side and a folder on the other are not shown as text. Lines are shown in the user's fixed-pitch font without syntax highlighting.

**File → Close Tab** (⌘W) closes the selected file tab; on the Files tab it closes the window. The Files tab cannot be closed. **Window → Select Next Tab** (⇧⌘]) and **Select Previous Tab** (⇧⌘[) move between tabs. Tabs for files with the same name show their parent folder.

## Copying changes

Changes can be copied in either direction.

- **In the Files tab**, select entries and choose **Edit → Copy to the Right** (⌥⌘→) or **Copy to the Left** (⌥⌘←), or use the same commands in either tree's context menu. A file or link replaces the other side's entry. A folder copies every differing entry inside it; entries only on the destination side are left alone. Where the destination has a folder in place of a file, or a file in place of a folder, that entry is moved to the Trash first. Copying more than one item, or replacing a folder or file of the other kind, asks for confirmation first.
- **Move to Trash** in a tree's context menu moves that side's entries to the Trash.
- **In a file tab**, the arrows between the two sides, next to each change, copy that change to the right (→) or to the left (←). **Edit → Copy Change to the Right** and **Copy Change to the Left** copy the current change. The tab stays on the same change number afterwards.

Compare only writes over what it compared: if a file changed on disk since it was compared, the copy is refused and asks you to compare again. Unsaved changes in TextMate are not part of the comparison: Compare reads and writes the files on disk, and TextMate treats its writes like those of any other program.

Every write replaces the file atomically and keeps its permissions. **Edit → Undo** (⌘Z) reverses the last copy or move to the Trash, and **Redo** (⇧⌘Z) does it again. Undo is refused when a file has changed since.

## Development

`make` builds `Compare.app` and the `tm-compare` launcher and embeds them in TextMate's `Contents/Helpers` and `Contents/MacOS`. TextMate opens comparisons with a `textmate-compare://compare?left=…&right=…&focus=…` URL; `src/compare_url.h` builds and parses it for the launcher, the app and TextMate's **Compare To** menu (`Applications/TextMate/src/WorktreeCompareMenu.mm`, which reuses the command palette's worktree discovery).

| File | Contents |
|---|---|
| `src/compare_tree.{h,mm}` | Listing (`git ls-files`, or a folder walk), classification, stamps, re-reading changed entries, `git check-ignore` |
| `src/compare_diff.{h,mm}` | Line diff (xdiff histogram) as aligned rows and hunks |
| `src/compare_transfer.{h,mm}` | Undoable change sets, tree copies and moves to the Trash, applying one change |
| `src/compare_watch.h` | FSEvents wrapper, also used by TextMate's menu |
| `src/CompareWindowController.mm` | Window, tabs (`OakTabBarView`), trees (`FileBrowserOutlineView`, `FileItemTableCellView`), transfers and undo |
| `src/CompareDiffView.mm` | File tab: text views, full-width line tints, line numbers, change arrows |

Tests (see CLAUDE.md for running them):

| Suite | Covers |
|---|---|
| `compare` | URL encoding, hunk model |
| `compare-tree` | Listing and classification against a repository with a linked worktree, `check-ignore`, branch labels |
| `compare-transfer` | Applying changes, change sets and undo, tree copies, type changes, refused copies, the Trash |
| `compare-window` | The real window: alignment, tints, sync, filters, focus, tabs, transfers with undo, live refresh, search, remembered expansion |
| `compare-launch` | The signed app binary starts (library validation) |
| `tm-compare-help`, `tm-compare-rejects-missing-folder` | The launcher |

`compare-window` needs a GUI session. With `COMPARE_SNAPSHOT_DIR` set it also writes light and dark PNG snapshots; these do not show the file tab's text views, which only draw on screen.

Compare.app links the FileBrowser and OakTabBarView static libraries and bundles their images and TMFileReference's file-type icons, which static libraries cannot carry. FileBrowser pulls in `libOakSwiftUI.dylib`, so ad-hoc signed builds need `com.apple.security.cs.disable-library-validation`, as ThemeEditor does.
