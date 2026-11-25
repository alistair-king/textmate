#import "../src/compare_transfer.h"
#include <sys/stat.h>

// Plain folders (no Git) so each test builds exactly the state it needs.

static NSData* Data (NSString* text)
{
	return [text dataUsingEncoding:NSUTF8StringEncoding];
}

static NSString* Text (NSData* data)
{
	return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static NSString* Folder ()
{
	NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"compare-transfer-" stringByAppendingString:NSUUID.UUID.UUIDString]];
	path = path.stringByResolvingSymlinksInPath;
	[NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
	return path;
}

static void Write (NSString* root, NSString* relativePath, NSString* contents)
{
	NSString* path = [root stringByAppendingPathComponent:relativePath];
	[NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
	OAK_ASSERT([contents writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil]);
}

static NSString* Read (NSString* root, NSString* relativePath)
{
	return [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:relativePath] encoding:NSUTF8StringEncoding error:nil];
}

static BOOL Exists (NSString* root, NSString* relativePath)
{
	return CompareStampAtPath([root stringByAppendingPathComponent:relativePath]).exists;
}

static compare_options_t Options ()
{
	return compare_options_t(); // no Git: folder walks
}

static CompareStatus StatusOf (CompareNode* root, NSString* relativePath)
{
	CompareNode* node = [root nodeAtRelativePath:relativePath];
	return node ? node.status : 0;
}

// ==============
// = apply_hunk =
// ==============

static NSString* Apply (NSString* left, NSString* right, size_t index, bool toRight)
{
	auto diff = compare::diff_data(Data(left), Data(right));
	OAK_ASSERT(index < diff.hunks.size());
	return Text(compare::apply_hunk(Data(left), Data(right), diff.hunks[index], toRight));
}

void test_apply_change_in_either_direction ()
{
	NSString* left  = @"a\nb\nc\nd\ne\n";
	NSString* right = @"a\nB\nc\nd\nE\n";
	OAK_ASSERT([Apply(left, right, 0, true) isEqualToString:@"a\nb\nc\nd\nE\n"]);
	OAK_ASSERT([Apply(left, right, 1, true) isEqualToString:@"a\nB\nc\nd\ne\n"]);
	OAK_ASSERT([Apply(left, right, 0, false) isEqualToString:@"a\nB\nc\nd\ne\n"]);
}

void test_apply_insertion_and_deletion ()
{
	// The right has an extra line; copying to the right removes it, copying to the left adds it.
	NSString* left  = @"a\nc\n";
	NSString* right = @"a\nb\nc\n";
	OAK_ASSERT([Apply(left, right, 0, true) isEqualToString:@"a\nc\n"]);
	OAK_ASSERT([Apply(left, right, 0, false) isEqualToString:@"a\nb\nc\n"]);

	// At the start and the end of the file.
	OAK_ASSERT([Apply(@"b\n", @"a\nb\n", 0, false) isEqualToString:@"a\nb\n"]);
	OAK_ASSERT([Apply(@"a\n", @"a\nb\n", 0, false) isEqualToString:@"a\nb\n"]);
	OAK_ASSERT([Apply(@"", @"x\n", 0, false) isEqualToString:@"x\n"]);
	OAK_ASSERT([Apply(@"x\n", @"", 0, false) isEqualToString:@""]);
}

void test_apply_keeps_line_terminators_sound ()
{
	// xdiff treats an unterminated last line as differing from a terminated
	// one, so the hunk covers both and the source's ending is kept.
	OAK_ASSERT([Apply(@"a\nlast", @"a\nmore\n", 0, true) isEqualToString:@"a\nlast"]);
	OAK_ASSERT([Apply(@"a\nlast", @"a\nmore\n", 0, false) isEqualToString:@"a\nmore\n"]);

	// A line without a terminator that ends up mid-file gets the destination's
	// (hand-made hunk: insert the left's unterminated line 1 at the right's line 1).
	compare::diff_hunk_t insert = { 1, 1, 1, 0, 0, 0 };
	OAK_ASSERT([Text(compare::apply_hunk(Data(@"a\nlast"), Data(@"a\nmore\n"), insert, true)) isEqualToString:@"a\nlast\nmore\n"]);
	OAK_ASSERT([Text(compare::apply_hunk(Data(@"a\nlast"), Data(@"a\r\nmore\r\n"), insert, true)) isEqualToString:@"a\r\nlast\r\nmore\r\n"]);
	compare::diff_hunk_t outOfRange = { 5, 1, 0, 0, 0, 0 };
	OAK_ASSERT(compare::apply_hunk(Data(@"a\n"), Data(@"b\n"), outOfRange, true) == nil);
}

