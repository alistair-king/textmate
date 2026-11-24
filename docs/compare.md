# Compare

Compare shows the differences between two folders, usually two Git worktrees of the same repository, and copies changes between them in either direction. `Applications/Compare` builds `Compare.app`, a helper app embedded in TextMate's app bundle. It runs as a separate process and uses TextMate's settings and file browser components.

## Opening a comparison

When the project in the front window belongs to a Git repository with more than one worktree, **Text → Compare To** lists the other worktrees by folder name and branch. Choose one to compare it with the project's worktree. The project's worktree is always on the left, and the comparison opens on the project's folder within it. The menu item is hidden when there is no other worktree. TextMate notices worktrees being added or removed (including from its own terminal), when the project changes, and when TextMate becomes active.

From the command line, run `tm-compare <left-folder> <right-folder>`, optionally with `--focus <relative-path>` to open on a folder inside them. Any two folders can be compared; without Git, every file in them is listed. Comparing the same pair again brings its window to the front.

Run `tm-compare` without arguments, open Compare.app by itself, or choose **File → New Comparison…** (⌘N) in Compare, and a **New Comparison** window asks what to compare: click **Choose…** on the Left and Right cards, or drop a folder or file on either card (⇄ between them swaps the two), then **Compare**. Compare is enabled only for two folders or two files, and not for the same one twice; the window says why when it isn't. Closing that window without comparing quits Compare when nothing else is open.

Given two files rather than two folders (`tm-compare <left-file> <right-file>`, the names may differ), Compare opens just their comparison: a window with one file tab and no trees, which works like any file tab below. Copies, Undo and Edit in TextMate work as usual, and the window compares again when either file changes on disk (other files in their folders do not count). A file and a folder cannot be compared with each other, and `--focus` applies to folders only.

## Files tab

The first tab, **Files**, shows the two folders side by side as trees that look like TextMate's file browser, with copy arrows between them (see [Copying changes](#copying-changes)). Every row lines up across the two sides: an entry missing on one side shows as a dimmed placeholder there. Expanding, collapsing, selecting and scrolling on one side does the same on the other. Each header shows the folder's name, its branch and its location.

Only differences get a background color, so they stand out; everything else keeps the default background:

| Row | Meaning |
|---|---|
| Default background | Identical |
| Default background, amber dot at the end | A folder on both sides with differences somewhere inside it |
| Amber | File contents differ |
| Green | Only on this side (the other side shows a hatched grey placeholder) |
| Red | A file on one side and a folder or link on the other |

The **View** menu chooses what the trees show, with the current choice checked:

- **Changed Files** (⌘1), the default, shows differences and hides identical entries.
- **Only on the Left** (⌘2) and **Only on the Right** (⌘3) show entries that exist on one side only, and the folders containing them.
- **All Files** (⌘4) shows everything, identical entries included.
- **Show Ignored Files** (⌘>, which is ⇧⌘. on a US keyboard) also compares files that `.gitignore` excludes. By default the comparison uses Git's list of tracked and untracked files, so build output and other ignored files are left out; with this on, both folders are walked on disk instead.
- **Expand All** and **Collapse All** expand or collapse every folder in both trees, within the current display mode and name filter. They have no shortcuts, since ⇧⌘ and ⌥⌘ with the arrow keys already move the caret and copy changes.
- **Swap Left and Right** mirrors the comparison: the right folder (or file) moves to the left. Open file tabs, expanded folders and the selection stay, and both sides are compared again. Undo and Redo keep working: a copy redone after swapping still goes into the folder it first went into, whichever side that is now.

Choosing any of these except Swap Left and Right from a file tab switches to the Files tab. The display mode and Show Ignored Files apply to every open Compare window and are remembered for new ones; Expand All and Collapse All affect only the front window.

Above the trees:

- The summary counts modified entries, entries only on each side, and type changes.
- **Filter by name** narrows both trees to entries whose names contain the text (ignoring case and accents), expanding to show them. A matching folder shows everything inside it. Clearing the field restores the folders that were expanded before.
- The refresh button (**File → Compare Again**, ⌘R) compares everything again.

If Git takes longer than a minute to list the files, the comparison fails rather than listing every file, ignored ones included. Comparisons stay current: when a compared file changes on disk, or a new file appears that is not ignored, Compare compares again. Changes inside `.git` and to ignored files do not trigger a comparison. A new window opens with every folder that contains differences expanded, so the changed files are in view; folders that are a difference themselves (only on one side, or a file on the other) stay collapsed. Other expanded folders are remembered for each pair of folders.

