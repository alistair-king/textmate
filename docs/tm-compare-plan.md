# tm-compare — Development Plan

Status: Phase 0 done (2026-11-20); Phase 1 next. This file is the working plan; it will be
replaced by `docs/compare.md` (user documentation) once the feature ships.

## Goal

A helper application, built like `tm-theme-editor`, that compares two entire
Git worktrees and lets the user manually copy differences from one worktree to
the other.

TextMate opens it from **Text → Compare To ▸ <worktree>**. That submenu
item is shown only when the current project's repository has more than one
worktree. Its items are the other worktrees.

## Decisions

1. **Direction:** changes can be copied in either direction. The current
   worktree is always on the left.
2. **Scope:** whole worktree roots are compared. TextMate passes the project
   path relative to the worktree root as `focus`, and the tree opens there.
3. **Ignored files:** `.gitignore` is respected by default (files from
   `git ls-files --cached --others --exclude-standard`), with an option to
   include ignored files.
4. **Unsaved buffers:** ignored. Only files on disk are compared and changed.
   TextMate reloads an unmodified open document when its file changes on disk;
   a modified document gets TextMate's normal conflict prompt.
5. **Tree UI:** built from the TextMate file browser's view classes, with
   differences shown as row background colours (see "Tree comparison view").

## Reusable building blocks already in the repo

| Need | Existing code |
|---|---|
| Helper app, launcher, embedding, signing | `Applications/ThemeEditor/CMakeLists.txt`, `Applications/ThemeEditor/src/launcher.mm`, `Applications/TextMate/CMakeLists.txt` (`textmate_embed`, `textmate_codesign_file`) |
| Opening from a menu with arguments via a URL scheme | `openThemeEditor:` in `Applications/TextMate/src/AppController Menus.mm` (`textmate-theme-editor://`) |
| Finding a project's worktrees | `CommandPaletteWorktrees()` in `Applications/TextMate/src/CommandPaletteProjects.mm`. It runs `git worktree list --porcelain -z` safely (timeout, cleaned `GIT_*` environment, no shell) and returns `relatedPaths` and `branchLabel` |
| File tree views | `Frameworks/FileBrowser`: `FileBrowserView`, `FileBrowserOutlineView`, `FileItemTableCellView`, `FileItem`, `OFBHeaderView` (details below) |
| Line diffs | `vendor/xdiff` (histogram), used by `Frameworks/scm/src/gutter_diff.cc` and `Frameworks/DocumentWindow/src/ProjectChanges.mm` |
| Menus that rebuild on open | `MBMenuDelegate delegateUsingSelector:`, as used by "Jump to Bookmark" (`Applications/TextMate/src/AppController.mm`) |
| Syntax-highlighted text views | ThemeEditor's `ThemePreviewView : OakDocumentView` |
| NSTextView diff rendering | `Frameworks/DocumentWindow/src/ProjectChangesWindowController.mm` |

## Architecture

### Binaries (same layout as ThemeEditor)

- `Applications/Compare/` builds `Compare.app`, embedded in `Contents/Helpers`,
  with bundle id `com.macromates.TextMate.Compare`.
- `tm-compare` goes in `Contents/MacOS`. Unlike `tm-theme-editor` it takes
  arguments: `tm-compare <left-dir> <right-dir>`. It builds a URL and opens the
  helper with it.
- URL scheme:
  `textmate-compare://compare?left=<path>&right=<path>[&focus=<relpath>]`.
- One app instance with one window per worktree pair. Asking for a pair that's
  already open brings that window to the front.
- Compare.app links the `FileBrowser` static library (plus its dependencies,
  as ThemeEditor already does for OakTextView, bundles and Preferences).

### TextMate side

1. Worktree discovery reuses `CommandPaletteWorktrees()` where it is, in
   `CommandPaletteProjects.mm`. It is already compiled into TextMate whether or
   not SwiftUI is enabled, so it was not moved. The menu logic lives in
   `Applications/TextMate/src/WorktreeCompareMenu.{h,mm}`.