// ===============
// = Change sets =
// ===============

void test_write_and_undo ()
{
	NSString* root = Folder();
	Write(root, @"file.txt", @"before\n");
	NSString* path = [root stringByAppendingPathComponent:@"file.txt"];
	chmod(path.fileSystemRepresentation, 0755);

	CompareChangeSet* changes = [CompareChangeSet new];
	NSString* error = nil;
	OAK_ASSERT([changes writeData:Data(@"after\n") toPath:path mode:0644 error:&error]);
	OAK_ASSERT([Read(root, @"file.txt") isEqualToString:@"after\n"]);
	OAK_ASSERT_EQ(CompareStampAtPath(path).mode & 0777, 0755); // permissions kept
	OAK_ASSERT_EQ(changes.count, 1);

	OAK_ASSERT([changes undo:&error]);
	OAK_ASSERT([Read(root, @"file.txt") isEqualToString:@"before\n"]);
	OAK_ASSERT_EQ(CompareStampAtPath(path).mode & 0777, 0755);
}

void test_copy_creates_folders_and_undo_removes_them ()
{
	NSString* source = Folder();
	NSString* root   = Folder();
	Write(source, @"tool.sh", @"#!/bin/sh\n");
	chmod([source stringByAppendingPathComponent:@"tool.sh"].fileSystemRepresentation, 0755);

	CompareChangeSet* changes = [CompareChangeSet new];
	NSString* error = nil;
	OAK_ASSERT([changes copyItemAtPath:[source stringByAppendingPathComponent:@"tool.sh"] toPath:[root stringByAppendingPathComponent:@"a/b/tool.sh"] error:&error]);
	OAK_ASSERT([Read(root, @"a/b/tool.sh") isEqualToString:@"#!/bin/sh\n"]);
	OAK_ASSERT_EQ(CompareStampAtPath([root stringByAppendingPathComponent:@"a/b/tool.sh"]).mode & 0777, 0755);

	OAK_ASSERT([changes undo:&error]);
	OAK_ASSERT(!Exists(root, @"a/b/tool.sh"));
	OAK_ASSERT(!Exists(root, @"a"));
}

void test_trash_and_undo ()
{
	NSString* root = Folder();
	Write(root, @"folder/inside.txt", @"keep\n");
	CompareChangeSet* changes = [CompareChangeSet new];
	NSString* error = nil;
	OAK_ASSERT([changes trashItemAtPath:[root stringByAppendingPathComponent:@"folder"] error:&error]);
	OAK_ASSERT(!Exists(root, @"folder"));
	OAK_ASSERT([changes undo:&error]);
	OAK_ASSERT([Read(root, @"folder/inside.txt") isEqualToString:@"keep\n"]);
}

void test_undo_refuses_after_external_change ()
{
	NSString* root = Folder();
	Write(root, @"file.txt", @"before\n");
	NSString* path = [root stringByAppendingPathComponent:@"file.txt"];
	CompareChangeSet* changes = [CompareChangeSet new];
	NSString* error = nil;
	OAK_ASSERT([changes writeData:Data(@"after\n") toPath:path mode:0644 error:&error]);
	Write(root, @"file.txt", @"edited elsewhere\n");
	OAK_ASSERT(![changes undo:&error]);
	OAK_ASSERT(error != nil);
	OAK_ASSERT([Read(root, @"file.txt") isEqualToString:@"edited elsewhere\n"]);
}

// ==================
// = Tree transfers =
// ==================

struct pair_t { NSString* left; NSString* right; };

