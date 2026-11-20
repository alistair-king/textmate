#import "compare_tree.h"
#include <sys/stat.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <vector>

@interface CompareNode ()
@property (nonatomic, readwrite) NSString* name;
@property (nonatomic, readwrite) NSString* relativePath;
@property (nonatomic, readwrite) NSString* leftPath;
@property (nonatomic, readwrite) NSString* rightPath;
@property (nonatomic, readwrite) CompareKind leftKind;
@property (nonatomic, readwrite) CompareKind rightKind;
@property (nonatomic, readwrite) compare_stamp_t leftStamp;
@property (nonatomic, readwrite) compare_stamp_t rightStamp;
@property (nonatomic, readwrite) CompareStatus status;
@property (nonatomic, readwrite) CompareStatus mask;
@property (nonatomic, readwrite) NSArray<CompareNode*>* children;
@property (nonatomic, readwrite, weak) CompareNode* parent;
@property (nonatomic) NSMutableDictionary<NSString*, CompareNode*>* childrenByName;
@end

@implementation CompareNode
- (BOOL)isFolder
{
	return _childrenByName.count || _leftKind == CompareKindDirectory || _rightKind == CompareKindDirectory;
}

- (CompareNode*)nodeAtRelativePath:(NSString*)relativePath
{
	CompareNode* node = self;
	for(NSString* component in [relativePath.precomposedStringWithCanonicalMapping componentsSeparatedByString:@"/"])
	{
		if(component.length && !(node = node.childrenByName[component]))
			return nil;
	}
	return node;
}

- (CompareNode*)root
{
	CompareNode* node = self;
	while(node.parent)
		node = node.parent;
	return node;
}

- (NSString*)pathOnLeft:(BOOL)left
{
	if(NSString* path = left ? _leftPath : _rightPath)
		return path;
	CompareNode* root = self.root;
	NSString* base = left ? root.leftPath : root.rightPath;
	return _relativePath.length ? [base stringByAppendingPathComponent:_relativePath] : base;
}

- (NSString*)description
{
	return [NSString stringWithFormat:@"<CompareNode %@ status=%d mask=%d>", _relativePath, _status, _mask];
}
@end

// ==========
// = Listing =
// ==========

// Runs git with file-backed output, so large listings cannot deadlock a pipe.
static NSData* GitOutput (NSString* git, NSString* directory, NSArray<NSString*>* arguments, BOOL (^cancelled)(), NSData* input = nil, int acceptedStatus = 0)
{
	FILE* output = tmpfile();
	if(!output)
		return nil;
	NSFileHandle* handle = [[NSFileHandle alloc] initWithFileDescriptor:fileno(output) closeOnDealloc:NO];
	NSTask* task = [NSTask new];
	task.executableURL = [NSURL fileURLWithPath:git];
	task.arguments = [@[ @"--no-optional-locks", @"-c", @"core.fsmonitor=false", @"-C", directory ] arrayByAddingObjectsFromArray:arguments];
	NSMutableDictionary* environment = [NSProcessInfo.processInfo.environment mutableCopy];
	for(NSString* key in environment.allKeys)
	{
		if([key hasPrefix:@"GIT_"])
			[environment removeObjectForKey:key];
	}
	environment[@"GIT_TERMINAL_PROMPT"] = @"0";
	task.environment    = environment;
	task.standardOutput = handle;
	task.standardError  = task.standardInput = NSFileHandle.fileHandleWithNullDevice;
	NSPipe* inputPipe = input ? [NSPipe pipe] : nil;
	if(inputPipe)
		task.standardInput = inputPipe;

	dispatch_semaphore_t exited = dispatch_semaphore_create(0);
	task.terminationHandler = ^(NSTask*){ dispatch_semaphore_signal(exited); };
	NSData* result = nil;
	if([task launchAndReturnError:nil])
	{
		if(inputPipe)
		{
			// Written from another queue so a full pipe cannot block the wait below.
			NSFileHandle* writer = inputPipe.fileHandleForWriting;
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
				@try { [writer writeData:input]; } @catch(NSException*) { }
				[writer closeFile];
			});
		}
		BOOL stopped = NO;
		for(int waited = 0; dispatch_semaphore_wait(exited, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0; ++waited)
		{
			if((cancelled && cancelled()) || waited > 600) // 60 s
			{
				kill(task.processIdentifier, SIGKILL);
				stopped = YES;
				break;
			}
		}
		[task waitUntilExit];
		if(!stopped && (task.terminationStatus == 0 || task.terminationStatus == acceptedStatus))
		{
			[handle seekToFileOffset:0];
			result = [handle readDataToEndOfFile];
		}
	}
	fclose(output);
	return result;
}