Files are compared byte for byte; symbolic links by their targets. Empty folders appear when folders are walked (without Git, or with **Show Ignored Files**); Git's list of files has no empty folders. Submodules and nested repositories (folders with their own `.git`) are listed as one entry but not compared, and a folder walk does not go inside them. A change to a file's permissions alone is not shown as a difference.

## File tabs

Double-click a file in either tree, or select it and press ⌘↓ or ⌘O (**File → Open File Comparison**), to compare its contents in a tab of its own. Opening a file that already has a tab selects it. Double-clicking a folder expands or collapses it. Several selected files open together.

Both versions are shown side by side with line numbers. Above each side, as above each tree in the Files tab, a header shows that side's file name and Git branch (or “detached” and the commit; nothing outside Git) and the file's full path, dimmed where the file is missing on that side. Rows line up: a line only on one side shows as a hatched gap on the other. The line-number gutter carries the same background colors as its rows.

- Changed lines are amber on both sides, with the part that differs in a stronger amber.
- Lines only on one side are green; the other side shows a hatched gap.
- The header shows the file's path, how many changes there are and how many lines they affect, and notes different line endings (CRLF) or a missing newline at the end of a file.
- **Go → Next Change** (⌃⌘↓) and **Previous Change** (⌃⌘↑), or the chevrons in the header, move between changes. Opening a file shows its first change.

Binary files, files over 8 MB, folders, symbolic links (their targets are described instead), submodules and entries that are a file on one side and a folder on the other are not shown as text.

Each side is shown as TextMate's editor would show that file: the file type it detects (from the name and first line), its grammar's syntax highlighting, the font and size from the `fontName` and `fontSize` settings, and the theme from the `theme` setting or, without one, the theme chosen for the current light or dark appearance (**View → Theme**). Settings in `.tm_properties` files apply as in the editor. The difference tints are drawn over the theme's background, and switching between light and dark appearance switches the theme. Files over 2 MB are shown in the theme's colors without highlighting.