static pair_t Pair ()
{
	pair_t pair = { Folder(), Folder() };
	Write(pair.left,  @"same.txt",          @"same\n");
	Write(pair.right, @"same.txt",          @"same\n");
	Write(pair.left,  @"changed.txt",       @"left\n");
	Write(pair.right, @"changed.txt",       @"right\n");
	Write(pair.left,  @"only/left/a.txt",   @"a\n");
	Write(pair.left,  @"only/left/b.txt",   @"b\n");
	Write(pair.right, @"mixed/x.txt",       @"x right\n");
	Write(pair.left,  @"mixed/x.txt",       @"x left\n");
	Write(pair.right, @"mixed/right.txt",   @"r\n");
	Write(pair.left,  @"kind",              @"a file on the left\n");
	Write(pair.right, @"kind/inner.txt",    @"a folder on the right\n");
	return pair;
}

void test_copy_file_both_ways_with_undo ()
{
	pair_t pair = Pair();
	CompareNode* root = CompareBuildTree(pair.left, pair.right, Options());
	CompareNode* node = [root nodeAtRelativePath:@"changed.txt"];
	OAK_ASSERT_EQ(CompareCountCopies(node, YES), 1);

	CompareChangeSet* changes = [CompareChangeSet new];
	NSString* error = nil;
	OAK_ASSERT(CompareCopyNode(node, YES, changes, &error));
	OAK_ASSERT([Read(pair.right, @"changed.txt") isEqualToString:@"left\n"]);
	CompareRestat(node, Options());
	OAK_ASSERT_EQ((int)StatusOf(root, @"changed.txt"), (int)CompareStatusIdentical);

	OAK_ASSERT([changes undo:&error]);
	CompareRestat(node, Options());
	OAK_ASSERT([Read(pair.right, @"changed.txt") isEqualToString:@"right\n"]);
	OAK_ASSERT_EQ((int)StatusOf(root, @"changed.txt"), (int)CompareStatusModified);

	CompareChangeSet* back = [CompareChangeSet new];
	OAK_ASSERT(CompareCopyNode(node, NO, back, &error));
	OAK_ASSERT([Read(pair.left, @"changed.txt") isEqualToString:@"right\n"]);
}

void test_copy_folder_copies_differing_entries_only ()
{
	pair_t pair = Pair();
	CompareNode* root = CompareBuildTree(pair.left, pair.right, Options());

	// A folder only on the left: everything inside is created on the right.
	CompareNode* only = [root nodeAtRelativePath:@"only"];
	OAK_ASSERT_EQ(CompareCountCopies(only, YES), 2);
	OAK_ASSERT_EQ(CompareCountCopies(only, NO), 0);
	CompareChangeSet* changes = [CompareChangeSet new];
	NSString* error = nil;
	OAK_ASSERT(CompareCopyNode(only, YES, changes, &error));
	OAK_ASSERT([Read(pair.right, @"only/left/b.txt") isEqualToString:@"b\n"]);
	CompareRestat(only, Options());
	OAK_ASSERT_EQ((int)StatusOf(root, @"only"), (int)CompareStatusIdentical);

	// A folder on both sides: the differing file is copied; a file only on the destination stays.
	CompareNode* mixed = [root nodeAtRelativePath:@"mixed"];
	OAK_ASSERT_EQ(CompareCountCopies(mixed, YES), 1);
	OAK_ASSERT(CompareCopyNode(mixed, YES, changes, &error));
	OAK_ASSERT([Read(pair.right, @"mixed/x.txt") isEqualToString:@"x left\n"]);
	OAK_ASSERT(Exists(pair.right, @"mixed/right.txt"));
	CompareRestat(mixed, Options());
	OAK_ASSERT_EQ((int)StatusOf(root, @"mixed"), (int)CompareStatusModified);
	OAK_ASSERT_EQ((int)StatusOf(root, @"mixed/x.txt"), (int)CompareStatusIdentical);

	// One undo reverses everything this change set did.
	OAK_ASSERT([changes undo:&error]);
	OAK_ASSERT(!Exists(pair.right, @"only"));
	OAK_ASSERT([Read(pair.right, @"mixed/x.txt") isEqualToString:@"x right\n"]);
}