static NSArray<NSString*>* GitEntries (NSString* root, NSString* git, BOOL (^cancelled)())
{
	NSData* data = GitOutput(git, root, @[ @"ls-files", @"-z", @"--cached", @"--others", @"--exclude-standard" ], cancelled);
	if(!data)
		return nil;

	NSMutableOrderedSet<NSString*>* entries = [NSMutableOrderedSet orderedSet];
	char const* bytes = (char const*)data.bytes;
	for(size_t start = 0, length = data.length; start < length; )
	{
		size_t end = start;
		while(end < length && bytes[end] != '\0')
			++end;
		size_t size = end - start;
		while(size && bytes[start + size - 1] == '/') // untracked nested repository
			--size;
		if(size)
		{
			if(NSString* path = [NSFileManager.defaultManager stringWithFileSystemRepresentation:bytes + start length:size])
				[entries addObject:path];
		}
		start = end + 1;
	}
	return entries.array;
}

static NSArray<NSString*>* WalkEntries (NSString* root, BOOL (^cancelled)())
{
	// The path-based enumerator yields paths relative to `root`, whatever
	// spelling (/var vs /private/var) the root was given in, and does not
	// descend into symbolic links.
	NSDirectoryEnumerator<NSString*>* enumerator = [NSFileManager.defaultManager enumeratorAtPath:root];
	NSMutableArray<NSString*>* entries = [NSMutableArray array];
	for(NSString* path in enumerator)
	{
		if(cancelled && cancelled())
			return nil;
		if([path.lastPathComponent isEqualToString:@".git"])
		{
			[enumerator skipDescendants];
			continue;
		}
		if(![enumerator.fileAttributes.fileType isEqualToString:NSFileTypeDirectory])
			[entries addObject:path];
	}
	return entries;
}

compare_stamp_t CompareStampAtPath (NSString* path)
{
	compare_stamp_t stamp;
	struct stat st;
	if(path && lstat(path.fileSystemRepresentation, &st) == 0)
	{
		stamp.exists   = true;
		stamp.dev      = st.st_dev;
		stamp.ino      = st.st_ino;
		stamp.size     = st.st_size;
		stamp.mode     = st.st_mode;
		stamp.mtime    = st.st_mtimespec.tv_sec;
		stamp.mtime_ns = st.st_mtimespec.tv_nsec;
	}
	return stamp;
}

static CompareKind KindForStamp (compare_stamp_t const& stamp, BOOL folderNode)
{
	if(!stamp.exists)
		return CompareKindNone;
	if(S_ISREG(stamp.mode))
		return CompareKindFile;
	if(S_ISLNK(stamp.mode))
		return CompareKindSymlink;
	if(S_ISDIR(stamp.mode))
		return folderNode ? CompareKindDirectory : CompareKindOther;
	return CompareKindOther;
}

static CompareKind KindAtPath (NSString* path)
{
	struct stat st;
	if(lstat(path.fileSystemRepresentation, &st) != 0)
		return CompareKindNone;
	if(S_ISREG(st.st_mode))
		return CompareKindFile;
	if(S_ISLNK(st.st_mode))
		return CompareKindSymlink;
	// A folder listed as an entry is a submodule or nested repository.
	return CompareKindOther;
}

NSArray<NSString*>* CompareListEntries (NSString* root, compare_options_t const& options)
{
	NSArray<NSString*>* entries = nil;
	if(options.git && !options.include_ignored)
		entries = GitEntries(root, options.git, options.cancelled);
	if(!entries && !(options.cancelled && options.cancelled()))
		entries = WalkEntries(root, options.cancelled);

	NSMutableArray<NSString*>* existing = [NSMutableArray arrayWithCapacity:entries.count];
	for(NSString* entry in entries)
	{
		if(KindAtPath([root stringByAppendingPathComponent:entry]) != CompareKindNone)
			[existing addObject:entry];
	}
	return entries ? existing : nil;
}

// =================
// = Classification =
// =================