**File → Close Tab** (⌘W) closes the selected file tab; on the Files tab it closes the window. The Files tab cannot be closed and has no close button. **Window → Select Next Tab** (⇧⌘]) and **Select Previous Tab** (⇧⌘[) move between tabs. Tabs for files with the same name show their parent folder.

## Editing in TextMate

**File → Edit in TextMate** (⌘E) opens files in TextMate for editing. In the Files tab it opens the selected files on the side whose tree has focus (the left one unless you clicked the right). Each tree's context menu has the same command for its own side. In a file tab, the command is titled **Edit Left in TextMate** or **Edit Right in TextMate** after the focused side, and opens that side's file at the current change. Folders, and entries missing on that side, are not opened. Compare uses the TextMate it is embedded in, so a development build opens files in the development TextMate.

Compare notices the saved file changing on disk and compares again, keeping the file tab on the same change. Unsaved edits in TextMate are not compared.

## Settings

**Compare → Settings…** (⌘,) opens Compare's settings.

- **Ignore folders and files** is a comma-separated list of folder and file names that never appear in a comparison, on either side, together with everything inside them. The default is `node_modules`. Names may use the wildcards `*`, `?` and `[abc]`, so `*.log` hides every log file. A name with a slash, such as `docs/build` or `packages/*/dist`, matches a path from the top of the compared folders instead of a name at any depth. Case is ignored. Ignored entries are not listed, counted, copied as part of a folder, or watched: changes inside them do not compare again. They stay hidden with **Show Ignored Files** on, which concerns `.gitignore`. Leave the field empty to show everything.

A change takes effect when you press Return, leave the field, or close the window, and every open comparison compares again.

## Copying changes

Changes can be copied in either direction.

- **In the Files tab**, click the → or ← arrow between the two trees, beside an entry, to copy that entry to the right or to the left; arrows appear only on rows that are differences themselves, and only where there is something to copy in that direction. Folders that merely contain differences (default background, amber dot) have no arrows; select one and use the menu commands below to copy everything that differs inside it. To copy several entries, select them and choose **Edit → Copy to the Right** (⌥⌘→) or **Copy to the Left** (⌥⌘←), or use the same commands in either tree's context menu. A file or link replaces the other side's entry. A folder copies every differing entry inside it; entries only on the destination side are left alone. Where the destination has a folder in place of a file, or a file in place of a folder, that entry is moved to the Trash first. Copying more than one item, or replacing a folder or file of the other kind, asks for confirmation first.
- **Move to Trash** in a tree's context menu moves that side's entries to the Trash.
- **In a file tab**, the arrows between the two sides, next to each change, copy that change to the right (→) or to the left (←). **Edit → Copy Change to the Right** and **Copy Change to the Left** copy the current change. The tab stays on the same change number afterwards.

Compare only writes over what it compared: if a file changed on disk since it was compared, the copy is refused and asks you to compare again. Copies and their Undo never write outside the two compared folders, and never through a symbolic link that has taken the place of a folder (or of a compared folder itself) since the comparison. Unsaved changes in TextMate are not part of the comparison: Compare reads and writes the files on disk, and TextMate treats its writes like those of any other program.

Every write replaces the file atomically and keeps its permissions. **Edit → Undo** (⌘Z) reverses the last copy or move to the Trash, and **Redo** (⇧⌘Z) does it again. Undo is refused when a file has changed since, and Redo when anything it would change has changed since the Undo, including anything inside a folder it would move to the Trash.

## Development

`make` builds `Compare.app` and the `tm-compare` launcher and embeds them in TextMate's `Contents/Helpers` and `Contents/MacOS`. TextMate opens comparisons with a `textmate-compare://compare?left=…&right=…&focus=…` URL; `src/compare_url.h` builds and parses it for the launcher, the app and TextMate's **Compare To** menu (`Applications/TextMate/src/WorktreeCompareMenu.mm`, which reuses the command palette's worktree discovery).

| File | Contents |
|---|---|
| `src/compare_tree.{h,mm}` | Listing (`git ls-files`, or a folder walk), the Ignore folders and files patterns (`compare_excludes_t`), classification, stamps, re-reading changed entries, `git check-ignore` |
| `src/compare_diff.{h,mm}` | Line diff (xdiff histogram) as aligned rows and hunks |
| `src/compare_transfer.{h,mm}` | Undoable change sets, tree copies and moves to the Trash, applying one change |
| `src/compare_watch.h` | FSEvents wrapper, also used by TextMate's menu |
| `src/compare_syntax.{h,mm}` | Syntax highlighting as TextMate's editor chooses it: file type, settings, font, theme, grammar parsed line by line |
| `src/CompareWindowController.mm` | Window, tabs (`OakTabBarView`), trees (`FileBrowserOutlineView`, `FileItemTableCellView`), transfers and undo |
| `src/CompareDiffView.mm` | File tab: text views, full-width line tints, line numbers, change arrows |
| `src/CompareSettings.mm` | Settings (stored in Compare's defaults, `compareExcludedNames`) and the Settings window |
| `src/compare_menu.h` | The View menu, shared with the tests |

Tests (see CLAUDE.md for running them):

| Suite | Covers |
|---|---|
| `compare` | URL encoding (Compare's and TextMate's `txmt://open`), hunk model |
| `compare-tree` | Listing and classification against a repository with a linked worktree, `check-ignore`, branch labels, ignore patterns |
| `compare-syntax` | Highlighting with a test bundle: file type, theme colors and font traits, parser state across lines, UTF-16 ranges, dark theme, files without a grammar, size limit |
| `compare-transfer` | Applying changes, change sets and undo, tree copies, type changes, refused copies, the Trash |
| `compare-window` | The real window: alignment, tints, sync, filters, focus, tabs, transfers with undo, live refresh, search, remembered expansion, the Settings window |
| `compare-launch` | The signed app binary starts (library validation) |
| `tm-compare-help`, `tm-compare-rejects-missing-folder` | The launcher |
| `worktree-compare-menu` | TextMate's **Compare To** menu: hidden without other worktrees, entries and the URL they open, following worktrees added or removed by Git |

`compare-window` needs a GUI session. It also checks real window pixels (the same row's tint on both sides, a changed line's tint), which catches views covered by others; snapshots of the view hierarchy do not. With `COMPARE_SNAPSHOT_DIR` set it writes light and dark PNG snapshots for looking at.

Custom-drawn views (`CompareTreeStrip`, `CompareChangeStrip`, the line-number ruler, separators, row views) return YES from `clipsToBounds` and fill only within their bounds. Views do not clip by default since macOS 14, and a strip that filled its whole dirty rect once grew its backing layer to the window and covered everything drawn before it.

The app icon, `resources/Compare.icns`, is drawn from TextMate's own icon by `resources/make_icon.swift`: two flowers, one over the other, with → and ← above them. After changing the script, run `swift Applications/Compare/resources/make_icon.swift` from the repository root and commit the new `Compare.icns`; the script also writes an uncommitted 1024 px `Compare-preview.png`.

Compare.app links the FileBrowser and OakTabBarView static libraries and bundles their images and TMFileReference's file-type icons, which static libraries cannot carry. FileBrowser pulls in `libOakSwiftUI.dylib`, so ad-hoc signed builds need `com.apple.security.cs.disable-library-validation`, as ThemeEditor does.