void test_copy_replaces_type ()
{
	pair_t pair = Pair();
	CompareNode* root = CompareBuildTree(pair.left, pair.right, Options());
	CompareNode* kind = [root nodeAtRelativePath:@"kind"];
	OAK_ASSERT(CompareCopyReplacesType(kind, YES));

	// File on the left replaces the folder on the right (the folder goes to the Trash).
	CompareChangeSet* changes = [CompareChangeSet new];
	NSString* error = nil;
	OAK_ASSERT(CompareCopyNode(kind, YES, changes, &error));
	OAK_ASSERT([Read(pair.right, @"kind") isEqualToString:@"a file on the left\n"]);
	CompareRestat(kind, Options());
	OAK_ASSERT_EQ((int)StatusOf(root, @"kind"), (int)CompareStatusIdentical);
	OAK_ASSERT([root nodeAtRelativePath:@"kind/inner.txt"] == nil);

	OAK_ASSERT([changes undo:&error]);
	CompareRestat(kind, Options());
	OAK_ASSERT([Read(pair.right, @"kind/inner.txt") isEqualToString:@"a folder on the right\n"]);
	OAK_ASSERT_EQ((int)StatusOf(root, @"kind"), (int)CompareStatusTypeChanged);
}

void test_copy_entry_below_a_file_replaces_the_file ()
{
	pair_t pair = Pair();
	CompareNode* root = CompareBuildTree(pair.left, pair.right, Options());
	// kind/inner.txt to the left, where "kind" is a file.
	CompareNode* inner = [root nodeAtRelativePath:@"kind/inner.txt"];
	CompareChangeSet* changes = [CompareChangeSet new];
	NSString* error = nil;
	OAK_ASSERT(CompareCopyNode(inner, NO, changes, &error));
	OAK_ASSERT([Read(pair.left, @"kind/inner.txt") isEqualToString:@"a folder on the right\n"]);
	CompareRestat([root nodeAtRelativePath:@"kind"], Options());
	OAK_ASSERT_EQ((int)StatusOf(root, @"kind"), (int)CompareStatusIdentical);
}

void test_copy_refuses_when_changed_since_compared ()
{
	pair_t pair = Pair();
	CompareNode* root = CompareBuildTree(pair.left, pair.right, Options());
	Write(pair.right, @"changed.txt", @"edited after comparing\n");
	CompareChangeSet* changes = [CompareChangeSet new];
	NSString* error = nil;
	OAK_ASSERT(!CompareCopyNode([root nodeAtRelativePath:@"changed.txt"], YES, changes, &error));
	OAK_ASSERT([error containsString:@"changed on the right"]);
	OAK_ASSERT([Read(pair.right, @"changed.txt") isEqualToString:@"edited after comparing\n"]);
	OAK_ASSERT_EQ(changes.count, 0);
}

void test_trash_one_sided_entry_removes_its_node ()
{
	pair_t pair = Pair();
	CompareNode* root = CompareBuildTree(pair.left, pair.right, Options());
	CompareNode* node = [root nodeAtRelativePath:@"mixed/right.txt"];
	CompareChangeSet* changes = [CompareChangeSet new];
	NSString* error = nil;
	OAK_ASSERT(CompareTrashNode(node, NO, changes, &error));
	CompareRestat(node, Options());
	OAK_ASSERT([root nodeAtRelativePath:@"mixed/right.txt"] == nil);
	OAK_ASSERT(![[root nodeAtRelativePath:@"mixed"].children containsObject:node]);

	OAK_ASSERT([changes undo:&error]);
	CompareRestatPaths(root, @[ @"mixed/right.txt" ], Options());
	OAK_ASSERT_EQ((int)StatusOf(root, @"mixed/right.txt"), (int)CompareStatusRightOnly);
	OAK_ASSERT([[root nodeAtRelativePath:@"mixed"].children containsObject:[root nodeAtRelativePath:@"mixed/right.txt"]]);
}

