#ifndef COMPARE_TRANSFER_H_P6Z3LK0V
#define COMPARE_TRANSFER_H_P6Z3LK0V

#import <Foundation/Foundation.h>
#import "compare_tree.h"
#import "compare_diff.h"

// Reversible file changes. Every write is atomic (a temporary file renamed
// into place) and keeps what it replaced in a private backup folder, so
// -undo: can restore it. Undo refuses to touch anything that has changed
// since this change set wrote it; a path replaced by an identical copy (as an
// undo of a later change restores it) counts as unchanged.
@interface CompareChangeSet : NSObject
@property (nonatomic, readonly) NSUInteger count;

// Replaces or creates `path` with a copy of the file or symbolic link at
// `source`, keeping its permissions. Creates missing parent folders.
- (BOOL)copyItemAtPath:(NSString*)source toPath:(NSString*)path error:(NSString**)error;
// Replaces or creates the file at `path`. An existing file keeps its
// permissions; a new one gets `mode`.
- (BOOL)writeData:(NSData*)data toPath:(NSString*)path mode:(mode_t)mode error:(NSString**)error;
- (BOOL)trashItemAtPath:(NSString*)path error:(NSString**)error;
// Creates an empty folder (and missing parents); undo removes it if still empty.
- (BOOL)createFolderAtPath:(NSString*)path error:(NSString**)error;

// Every path this change set changed, in order.
@property (nonatomic, readonly) NSArray<NSString*>* paths;
// Where trashed entries went (tests empty the Trash with these).
@property (nonatomic, readonly) NSArray<NSURL*>* trashedURLs;

- (BOOL)undo:(NSString**)error;
@end

// How some paths look on disk at one moment, to tell later whether anything
// has changed them (an identical copy counts as unchanged, as for undo).
@interface CompareDiskSnapshot : NSObject
+ (instancetype)snapshotOfPaths:(NSArray<NSString*>*)paths;
@property (nonatomic, readonly) NSString* changedPath; // the first that changed, nil when none
@end

// =====================
// = Tree transfers =
// =====================

// Entries `CompareCopyNode` would write for `node`: differing files and links
// present on the source side, at or below it.
NSUInteger CompareCountCopies (CompareNode* node, BOOL toRight);
// Whether copying would also move something on the destination side to the
// Trash (a folder replaced by a file, or the reverse).
BOOL CompareCopyReplacesType (CompareNode* node, BOOL toRight);

// Copies `node` from one side to the other: a file or link replaces the other
// side's entry; a folder copies every differing entry below it (entries only
// on the destination side are left alone). Refuses, before writing anything
// for an entry, when either side changed on disk since it was compared.
BOOL CompareCopyNode (CompareNode* node, BOOL toRight, CompareChangeSet* changes, NSString** error);

// Moves one side's entry to the Trash, refusing when it changed since it was
// compared.
BOOL CompareTrashNode (CompareNode* node, BOOL leftSide, CompareChangeSet* changes, NSString** error);

// =================
// = File changes =
// =================

namespace compare {

	// The destination file with one hunk taken from the source: the hunk's
	// lines on the destination side are replaced by its lines on the source
	// side. Line terminators are kept as they are; a line that would end up
	// in the middle of the file without one gets the destination's (CRLF or LF).
	NSData* apply_hunk (NSData* left, NSData* right, diff_hunk_t const& hunk, bool toRight);

} /* compare */

#endif /* end of include guard: COMPARE_TRANSFER_H_P6Z3LK0V */
