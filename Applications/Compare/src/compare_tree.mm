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

- (NSString*)description
{
	return [NSString stringWithFormat:@"<CompareNode %@ status=%d mask=%d>", _relativePath, _status, _mask];
}
@end

// ==========
// = Listing =
// ==========

// Runs git with file-backed output, so large listings cannot deadlock a pipe.
static NSData* GitOutput (NSString* git, NSString* directory, NSArray<NSString*>* arguments, BOOL (^cancelled)())
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

	dispatch_semaphore_t exited = dispatch_semaphore_create(0);
	task.terminationHandler = ^(NSTask*){ dispatch_semaphore_signal(exited); };
	NSData* result = nil;
	if([task launchAndReturnError:nil])
	{
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
		if(!stopped && task.terminationStatus == 0)
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
				CompareKind kind = leaf ? KindAtPath(onDisk) : CompareKindDirectory;
				if(isLeft ? !child.leftPath : !child.rightPath)
				{
					if(isLeft) { child.leftPath  = onDisk; child.leftKind  = kind; }
					else       { child.rightPath = onDisk; child.rightKind = kind; }
				}
				node = child;
			}
		}
	}

	// Leaves keep an empty dictionary only while building; `children` stays nil.
	return Classify(root, options) ? root : nil;
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