void test_undone_trash_of_folder_lists_it_again ()
{
	pair_t pair = Pair();
	CompareNode* root = CompareBuildTree(pair.left, pair.right, Options());
	CompareNode* only = [root nodeAtRelativePath:@"only"];
	CompareChangeSet* changes = [CompareChangeSet new];
	NSString* error = nil;
	OAK_ASSERT(CompareTrashNode(only, YES, changes, &error));
	CompareRestat(only, Options());
	OAK_ASSERT([root nodeAtRelativePath:@"only"] == nil);

	OAK_ASSERT([changes undo:&error]);
	CompareRestatPaths(root, @[ @"only" ], Options());
	OAK_ASSERT_EQ((int)StatusOf(root, @"only"), (int)CompareStatusLeftOnly);
	OAK_ASSERT_EQ((int)StatusOf(root, @"only/left/b.txt"), (int)CompareStatusLeftOnly);
	OAK_ASSERT([root nodeAtRelativePath:@"only"].isFolder);
}

// =======================
// = Review regressions =
// =======================

void test_file_in_place_of_a_parent_folder_counts_as_type_replacement ()
{
	// Copying config/settings.json to the right moves the right's file “config” to the Trash.
	pair_t pair = { Folder(), Folder() };
	Write(pair.left,  @"config/settings.json", @"{}\n");
	Write(pair.right, @"config",               @"a file\n");
	CompareNode* root = CompareBuildTree(pair.left, pair.right, Options());
	CompareNode* settings = [root nodeAtRelativePath:@"config/settings.json"];
	OAK_ASSERT(settings != nil);
	OAK_ASSERT(CompareCopyReplacesType(settings, YES));
	OAK_ASSERT(!CompareCopyReplacesType(settings, NO)); // the left has a folder there
	CompareChangeSet* changes = [CompareChangeSet new];
	NSString* error = nil;
	OAK_ASSERT(CompareCopyNode(settings, YES, changes, &error));
	OAK_ASSERT([Read(pair.right, @"config/settings.json") isEqualToString:@"{}\n"]);
	OAK_ASSERT([changes undo:&error]);
	OAK_ASSERT([Read(pair.right, @"config") isEqualToString:@"a file\n"]);
}

void test_second_undo_after_two_writes_to_one_file ()
{
	NSString* root = Folder();
	Write(root, @"file.txt", @"original\n");
	NSString* path = [root stringByAppendingPathComponent:@"file.txt"];
	CompareChangeSet* first  = [CompareChangeSet new];
	CompareChangeSet* second = [CompareChangeSet new];
	NSString* error = nil;
	OAK_ASSERT([first writeData:Data(@"first\n") toPath:path mode:0644 error:&error]);
	OAK_ASSERT([second writeData:Data(@"second\n") toPath:path mode:0644 error:&error]);
	OAK_ASSERT([second undo:&error]); // restores “first” as a new file (another inode)
	OAK_ASSERT([Read(root, @"file.txt") isEqualToString:@"first\n"]);
	OAK_ASSERT([first undo:&error]);
	OAK_ASSERT(error == nil);
	OAK_ASSERT([Read(root, @"file.txt") isEqualToString:@"original\n"]);
}

void test_undo_still_refuses_different_contents_of_the_same_size ()
{
	NSString* root = Folder();
	Write(root, @"file.txt", @"aaaa\n");
	NSString* path = [root stringByAppendingPathComponent:@"file.txt"];
	CompareChangeSet* changes = [CompareChangeSet new];
	NSString* error = nil;
	OAK_ASSERT([changes writeData:Data(@"bbbb\n") toPath:path mode:0644 error:&error]);
	[NSFileManager.defaultManager removeItemAtPath:path error:nil];
	Write(root, @"file.txt", @"cccc\n"); // same size, other contents
	OAK_ASSERT(![changes undo:&error]);
	OAK_ASSERT([Read(root, @"file.txt") isEqualToString:@"cccc\n"]);
}

