#ifndef COMPARE_TREE_H_R3N8VZ1D
#define COMPARE_TREE_H_R3N8VZ1D

#import <Foundation/Foundation.h>

// What a path is on one side of the comparison.
typedef NS_ENUM(uint8_t, CompareKind) {
	CompareKindNone = 0,   // missing on this side
	CompareKindFile,
	CompareKindDirectory,
	CompareKindSymlink,
	CompareKindOther,      // nested repository, submodule, socket, …
};

// A node's own status. Statuses are bits so a folder's `mask` can say which
// statuses occur anywhere below it.
typedef NS_OPTIONS(uint8_t, CompareStatus) {
	CompareStatusIdentical   = 1 << 0,
	CompareStatusModified    = 1 << 1, // file contents differ; folder contains differences
	CompareStatusLeftOnly    = 1 << 2,
	CompareStatusRightOnly   = 1 << 3,
	CompareStatusTypeChanged = 1 << 4, // e.g. a file on one side, a folder or link on the other
};

static CompareStatus const CompareStatusDifferent = CompareStatusModified|CompareStatusLeftOnly|CompareStatusRightOnly|CompareStatusTypeChanged;

@interface CompareNode : NSObject
@property (nonatomic, readonly) NSString* name;
@property (nonatomic, readonly) NSString* relativePath;  // precomposed; @"" for the root
@property (nonatomic, readonly) NSString* leftPath;      // absolute on-disk path; nil when missing
@property (nonatomic, readonly) NSString* rightPath;     // absolute on-disk path; nil when missing
@property (nonatomic, readonly) CompareKind leftKind;
@property (nonatomic, readonly) CompareKind rightKind;
@property (nonatomic, readonly) CompareStatus status;
@property (nonatomic, readonly) CompareStatus mask;      // status | all descendants' statuses
@property (nonatomic, readonly) NSArray<CompareNode*>* children; // nil for leaves; folders first, then by name
@property (nonatomic, readonly, weak) CompareNode* parent;
@property (nonatomic, readonly, getter = isFolder) BOOL folder;
- (CompareNode*)nodeAtRelativePath:(NSString*)relativePath;
@end

struct compare_options_t
{
	NSString* git          = nil; // nil: compare plain folder listings
	BOOL include_ignored   = NO;
	BOOL folders_first     = YES;
	BOOL (^cancelled)()    = nil;
};

// Relative paths of every non-folder entry below `root`. Uses
// `git ls-files --cached --others --exclude-standard` when `git` is set and
// `root` is inside a work tree (unless ignored files are included), otherwise
// walks the folder. `.git` is never listed. Entries that no longer exist on
// disk (deleted but still tracked) are skipped.
NSArray<NSString*>* CompareListEntries (NSString* root, compare_options_t const& options);

// Compares the two roots. Runs synchronously; call it from a worker queue.
// Returns nil when cancelled.
CompareNode* CompareBuildTree (NSString* left, NSString* right, compare_options_t const& options);

// The branch checked out at `root` (“detached 1a2b3c4” without one), or nil
// when `root` is not in a Git work tree.
NSString* CompareBranchLabel (NSString* root, NSString* git);

// Counts of leaf nodes (files, links, …) by status, keyed by @(CompareStatus).
// Folders whose type changed count once as CompareStatusTypeChanged.
NSDictionary<NSNumber*, NSNumber*>* CompareLeafCounts (CompareNode* root);

#endif /* end of include guard: COMPARE_TREE_H_R3N8VZ1D */