2. The Text menu has a hidden `Compare To` item after "Filter Through
   Command…". `WorktreeCompareMenu` is its submenu's delegate. Each submenu
   item is titled `basename (branch)`, holds the other worktree's root, and
   runs `compareToWorktree:`.
3. Hiding the item: menus never wait for git. `WorktreeCompareMenu` caches
   worktrees per project path and refreshes them on a worker queue:
   - when the main window's project path changes (checked from
     `-applicationDidUpdate:`, a string comparison),
   - when TextMate becomes active,
   - and each time the submenu opens (for the next opening).

   The item is hidden until discovery finds at least one other worktree.
   Watching `<git-common-dir>/worktrees/` for changes is left for Phase 4.
4. `compareToWorktree:` works like `openThemeEditor:`. It passes the current
   worktree as `left`, the chosen one as `right`, and the project path relative
   to the worktree root as `focus`.

### Compare.app core

This is pure logic in headers, like ThemeEditor's `colors.h`/`ase.h`, so it can
be tested without a GUI.

- **File set:** run `git ls-files -z --cached --others --exclude-standard` in
  each tree and take the union of relative paths. With "include ignored files"
  on, enumerate the directory instead.
- **Classification:** identical, modified, left only, right only, binary,
  symlink, or type changed.
  - Fast path: compare sizes first, then bytes.
  - Later optimisation: skip reading clean tracked files whose index blob ids
    match (`git ls-files -s`).
  - A folder's status is aggregated from its descendants: "contains
    differences" if any descendant differs, otherwise identical. A folder that
    exists on only one side is "left only" or "right only".
- **File diff:** xdiff histogram output kept as a hunk structure rather than
  unified-diff text, so the UI can work on individual hunks.
- **Transfers:** copy a whole file or folder, delete a file (to the Trash), or
  apply a single hunk in either direction. The rules are:
  - Before writing, check that the target hasn't changed on disk since it was
    diffed (size, mtime or hash). This is the same "refuse to overwrite newer"
    rule ThemeEditor uses.
  - Write atomically (temp file then rename) and keep the file mode.
  - Keep an in-app undo stack of the earlier contents.
  - After each transfer, re-classify the affected path and its parent folders.

## Tree comparison view (based on the file browser)

### What is reused from `Frameworks/FileBrowser`

| Class | Use in Compare.app |
|---|---|
| `FileBrowserView` | Layout reference: header view, outline view and actions bar stacked vertically. Each side of the window gets the same arrangement. |
| `OFBHeaderView` | Header above each tree, showing the worktree name and branch. |
| `FileBrowserOutlineView` | Both trees. It already provides the will/did expand and collapse delegate hooks (`FileBrowserOutlineViewDelegate`) needed to mirror expansion between the two sides, plus its keyboard and context-menu handling. |
| `FileItemTableCellView` | Row cells: file icon (via `TMFileReference`), name with middle truncation, Finder tags. Its open and close buttons stay hidden because Compare.app has no tabs. |
| `FileItem` | Per-side item for icons, display names and file properties. Its existing `missing` flag marks the placeholder row on the side where a file doesn't exist. |

### What is not reused

`FileBrowserViewController` is not embedded. It is built around a single tree
and TextMate's session: navigation history, favourites, SCM data sources,
OakCommand and bundle integration, and disk operations in one location.
Compare.app gets its own `CompareTreeController`, which copies two of its
patterns:

- the outline data source and arranged-children ordering (`itemComparator`,
  `arrangeChildren:inParent:`), so ordering matches TextMate's file browser;
- the expansion-state handling, so the tree opens on `focus` and remembers
  expanded folders per worktree pair.

### Model

- `CompareNode`: relative path, left `FileItem` (or a placeholder), right
  `FileItem` (or a placeholder), status, and children.
- Children are built from the union of both sides' paths, so every node has a
  row on both sides even when the file exists on only one.