static BOOL SameContents (NSString* lhs, NSString* rhs)
{
	FILE* a = fopen(lhs.fileSystemRepresentation, "rb");
	FILE* b = a ? fopen(rhs.fileSystemRepresentation, "rb") : nullptr;
	BOOL same = NO;
	if(a && b)
	{
		struct stat sa, sb;
		if(fstat(fileno(a), &sa) == 0 && fstat(fileno(b), &sb) == 0 && sa.st_size == sb.st_size)
		{
			std::vector<char> bufA(256 * 1024), bufB(256 * 1024);
			same = YES;
			while(same)
			{
				size_t lenA = fread(bufA.data(), 1, bufA.size(), a);
				size_t lenB = fread(bufB.data(), 1, bufB.size(), b);
				if(lenA != lenB || memcmp(bufA.data(), bufB.data(), lenA) != 0)
					same = NO;
				else if(lenA == 0)
					break;
			}
			if(ferror(a) || ferror(b))
				same = NO;
		}
	}
	if(a) fclose(a);
	if(b) fclose(b);
	return same;
}

static BOOL SameLinkTarget (NSString* lhs, NSString* rhs)
{
	NSString* a = [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:lhs error:nil];
	NSString* b = [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:rhs error:nil];
	return a && b && [a isEqualToString:b];
}

// Returns NO when cancelled.
static BOOL Classify (CompareNode* node, compare_options_t const& options)
{
	if(options.cancelled && options.cancelled())
		return NO;

	if(node.isFolder)
	{
		CompareStatus childMask = 0;
		for(CompareNode* child in node.childrenByName.allValues)
		{
			if(!Classify(child, options))
				return NO;
			childMask |= child.mask;
		}

		NSArray* children = node.childrenByName.allValues;
		BOOL foldersFirst = options.folders_first;
		node.children = [children sortedArrayUsingComparator:^NSComparisonResult(CompareNode* lhs, CompareNode* rhs){
			if(foldersFirst && lhs.isFolder != rhs.isFolder)
				return lhs.isFolder ? NSOrderedAscending : NSOrderedDescending;
			return [lhs.name localizedStandardCompare:rhs.name];
		}];

		if(node.leftKind == CompareKindDirectory && node.rightKind == CompareKindDirectory)
			node.status = (childMask & CompareStatusDifferent) ? CompareStatusModified : CompareStatusIdentical;
		else if(node.leftKind == CompareKindNone)
			node.status = CompareStatusRightOnly;
		else if(node.rightKind == CompareKindNone)
			node.status = CompareStatusLeftOnly;
		else
			node.status = CompareStatusTypeChanged;
		node.mask = node.status | childMask;
		return YES;
	}

	if(node.leftKind == CompareKindNone)
		node.status = CompareStatusRightOnly;
	else if(node.rightKind == CompareKindNone)
		node.status = CompareStatusLeftOnly;
	else if(node.leftKind != node.rightKind)
		node.status = CompareStatusTypeChanged;
	else if(node.leftKind == CompareKindFile)
		node.status = SameContents(node.leftPath, node.rightPath) ? CompareStatusIdentical : CompareStatusModified;
	else if(node.leftKind == CompareKindSymlink)
		node.status = SameLinkTarget(node.leftPath, node.rightPath) ? CompareStatusIdentical : CompareStatusModified;
	else
		node.status = CompareStatusIdentical; // submodules are not compared
	node.mask = node.status;
	return YES;
}

static CompareNode* NewNode (NSString* name, NSString* relativePath, CompareNode* parent)
{
	CompareNode* node = [CompareNode new];
	node.name           = name;
	node.relativePath   = relativePath;
	node.parent         = parent;
	node.childrenByName = [NSMutableDictionary dictionary];
	return node;
}