void test_empty_folders_are_listed_and_copied ()
{
	pair_t pair = { Folder(), Folder() };
	Write(pair.left, @"kept.txt", @"same\n");
	Write(pair.right, @"kept.txt", @"same\n");
	[NSFileManager.defaultManager createDirectoryAtPath:[pair.left stringByAppendingPathComponent:@"empty"] withIntermediateDirectories:YES attributes:nil error:nil];
	CompareNode* root = CompareBuildTree(pair.left, pair.right, Options());
	CompareNode* empty = [root nodeAtRelativePath:@"empty"];
	OAK_ASSERT(empty != nil);
	OAK_ASSERT(empty.isFolder);
	OAK_ASSERT_EQ((int)empty.status, (int)CompareStatusLeftOnly);
	OAK_ASSERT_EQ(CompareCountCopies(empty, YES), 1);

	CompareChangeSet* changes = [CompareChangeSet new];
	NSString* error = nil;
	OAK_ASSERT(CompareCopyNode(empty, YES, changes, &error));
	OAK_ASSERT(S_ISDIR(CompareStampAtPath([pair.right stringByAppendingPathComponent:@"empty"]).mode));
	CompareRestat(empty, Options());
	OAK_ASSERT_EQ((int)StatusOf(root, @"empty"), (int)CompareStatusIdentical);
	OAK_ASSERT([changes undo:&error]);
	OAK_ASSERT(!Exists(pair.right, @"empty"));
}

void test_empty_folder_versus_file_is_a_type_change ()
{
	pair_t pair = { Folder(), Folder() };
	[NSFileManager.defaultManager createDirectoryAtPath:[pair.left stringByAppendingPathComponent:@"x"] withIntermediateDirectories:YES attributes:nil error:nil];
	Write(pair.right, @"x", @"a file\n");
	CompareNode* root = CompareBuildTree(pair.left, pair.right, Options());
	CompareNode* x = [root nodeAtRelativePath:@"x"];
	OAK_ASSERT_EQ((int)x.status, (int)CompareStatusTypeChanged);
	OAK_ASSERT(CompareCopyReplacesType(x, YES));
	CompareChangeSet* changes = [CompareChangeSet new];
	NSString* error = nil;
	OAK_ASSERT(CompareCopyNode(x, YES, changes, &error));
	OAK_ASSERT(S_ISDIR(CompareStampAtPath([pair.right stringByAppendingPathComponent:@"x"]).mode));
	OAK_ASSERT([changes undo:&error]);
	OAK_ASSERT([Read(pair.right, @"x") isEqualToString:@"a file\n"]);
}

void test_undo_refuses_when_a_trashed_entry_has_left_the_trash ()
{
	// Copying a folder “config” over a file “config”: the file goes to the
	// Trash, then a folder is created at the same path. With the Trash
	// emptied, undo must refuse before changing anything.
	pair_t pair = { Folder(), Folder() };
	Write(pair.left,  @"config/settings.json", @"{}\n");
	Write(pair.right, @"config",               @"a file\n");
	CompareNode* root = CompareBuildTree(pair.left, pair.right, Options());
	CompareChangeSet* changes = [CompareChangeSet new];
	NSString* error = nil;
	OAK_ASSERT(CompareCopyNode([root nodeAtRelativePath:@"config"], YES, changes, &error));
	OAK_ASSERT(changes.trashedURLs.count == 1);
	for(NSURL* url in changes.trashedURLs)
		[NSFileManager.defaultManager removeItemAtURL:url error:nil];
	OAK_ASSERT(![changes undo:&error]);
	OAK_ASSERT([error containsString:@"no longer in the Trash"]);
	OAK_ASSERT([Read(pair.right, @"config/settings.json") isEqualToString:@"{}\n"]); // nothing undone
}

// ======================
// = Second review round =
// ======================

