#ifndef COMPARE_TREE_H_R3N8VZ1D
#define COMPARE_TREE_H_R3N8VZ1D

#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <string>
#include <vector>

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

// What an entry looked like on disk when it was compared; used to refuse
// overwriting anything that has changed since. `exists` is false for a
// missing entry.
struct compare_stamp_t
{
	bool exists = false;
	dev_t dev = 0;
	ino_t ino = 0;
	off_t size = 0;
	mode_t mode = 0;
	long mtime = 0, mtime_ns = 0;

	bool operator== (compare_stamp_t const& rhs) const
	{
		return exists == rhs.exists && (!exists || (dev == rhs.dev && ino == rhs.ino && size == rhs.size && mode == rhs.mode && mtime == rhs.mtime && mtime_ns == rhs.mtime_ns));
	}
	bool operator!= (compare_stamp_t const& rhs) const { return !(*this == rhs); }
};

compare_stamp_t CompareStampAtPath (NSString* path); // lstat: links are not followed

@interface CompareNode : NSObject
@property (nonatomic, readonly) NSString* name;
@property (nonatomic, readonly) NSString* relativePath;  // precomposed; @"" for the root
@property (nonatomic, readonly) NSString* leftPath;      // absolute on-disk path; nil when missing
@property (nonatomic, readonly) NSString* rightPath;     // absolute on-disk path; nil when missing
@property (nonatomic, readonly) CompareKind leftKind;
@property (nonatomic, readonly) CompareKind rightKind;
@property (nonatomic, readonly) compare_stamp_t leftStamp;
@property (nonatomic, readonly) compare_stamp_t rightStamp;
@property (nonatomic, readonly) CompareStatus status;
@property (nonatomic, readonly) CompareStatus mask;      // status | all descendants' statuses
@property (nonatomic, readonly) NSArray<CompareNode*>* children; // nil for leaves; folders first, then by name
@property (nonatomic, readonly, weak) CompareNode* parent;
@property (nonatomic, readonly, getter = isFolder) BOOL folder;
- (CompareNode*)nodeAtRelativePath:(NSString*)relativePath;
- (CompareNode*)root;
// The entry's path on one side; for a missing entry, where it would be.
- (NSString*)pathOnLeft:(BOOL)left;
@end

// Names (and paths) never shown in a comparison: Settings → “Ignore folders
// and files”, a comma-separated list of fnmatch patterns (* ? [abc]), matched
// ignoring case. A pattern without a slash matches any file or folder name at
// any depth; with a slash it matches a relative path from the roots (leading
// and trailing slashes are dropped). A matched folder hides everything in it.
struct compare_excludes_t
{
	compare_excludes_t () = default;
	explicit compare_excludes_t (NSString* list);
	bool empty () const { return _names.empty() && _paths.empty(); }
	// `relativePath` is relative to the roots, “/”-separated.
	bool matches (NSString* relativePath) const;
	NSArray<NSString*>* patterns () const; // as parsed, for display and tests

private:
	std::vector<std::string> _names;
	std::vector<std::string> _paths;
};

struct compare_options_t
{
	compare_excludes_t excludes;
	NSString* git          = nil; // nil: compare plain folder listings
	BOOL include_ignored   = NO;
	BOOL folders_first     = YES;
	BOOL (^cancelled)()    = nil;
	NSTimeInterval git_timeout = 60;          // listing with Git longer than this fails the comparison
	void (^failed)(NSString* reason) = nil;   // why a listing failed (not called when cancelled)
};

// Relative paths of every non-folder entry below `root`. Uses
// `git ls-files --cached --others --exclude-standard` when `git` is set and
// `root` is inside a work tree (unless ignored files are included), otherwise
// walks the folder. `.git` and entries matching `options.excludes` are never
// listed (a walk does not enter excluded folders). Entries that no longer exist on
// disk (deleted but still tracked) are skipped. When Git takes longer than
// `git_timeout` the listing fails (nil, and `failed` is told why) rather than
// walking the folder, which would include ignored files.
NSArray<NSString*>* CompareListEntries (NSString* root, compare_options_t const& options);

// Compares the two roots. Runs synchronously; call it from a worker queue.
// Returns nil when cancelled.
CompareNode* CompareBuildTree (NSString* left, NSString* right, compare_options_t const& options);

// Re-reads `node` (and everything below it) from disk after it was changed,
// re-classifies it, removes entries now missing on both sides and updates
// the folders above it. Reads file contents, so use it for the changed
// entries only.
void CompareRestat (CompareNode* node, compare_options_t const& options);

// Like CompareRestat for entries given by relative path below `root`,
// including entries that reappeared (an undone move to the Trash): missing
// nodes are created, and a folder's contents are listed again.
void CompareRestatPaths (CompareNode* root, NSArray<NSString*>* relativePaths, compare_options_t const& options);

// One entry for two files (a comparison started on files rather than
// folders): its relativePath is @"" and, unlike other nodes, it keeps both
// paths when a file is missing, so changes can recreate it.
CompareNode* CompareFilePair (NSString* left, NSString* right);

// Which of `relativePaths` (below `root`) Git ignores (`git check-ignore`);
// empty without Git. Paths are returned precomposed.
NSSet<NSString*>* CompareIgnoredPaths (NSString* root, NSArray<NSString*>* relativePaths, NSString* git);

// The branch checked out at `root` (“detached 1a2b3c4” without one), or nil
// when `root` is not in a Git work tree.
NSString* CompareBranchLabel (NSString* root, NSString* git);

// Counts of leaf nodes (files, links, …) by status, keyed by @(CompareStatus).
// A folder whose type changed counts once as CompareStatusTypeChanged, and
// its contents are not counted again.
NSDictionary<NSNumber*, NSNumber*>* CompareLeafCounts (CompareNode* root);

#endif /* end of include guard: COMPARE_TREE_H_R3N8VZ1D */