CompareNode* CompareBuildTree (NSString* left, NSString* right, compare_options_t const& options)
{
	CompareNode* root = NewNode(@"", @"", nil);
	root.leftPath  = left;
	root.rightPath = right;
	root.leftKind  = CompareKindDirectory;
	root.rightKind = CompareKindDirectory;

	for(BOOL isLeft : { YES, NO })
	{
		NSString* base = isLeft ? left : right;
		NSArray<NSString*>* entries = CompareListEntries(base, options);
		if(!entries)
			return nil;

		for(NSString* entry in entries)
		{
			NSArray<NSString*>* components = [entry componentsSeparatedByString:@"/"];
			CompareNode* node = root;
			NSString* onDisk = base;
			for(NSUInteger i = 0; i < components.count; ++i)
			{
				NSString* component = components[i];
				NSString* key = component.precomposedStringWithCanonicalMapping;
				onDisk = [onDisk stringByAppendingPathComponent:component];

				CompareNode* child = node.childrenByName[key];
				if(!child)
				{
					child = NewNode(key, node.relativePath.length ? [node.relativePath stringByAppendingFormat:@"/%@", key] : key, node);
					node.childrenByName[key] = child;
				}

				BOOL leaf = i + 1 == components.count;
				if(isLeft ? !child.leftPath : !child.rightPath)
				{
					compare_stamp_t stamp = CompareStampAtPath(onDisk);
					CompareKind kind = leaf ? KindForStamp(stamp, NO) : CompareKindDirectory;
					if(isLeft) { child.leftPath  = onDisk; child.leftKind  = kind; child.leftStamp  = stamp; }
					else       { child.rightPath = onDisk; child.rightKind = kind; child.rightStamp = stamp; }
				}
				node = child;
			}
		}
	}

	// Leaves keep an empty dictionary only while building; `children` stays nil.
	return Classify(root, options) ? root : nil;
}

NSSet<NSString*>* CompareIgnoredPaths (NSString* root, NSArray<NSString*>* relativePaths, NSString* git)
{
	NSMutableSet<NSString*>* ignored = [NSMutableSet set];
	if(!git || !relativePaths.count)
		return ignored;
	NSMutableData* input = [NSMutableData data];
	for(NSString* path in relativePaths)
	{
		[input appendBytes:path.fileSystemRepresentation length:strlen(path.fileSystemRepresentation)];
		[input appendBytes:"" length:1];
	}
	// Exit status 1 means “none of these are ignored”.
	NSData* data = GitOutput(git, root, @[ @"check-ignore", @"-z", @"--stdin" ], nil, input, 1);
	for(NSString* path in [[[NSString alloc] initWithData:data ?: [NSData data] encoding:NSUTF8StringEncoding] componentsSeparatedByString:@"\0"])
	{
		if(path.length)
			[ignored addObject:path.precomposedStringWithCanonicalMapping];
	}
	return ignored;
}

NSString* CompareBranchLabel (NSString* root, NSString* git)
{
	if(!git)
		return nil;
	auto line = ^NSString*(NSArray* arguments){
		NSData* data = GitOutput(git, root, arguments, nil);
		NSString* text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
		text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
		return text.length ? text : nil;
	};
	if(NSString* branch = line(@[ @"symbolic-ref", @"--short", @"-q", @"HEAD" ]))
		return branch;
	if(NSString* commit = line(@[ @"rev-parse", @"--short", @"HEAD" ]))
		return [@"detached " stringByAppendingString:commit];
	return nil;
}

// ===========================
// = Re-reading changed entries =
// ===========================

static BOOL HasFolderShape (CompareNode* node)
{
	return node.childrenByName.count != 0;
}

// Re-reads both sides of `node` and its descendants. Returns NO when the entry
// is now missing on both sides (the caller removes it).
static BOOL Reread (CompareNode* node)
{
	for(CompareNode* child in node.childrenByName.allValues)
	{
		if(!Reread(child))
			[node.childrenByName removeObjectForKey:child.name];
	}
	for(BOOL left : { YES, NO })
	{
		NSString* path = [node pathOnLeft:left];
		compare_stamp_t stamp = CompareStampAtPath(path);
		CompareKind kind = KindForStamp(stamp, HasFolderShape(node) || (left ? node.leftKind : node.rightKind) == CompareKindDirectory);
		if(left) { node.leftPath  = stamp.exists ? path : nil; node.leftKind  = kind; node.leftStamp  = stamp; }
		else     { node.rightPath = stamp.exists ? path : nil; node.rightKind = kind; node.rightStamp = stamp; }
	}
	return node.leftKind != CompareKindNone || node.rightKind != CompareKindNone || !node.parent;
}