- Both outline views use the same `CompareNode` objects as their items. Each
  view's cell shows its own side's `FileItem`. This keeps the rows on the two
  sides aligned.

### Layout and behaviour

```
┌ left: develop (develop) ──────┬──┬ right: tm-compare (feature/x) ─┐
│ ▾ Applications                │  │ ▾ Applications                 │  ← folder tint: contains differences
│   ▾ Compare                   │→ │   ▸ (missing)                  │  ← left only: green left / grey right
│     main.mm                   │⇄ │     main.mm                    │  ← modified: amber both sides
│   README.md                   │  │   README.md                    │  ← identical: no background
│   (missing)                   │ ←│   NOTES.md                     │  ← right only: grey left / green right
└───────────────────────────────┴──┴────────────────────────────────┘
│ file diff for the selected row (phase 2)                           │
└────────────────────────────────────────────────────────────────────┘
```

- **Synchronised trees:** expanding or collapsing a folder on one side does the
  same on the other, using the `FileBrowserOutlineViewDelegate` hooks. The two
  clip views share a scroll position (bounds-change notifications), and
  selecting a row selects the same row on the other side.
- **Centre strip:** a narrow column between the trees with → and ← buttons on
  each differing row. A button copies that file or folder to the other side.
  Multi-selection with "Copy to Right" / "Copy to Left" works the same way.
- **Filters:** Changed (the default, which hides identical files and
  folders), Left only, Right only, All. There is also a name search field.
- **Context menu:** Copy to Other Side, Move to Trash, Reveal in Finder, Open in
  TextMate (via `mate`).

### Background colours

- Drawn by a custom `CompareRowView : NSTableRowView` returned from
  `outlineView:rowViewForItem:`. Its `drawBackgroundInRect:` fills the row with
  the status colour. Selection highlighting still draws on top, so selected
  rows stay readable.
- Colours are dynamic `NSColor`s with low alpha, defined for light and dark
  appearance, in one palette header shared with the file diff view:

| Status | Left row | Right row |
|---|---|---|
| Identical | none | none |
| Modified | amber | amber |
| Left only | green | grey placeholder |
| Right only | grey placeholder | green |
| Type changed / binary differs | red | red |
| Folder contains differences | light amber | light amber |

- Placeholder rows also show a dimmed name using `FileItem.missing`.

### File diff view (phase 2)

Selecting a modified file shows both versions side by side below the trees.
It uses the same palette for line backgrounds:

- changed lines in amber;
- inserted lines in green;
- deleted lines as a grey gap on the other side.

The centre strip gets per-hunk → and ← buttons. Start with two `NSTextView`s
using attributed backgrounds. Moving to `OakDocumentView` for syntax
highlighting can come later.

## Phases

Each phase ends with a green ctest suite (see CLAUDE.md → Testing).

| Phase | Delivers | Tests |
|---|---|---|
| **0. Skeleton** ✅ | Compare.app and tm-compare built, embedded and signed. URL handling works. The window shows the two paths. Worktree discovery is reused and the Text → Compare To menu is live. | `command-palette-projects` still green; launcher `--help` |
| **1. Tree comparison (read-only)** | File enumeration and classification. Two synchronised `FileBrowserOutlineView` trees with `FileItemTableCellView` cells, row background colours, filters and opening on `focus`. | `compare` suite: temp repo + `git worktree add` fixtures covering modified, one-side-only, ignored, binary, symlink and Unicode-normalised names; folder aggregation |
| **2. File diff view** | xdiff hunks, side-by-side view with line background colours, synchronised scroll, next/previous change | Hunk-model unit tests (empty files, missing trailing newline, CRLF) |
| **3. Transfers** | File and folder copy in both directions, delete to Trash, then per-hunk apply in both directions. Staleness check, undo, re-classify after each change. | Apply/undo round-trips; refusal when the target changed on disk; a GUI test bundle like `theme-editor-selection` |
| **4. Polish** | Live refresh via file-system events, "include ignored files" option, remembered expansion state, `docs/compare.md`, README | — |
