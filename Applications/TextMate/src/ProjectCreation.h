#import <Foundation/Foundation.h>

// Creating and importing projects. Everything here runs Git synchronously and
// is meant for a worker thread; errors carry Git's own message.

typedef NS_ENUM(NSInteger, ProjectCreationLayout) {
	// Name/ holds one folder per checkout; the default branch is Name/<branch>/.
	ProjectCreationLayoutWorktrees,
	// The repository is Name/ itself.
	ProjectCreationLayoutPlain,
};

// Local Git config key marking a repository created with the worktrees layout.
extern NSString* const kProjectCreationLayoutConfigKey;

// User-facing reason the name is unusable, or nil.
NSString* ProjectCreationNameProblem (NSString* name);
// Folder name for a branch checkout: "feature/x" → "feature-x".
NSString* ProjectCreationBranchDirectoryName (NSString* branch);
// Folder that holds the worktrees of the repository whose main checkout is given.
NSString* ProjectCreationWorktreeContainer (NSString* mainCheckout);

// Clones remoteURL (or runs git init when it is empty) into parent/name using
// the given layout. Returns the checkout to open; nothing is left behind on failure.
NSString* ProjectCreationCreate (NSString* parent, NSString* name, ProjectCreationLayout layout, NSString* remoteURL, NSString* git, NSError** error);
// Adds a worktree for branch beside mainCheckout. An existing local or
// origin branch is checked out; otherwise the branch starts at mainCheckout's HEAD.
NSString* ProjectCreationAddWorktree (NSString* mainCheckout, NSString* branch, NSString* git, NSError** error);
// Folder to open when importing: a worktree container opens its main checkout.
NSString* ProjectCreationImportPath (NSString* folder);
