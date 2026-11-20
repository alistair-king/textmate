#import "compare_transfer.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <vector>

// ===============
// = Change sets =
// ===============

namespace {

	enum class change_kind { write, trash };

	struct change_t
	{
		change_kind kind;
		NSString* path;
		NSString* backup = nil;          // write: the replaced entry, nil when there was none
		NSURL* trashed = nil;            // trash: where the entry went
		std::vector<NSString*> folders;  // write: parent folders this change created
		compare_stamp_t after;           // what `path` looked like right after the change
	};

	NSString* DisplayName (NSString* path)
	{
		return [NSString stringWithFormat:@"“%@”", path.lastPathComponent];
	}

	NSString* TemporaryPathNextTo (NSString* path)
	{
		NSString* name = [NSString stringWithFormat:@".%@.tm-compare-%@", path.lastPathComponent, NSUUID.UUID.UUIDString];
		return [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:name];
	}

	// Renames `temporary` over `path`; on failure removes `temporary`.
	BOOL MoveIntoPlace (NSString* temporary, NSString* path, NSString** error)
	{
		if(rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation) == 0)
			return YES;
		NSString* reason = @(strerror(errno));
		[NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
		if(error)
			*error = [NSString stringWithFormat:@"%@ could not be replaced: %@.", DisplayName(path), reason];
		return NO;
	}

}

@implementation CompareChangeSet
{
	std::vector<change_t> _changes;
	NSString* _backupFolder;
	NSUInteger _backups;
}

- (NSUInteger)count
{
	return _changes.size();
}

- (NSString*)backupFolder
{
	if(!_backupFolder)
	{
		_backupFolder = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"com.macromates.TextMate.Compare/undo/" stringByAppendingString:NSUUID.UUID.UUIDString]];
		[NSFileManager.defaultManager createDirectoryAtPath:_backupFolder withIntermediateDirectories:YES attributes:nil error:nil];
	}
	return _backupFolder;
}

- (void)dealloc
{
	if(_backupFolder)
		[NSFileManager.defaultManager removeItemAtPath:_backupFolder error:nil];
}

// Creates missing parent folders, recording them for undo.
- (BOOL)createParentOf:(NSString*)path folders:(std::vector<NSString*>&)created error:(NSString**)error
{
	NSMutableArray<NSString*>* missing = [NSMutableArray array];
	for(NSString* folder = path.stringByDeletingLastPathComponent; folder.length > 1; folder = folder.stringByDeletingLastPathComponent)
	{
		compare_stamp_t stamp = CompareStampAtPath(folder);
		if(stamp.exists)
		{
			if(!S_ISDIR(stamp.mode))
			{
				if(error)
					*error = [NSString stringWithFormat:@"%@ is not a folder.", folder.stringByAbbreviatingWithTildeInPath];
				return NO;
			}
			break;
		}
		[missing insertObject:folder atIndex:0];
	}
	for(NSString* folder in missing)
	{
		if(mkdir(folder.fileSystemRepresentation, 0777) != 0 && errno != EEXIST)
		{
			if(error)
				*error = [NSString stringWithFormat:@"The folder %@ could not be created: %s.", DisplayName(folder), strerror(errno)];
			return NO;
		}
		created.push_back(folder);
	}
	return YES;
}

// Copies the existing entry at `path` into the backup folder.
- (BOOL)backUp:(NSString*)path into:(NSString* __strong*)backup error:(NSString**)error
{
	*backup = nil;
	compare_stamp_t stamp = CompareStampAtPath(path);
	if(!stamp.exists)
		return YES;
	if(S_ISDIR(stamp.mode))
	{
		if(error)
			*error = [NSString stringWithFormat:@"%@ is a folder.", DisplayName(path)];
		return NO;
	}
	NSString* destination = [self.backupFolder stringByAppendingPathComponent:[NSString stringWithFormat:@"%lu", (unsigned long)++_backups]];
	NSError* copyError = nil;
	if(![NSFileManager.defaultManager copyItemAtPath:path toPath:destination error:&copyError])
	{
		if(error)
			*error = [NSString stringWithFormat:@"%@ could not be backed up for undo: %@", DisplayName(path), copyError.localizedDescription];
		return NO;
	}
	*backup = destination;
	return YES;
}