void test_copy_never_writes_through_a_link_that_replaced_a_folder ()
{
	// After comparing, the right's folder “a” is replaced by a link to an
	// unrelated folder that also has “b/”: the copy must not write into it.
	pair_t pair = { Folder(), Folder() };
	NSString* outside = Folder();
	Write(pair.left,  @"a/b/new.txt",   @"new\n");
	Write(pair.right, @"a/b/other.txt", @"other\n");
	Write(outside,    @"b/keep.txt",    @"unrelated\n");
	CompareNode* root = CompareBuildTree(pair.left, pair.right, Options());
	CompareNode* node = [root nodeAtRelativePath:@"a/b/new.txt"];
	OAK_ASSERT(node != nil);

	NSString* a = [pair.right stringByAppendingPathComponent:@"a"];
	[NSFileManager.defaultManager moveItemAtPath:a toPath:[Folder() stringByAppendingPathComponent:@"moved"] error:nil];
	OAK_ASSERT([NSFileManager.defaultManager createSymbolicLinkAtPath:a withDestinationPath:outside error:nil]);

	CompareChangeSet* changes = [CompareChangeSet new];
	changes.roots = @[ pair.left, pair.right ];
	NSString* error = nil;
	OAK_ASSERT(!CompareCopyNode(node, YES, changes, &error));
	OAK_ASSERT([error containsString:@"no longer a folder"]);
	OAK_ASSERT(!Exists(outside, @"b/new.txt"));
	OAK_ASSERT_EQ(changes.count, 0);
}

void test_changes_outside_the_roots_are_refused ()
{
	NSString* root = Folder();
	CompareChangeSet* changes = [CompareChangeSet new];
	changes.roots = @[ root ];
	NSString* error = nil;
	OAK_ASSERT(![changes writeData:Data(@"x\n") toPath:[Folder() stringByAppendingPathComponent:@"elsewhere.txt"] mode:0644 error:&error]);
	OAK_ASSERT([error containsString:@"outside"]);
	OAK_ASSERT([changes writeData:Data(@"x\n") toPath:[root stringByAppendingPathComponent:@"sub/inside.txt"] mode:0644 error:&error]);
}

void test_snapshot_of_a_folder_sees_edits_inside_it ()
{
	NSString* root = Folder();
	Write(root, @"config/a.txt", @"one\n");
	NSString* config = [root stringByAppendingPathComponent:@"config"];
	CompareDiskSnapshot* snapshot = [CompareDiskSnapshot snapshotOfPaths:@[ config ]];
	OAK_ASSERT(snapshot.changedPath == nil);
	Write(root, @"config/a.txt", @"two\n");
	OAK_ASSERT([snapshot.changedPath isEqualToString:config]);
	Write(root, @"config/a.txt", @"one\n");
	OAK_ASSERT(snapshot.changedPath == nil);
	Write(root, @"config/added.txt", @"new\n");
	OAK_ASSERT([snapshot.changedPath isEqualToString:config]);
}

void test_undo_restores_a_trashed_relative_link ()
{
	NSString* root = Folder();
	Write(root, @"target.txt", @"target\n");
	NSString* link = [root stringByAppendingPathComponent:@"link"];
	OAK_ASSERT([NSFileManager.defaultManager createSymbolicLinkAtPath:link withDestinationPath:@"target.txt" error:nil]);
	CompareChangeSet* changes = [CompareChangeSet new];
	NSString* error = nil;
	OAK_ASSERT([changes trashItemAtPath:link error:&error]);
	OAK_ASSERT([changes undo:&error]); // the link does not resolve from the Trash
	OAK_ASSERT([[NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:link error:nil] isEqualToString:@"target.txt"]);
}

void test_copy_siblings_over_a_file_in_one_batch ()
{
	pair_t pair = { Folder(), Folder() };
	Write(pair.left,  @"config/a.txt", @"a\n");
	Write(pair.left,  @"config/b.txt", @"b\n");
	Write(pair.right, @"config",       @"a file\n");
	CompareNode* root = CompareBuildTree(pair.left, pair.right, Options());
	CompareChangeSet* changes = [CompareChangeSet new];
	changes.roots = @[ pair.left, pair.right ];
	NSString* error = nil;
	OAK_ASSERT(CompareCopyNode([root nodeAtRelativePath:@"config/a.txt"], YES, changes, &error));
	OAK_ASSERT(CompareCopyNode([root nodeAtRelativePath:@"config/b.txt"], YES, changes, &error));
	OAK_ASSERT([Read(pair.right, @"config/a.txt") isEqualToString:@"a\n"]);
	OAK_ASSERT([Read(pair.right, @"config/b.txt") isEqualToString:@"b\n"]);
	OAK_ASSERT([changes undo:&error]);
	OAK_ASSERT([Read(pair.right, @"config") isEqualToString:@"a file\n"]);
}