// Recomputes a folder's status from its (already classified) children.
static void Aggregate (CompareNode* node, compare_options_t const& options)
{
	CompareStatus childMask = 0;
	for(CompareNode* child in node.childrenByName.allValues)
		childMask |= child.mask;
	BOOL foldersFirst = options.folders_first;
	node.children = [node.childrenByName.allValues sortedArrayUsingComparator:^NSComparisonResult(CompareNode* lhs, CompareNode* rhs){
		if(foldersFirst && lhs.isFolder != rhs.isFolder)
			return lhs.isFolder ? NSOrderedAscending : NSOrderedDescending;
		return [lhs.name localizedStandardCompare:rhs.name];
	}];
	if(node.leftKind == CompareKindDirectory && node.rightKind == CompareKindDirectory)
		node.status = (childMask & CompareStatusDifferent) ? CompareStatusModified : CompareStatusIdentical;
	else if(node.leftKind == CompareKindNone)
		node.status = CompareStatusRightOnly;
	else if(node.rightKind == CompareKindNone)
		node.status = CompareStatusLeftOnly;
	else
		node.status = CompareStatusTypeChanged;
	node.mask = node.status | childMask;
}

void CompareRestat (CompareNode* node, compare_options_t const& options)
{
	if(!node)
		return;
	CompareNode* parent = node.parent;
	if(Reread(node))
	{
		if(!node.isFolder)
			node.children = nil;
		Classify(node, options);
	}
	else
	{
		[parent.childrenByName removeObjectForKey:node.name];
	}

	// Folders above: their own kinds may change too (a folder created on one side).
	for(CompareNode* ancestor = parent; ancestor; ancestor = ancestor.parent)
	{
		for(BOOL left : { YES, NO })
		{
			if(!ancestor.parent)
				continue; // the roots stay folders
			NSString* path = [ancestor pathOnLeft:left];
			compare_stamp_t stamp = CompareStampAtPath(path);
			CompareKind kind = KindForStamp(stamp, YES);
			if(left) { ancestor.leftPath  = stamp.exists ? path : nil; ancestor.leftKind  = kind; ancestor.leftStamp  = stamp; }
			else     { ancestor.rightPath = stamp.exists ? path : nil; ancestor.rightKind = kind; ancestor.rightStamp = stamp; }
		}
		CompareNode* above = ancestor.parent;
		if(above && !ancestor.childrenByName.count && ancestor.leftKind == CompareKindNone && ancestor.rightKind == CompareKindNone)
			[above.childrenByName removeObjectForKey:ancestor.name];
		else
			Aggregate(ancestor, options);
	}
}

// The node for `relativePath`, creating it and its parents when missing.
static CompareNode* EnsureNode (CompareNode* root, NSString* relativePath)
{
	CompareNode* node = root;
	for(NSString* component in [relativePath.precomposedStringWithCanonicalMapping componentsSeparatedByString:@"/"])
	{
		if(!component.length)
			continue;
		CompareNode* child = node.childrenByName[component];
		if(!child)
		{
			child = NewNode(component, node.relativePath.length ? [node.relativePath stringByAppendingFormat:@"/%@", component] : component, node);
			node.childrenByName[component] = child;
		}
		node = child;
	}
	return node;
}

void CompareRestatPaths (CompareNode* root, NSArray<NSString*>* relativePaths, compare_options_t const& options)
{
	for(NSString* relativePath in relativePaths)
	{
		CompareNode* node = EnsureNode(root, relativePath);
		for(BOOL left : { YES, NO })
		{
			NSString* path = [node pathOnLeft:left];
			if(!S_ISDIR(CompareStampAtPath(path).mode))
				continue;
			for(NSString* entry in CompareListEntries(path, options))
				EnsureNode(root, node.relativePath.length ? [node.relativePath stringByAppendingPathComponent:entry] : entry);
		}
		CompareRestat(node, options);
	}
}

static void CountLeaves (CompareNode* node, NSMutableDictionary<NSNumber*, NSNumber*>* counts)
{
	if(node.isFolder)
	{
		// A folder that is a file or link on the other side is one difference.
		if(node.status == CompareStatusTypeChanged)
			counts[@(node.status)] = @(counts[@(node.status)].unsignedIntegerValue + 1);
		for(CompareNode* child in node.children)
			CountLeaves(child, counts);
		return;
	}
	counts[@(node.status)] = @(counts[@(node.status)].unsignedIntegerValue + 1);
}

NSDictionary<NSNumber*, NSNumber*>* CompareLeafCounts (CompareNode* root)
{
	NSMutableDictionary* counts = [NSMutableDictionary dictionary];
	CountLeaves(root, counts);
	return counts;
}