- (BOOL)copyItemAtPath:(NSString*)source toPath:(NSString*)path error:(NSString**)error
{
	change_t change = { change_kind::write, path };
	if(![self createParentOf:path folders:change.folders error:error] || ![self backUp:path into:&change.backup error:error])
		return NO;
	NSString* temporary = TemporaryPathNextTo(path);
	NSError* copyError = nil;
	if(![NSFileManager.defaultManager copyItemAtPath:source toPath:temporary error:&copyError])
	{
		if(error)
			*error = [NSString stringWithFormat:@"%@ could not be copied: %@", DisplayName(source), copyError.localizedDescription];
		return NO;
	}
	if(!MoveIntoPlace(temporary, path, error))
		return NO;
	change.after = CompareStampAtPath(path);
	_changes.push_back(change);
	return YES;
}

- (BOOL)writeData:(NSData*)data toPath:(NSString*)path mode:(mode_t)mode error:(NSString**)error
{
	change_t change = { change_kind::write, path };
	if(![self createParentOf:path folders:change.folders error:error] || ![self backUp:path into:&change.backup error:error])
		return NO;
	compare_stamp_t existing = CompareStampAtPath(path);
	NSString* temporary = TemporaryPathNextTo(path);
	if(![data writeToFile:temporary options:0 error:nil] || chmod(temporary.fileSystemRepresentation, (existing.exists ? existing.mode : mode) & 07777) != 0)
	{
		[NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
		if(error)
			*error = [NSString stringWithFormat:@"%@ could not be written.", DisplayName(path)];
		return NO;
	}
	if(!MoveIntoPlace(temporary, path, error))
		return NO;
	change.after = CompareStampAtPath(path);
	_changes.push_back(change);
	return YES;
}

- (BOOL)trashItemAtPath:(NSString*)path error:(NSString**)error
{
	NSURL* trashed = nil;
	NSError* trashError = nil;
	if(![NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:path] resultingItemURL:&trashed error:&trashError])
	{
		if(error)
			*error = [NSString stringWithFormat:@"%@ could not be moved to the Trash: %@", DisplayName(path), trashError.localizedDescription];
		return NO;
	}
	change_t change = { change_kind::trash, path };
	change.trashed = trashed;
	change.after   = CompareStampAtPath(path);
	_changes.push_back(change);
	return YES;
}

- (BOOL)undo:(NSString**)error
{
	// Check everything first so a refused undo changes nothing. A path changed
	// more than once (a folder trashed, then a file written in its place) must
	// look like its latest change left it.
	NSMutableSet<NSString*>* checked = [NSMutableSet set];
	for(auto it = _changes.rbegin(); it != _changes.rend(); ++it)
	{
		auto const& change = *it;
		if([checked containsObject:change.path])
			continue;
		[checked addObject:change.path];
		if(CompareStampAtPath(change.path) != change.after)
		{
			if(error)
				*error = [NSString stringWithFormat:@"%@ has changed since, so this change cannot be undone.", DisplayName(change.path)];
			return NO;
		}
		if(change.kind == change_kind::trash && ![NSFileManager.defaultManager fileExistsAtPath:change.trashed.path])
		{
			if(error)
				*error = [NSString stringWithFormat:@"%@ is no longer in the Trash.", DisplayName(change.path)];
			return NO;
		}
	}

	BOOL ok = YES;
	for(auto it = _changes.rbegin(); it != _changes.rend(); ++it)
	{
		NSString* problem = nil;
		if(it->kind == change_kind::trash)
		{
			NSError* moveError = nil;
			if(![NSFileManager.defaultManager moveItemAtURL:it->trashed toURL:[NSURL fileURLWithPath:it->path] error:&moveError])
				problem = moveError.localizedDescription;
		}
		else if(it->backup)
		{
			NSString* temporary = TemporaryPathNextTo(it->path);
			if(![NSFileManager.defaultManager copyItemAtPath:it->backup toPath:temporary error:nil])
				problem = @"its backup could not be restored";
			else if(!MoveIntoPlace(temporary, it->path, &problem))
				problem = problem ?: @"it could not be replaced";
		}
		else
		{
			// Created by this change: the other side still has it.
			if(unlink(it->path.fileSystemRepresentation) != 0)
				problem = @(strerror(errno));
			for(auto folder = it->folders.rbegin(); folder != it->folders.rend(); ++folder)
				rmdir((*folder).fileSystemRepresentation); // only if empty
		}
		if(problem)
		{
			ok = NO;
			if(error && !*error)
				*error = [NSString stringWithFormat:@"%@ could not be restored: %@", DisplayName(it->path), problem];
		}
	}
	_changes.clear();
	return ok;
}
@end