// ======================
// = Third review round =
// ======================

void test_undo_never_restores_through_a_link_that_replaced_a_folder ()
{
	NSString* root    = Folder();
	NSString* outside = Folder();
	Write(root, @"a/f.txt", @"old\n");
	CompareChangeSet* changes = [CompareChangeSet new];
	changes.roots = @[ root ];
	NSString* error = nil;
	OAK_ASSERT([changes writeData:Data(@"new\n") toPath:[root stringByAppendingPathComponent:@"a/f.txt"] mode:0644 error:&error]);

	// The parent moves out of the comparison and a link takes its place: the
	// file still looks as the change left it, but lies elsewhere now.
	NSString* moved = [outside stringByAppendingPathComponent:@"a"];
	OAK_ASSERT([NSFileManager.defaultManager moveItemAtPath:[root stringByAppendingPathComponent:@"a"] toPath:moved error:nil]);
	OAK_ASSERT([NSFileManager.defaultManager createSymbolicLinkAtPath:[root stringByAppendingPathComponent:@"a"] withDestinationPath:moved error:nil]);
	OAK_ASSERT(![changes undo:&error]);
	OAK_ASSERT([error containsString:@"no longer a folder"]);
	OAK_ASSERT([Read(outside, @"a/f.txt") isEqualToString:@"new\n"]);
}

void test_trash_refuses_a_changed_file_whose_other_side_is_a_folder ()
{
	pair_t pair = { Folder(), Folder() };
	Write(pair.left,  @"config",          @"a file\n");
	Write(pair.right, @"config/inner.txt", @"a folder\n");
	CompareNode* root = CompareBuildTree(pair.left, pair.right, Options());
	CompareNode* node = [root nodeAtRelativePath:@"config"];
	OAK_ASSERT(node != nil && node.isFolder);

	Write(pair.left, @"config", @"edited after comparing\n");
	CompareChangeSet* changes = [CompareChangeSet new];
	NSString* error = nil;
	OAK_ASSERT(!CompareTrashNode(node, YES, changes, &error));
	OAK_ASSERT(error != nil);
	OAK_ASSERT([Read(pair.left, @"config") isEqualToString:@"edited after comparing\n"]);

	// The folder side is still trashed by its own entry.
	Write(pair.right, @"config/added.txt", @"new\n");
	OAK_ASSERT(CompareTrashNode(node, NO, changes, &error));
	OAK_ASSERT(!Exists(pair.right, @"config"));
	OAK_ASSERT([changes undo:&error]);
	OAK_ASSERT(Exists(pair.right, @"config/added.txt"));
}

void test_undo_never_restores_through_a_link_that_replaced_the_root ()
{
	NSString* root    = Folder();
	NSString* outside = Folder();
	Write(root, @"f.txt", @"old\n");
	CompareChangeSet* changes = [CompareChangeSet new];
	changes.roots = @[ root ];
	NSString* error = nil;
	OAK_ASSERT([changes writeData:Data(@"new\n") toPath:[root stringByAppendingPathComponent:@"f.txt"] mode:0644 error:&error]);

	// The compared folder itself moves away and a link takes its place.
	NSString* moved = [outside stringByAppendingPathComponent:@"moved"];
	OAK_ASSERT([NSFileManager.defaultManager moveItemAtPath:root toPath:moved error:nil]);
	OAK_ASSERT([NSFileManager.defaultManager createSymbolicLinkAtPath:root withDestinationPath:moved error:nil]);
	OAK_ASSERT(![changes undo:&error]);
	OAK_ASSERT([error containsString:@"no longer a folder"]);
	OAK_ASSERT([Read(moved, @"f.txt") isEqualToString:@"new\n"]);

	// Nor is anything new written through it.
	CompareChangeSet* more = [CompareChangeSet new];
	more.roots = @[ root ];
	OAK_ASSERT(![more writeData:Data(@"x\n") toPath:[root stringByAppendingPathComponent:@"g.txt"] mode:0644 error:&error]);
	OAK_ASSERT(!Exists(moved, @"g.txt"));
}
