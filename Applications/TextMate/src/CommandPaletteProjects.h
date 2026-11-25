#import <Foundation/Foundation.h>

// Worker-thread, read-only discovery. Each entry is keyed by its canonical
// worktree root; projects below that root inherit its branch information.
NSDictionary<NSString*, NSDictionary*>* CommandPaletteWorktrees(NSArray<NSString*>* paths, NSString* git, NSProgress* progress = nil);
NSString* CommandPaletteCanonicalPath(NSString* path);
NSDictionary* CommandPaletteWorktreeForPath(NSDictionary<NSString*, NSDictionary*>* worktrees, NSString* path);
// Repository name from a remote URL (https, scp-style, or local path), without ".git".
NSString* CommandPaletteRepositoryName(NSString* remoteURL);
// Whether new worktrees belong beside this repository's main checkout: it was
// created with the worktrees layout, or its parent folder is named after it.
BOOL CommandPaletteUsesWorktreeLayout(NSDictionary* metadata);
NSArray<NSString*>* CommandPaletteWorkspacePaths(NSArray<NSString*>* paths, NSDictionary<NSString*, NSDictionary*>* worktrees);