// ==================
// = Tree transfers =
// ==================

static BOOL Copyable (CompareKind kind)
{
	return kind == CompareKindFile || kind == CompareKindSymlink;
}

NSUInteger CompareCountCopies (CompareNode* node, BOOL toRight)
{
	if(!(node.mask & CompareStatusDifferent))
		return 0;
	CompareKind source = toRight ? node.leftKind : node.rightKind;
	if(!node.isFolder || Copyable(source))
		return Copyable(source) && node.status != CompareStatusIdentical ? 1 : 0;
	NSUInteger count = 0;
	for(CompareNode* child in node.children)
		count += CompareCountCopies(child, toRight);
	return count;
}

BOOL CompareCopyReplacesType (CompareNode* node, BOOL toRight)
{
	CompareKind source      = toRight ? node.leftKind : node.rightKind;
	CompareKind destination = toRight ? node.rightKind : node.leftKind;
	if(source != CompareKindNone && destination != CompareKindNone && (source == CompareKindDirectory) != (destination == CompareKindDirectory))
		return YES;
	if(source == CompareKindDirectory)
	{
		for(CompareNode* child in node.children)
		{
			if(CompareCopyReplacesType(child, toRight))
				return YES;
		}
	}
	return NO;
}

static NSString* ChangedError (CompareNode* node, BOOL left)
{
	return [NSString stringWithFormat:@"“%@” changed on the %@ since it was compared. Compare again, then try once more.", node.relativePath, left ? @"left" : @"right"];
}

// The destination side's entry is a file where a folder is needed, or the
// reverse: move it to the Trash first.
static BOOL ClearForCopy (CompareNode* node, BOOL toRight, BOOL needFolder, CompareChangeSet* changes, NSString** error)
{
	CompareKind destination = toRight ? node.rightKind : node.leftKind;
	if(destination == CompareKindNone || (destination == CompareKindDirectory) == needFolder)
		return YES;
	NSString* path = [node pathOnLeft:!toRight];
	if(CompareStampAtPath(path) != (toRight ? node.rightStamp : node.leftStamp))
	{
		if(error)
			*error = ChangedError(node, !toRight);
		return NO;
	}
	return [changes trashItemAtPath:path error:error];
}

static BOOL CopyNode (CompareNode* node, BOOL toRight, CompareChangeSet* changes, NSString** error)
{
	CompareKind source = toRight ? node.leftKind : node.rightKind;
	if(source == CompareKindNone || node.status == CompareStatusIdentical)
		return YES;

	if(source == CompareKindDirectory)
	{
		if(!ClearForCopy(node, toRight, YES, changes, error))
			return NO;
		for(CompareNode* child in node.children)
		{
			if(!CopyNode(child, toRight, changes, error))
				return NO;
		}
		return YES;
	}

	if(!Copyable(source))
		return YES; // submodules and other special entries are not copied

	NSString* from = [node pathOnLeft:toRight];
	NSString* to   = [node pathOnLeft:!toRight];
	if(CompareStampAtPath(from) != (toRight ? node.leftStamp : node.rightStamp))
	{
		if(error)
			*error = ChangedError(node, toRight);
		return NO;
	}
	BOOL replacesFolder = (toRight ? node.rightKind : node.leftKind) == CompareKindDirectory;
	if(!replacesFolder && CompareStampAtPath(to) != (toRight ? node.rightStamp : node.leftStamp))
	{
		if(error)
			*error = ChangedError(node, !toRight);
		return NO;
	}
	if(!ClearForCopy(node, toRight, NO, changes, error))
		return NO;
	return [changes copyItemAtPath:from toPath:to error:error];
}

BOOL CompareCopyNode (CompareNode* node, BOOL toRight, CompareChangeSet* changes, NSString** error)
{
	// A file in the way of a folder above the entry (one side has a file
	// where the other has a folder): replace it first.
	NSMutableArray<CompareNode*>* ancestors = [NSMutableArray array];
	for(CompareNode* ancestor = node.parent; ancestor.parent; ancestor = ancestor.parent)
		[ancestors insertObject:ancestor atIndex:0];
	for(CompareNode* ancestor in ancestors)
	{
		if(!ClearForCopy(ancestor, toRight, YES, changes, error))
			return NO;
	}
	return CopyNode(node, toRight, changes, error);
}

BOOL CompareTrashNode (CompareNode* node, BOOL leftSide, CompareChangeSet* changes, NSString** error)
{
	if((leftSide ? node.leftKind : node.rightKind) == CompareKindNone || !node.parent)
		return YES;
	NSString* path = [node pathOnLeft:leftSide];
	// Folders are checked by their own entry only; their contents may have
	// been listed without every file (ignored files are not compared).
	if(CompareStampAtPath(path) != (leftSide ? node.leftStamp : node.rightStamp) && !node.isFolder)
	{
		if(error)
			*error = ChangedError(node, leftSide);
		return NO;
	}
	return [changes trashItemAtPath:path error:error];
}

// ================
// = File changes =
// ================

namespace compare {

	// [start, end) of each line including its terminator, as xdiff splits them.
	static std::vector<NSRange> RawLines (NSData* data)
	{
		std::vector<NSRange> lines;
		char const* bytes = (char const*)data.bytes;
		NSUInteger start = 0, length = data.length;
		for(NSUInteger i = 0; i < length; ++i)
		{
			if(bytes[i] == '\n')
			{
				lines.push_back(NSMakeRange(start, i + 1 - start));
				start = i + 1;
			}
		}
		if(start < length)
			lines.push_back(NSMakeRange(start, length - start));
		return lines;
	}

	NSData* apply_hunk (NSData* left, NSData* right, diff_hunk_t const& hunk, bool toRight)
	{
		NSData* source      = toRight ? left : right;
		NSData* destination = toRight ? right : left;
		long sourceStart = toRight ? hunk.left_start  : hunk.right_start;
		long sourceCount = toRight ? hunk.left_count  : hunk.right_count;
		long destStart   = toRight ? hunk.right_start : hunk.left_start;
		long destCount   = toRight ? hunk.right_count : hunk.left_count;

		std::vector<NSRange> sourceLines = RawLines(source);
		std::vector<NSRange> destLines   = RawLines(destination);
		if(sourceStart + sourceCount > (long)sourceLines.size() || destStart + destCount > (long)destLines.size())
			return nil;

		struct piece_t { NSData* data; NSRange range; };
		std::vector<piece_t> pieces;
		for(long i = 0; i < destStart; ++i)
			pieces.push_back({ destination, destLines[i] });
		for(long i = sourceStart; i < sourceStart + sourceCount; ++i)
			pieces.push_back({ source, sourceLines[i] });
		for(long i = destStart + destCount; i < (long)destLines.size(); ++i)
			pieces.push_back({ destination, destLines[i] });

		BOOL crlf = memmem(destination.bytes, destination.length, "\r\n", 2) != nullptr;
		NSMutableData* result = [NSMutableData data];
		for(size_t i = 0; i < pieces.size(); ++i)
		{
			auto const& piece = pieces[i];
			[result appendBytes:(char const*)piece.data.bytes + piece.range.location length:piece.range.length];
			BOOL terminated = piece.range.length && ((char const*)piece.data.bytes)[NSMaxRange(piece.range) - 1] == '\n';
			if(!terminated && i + 1 < pieces.size())
				[result appendBytes:crlf ? "\r\n" : "\n" length:crlf ? 2 : 1];
		}
		return result;
	}

} /* compare */
