#import "../src/compare_tree.h"
#import "compare_fixture.h"

struct fixture_t
{
	NSString* left;
	NSString* right;
};

static fixture_t const& Fixture ()
{
	static fixture_t fixture = []{
		compare_fixture_t created = compare_fixture::create(@COMPARE_TEST_GIT);
		OAK_ASSERT(created.error == nil);
		return fixture_t{ created.left, created.right };
	}();
	return fixture;
}

static compare_options_t GitOptions ()
{
	compare_options_t options;
	options.git = @COMPARE_TEST_GIT;
	return options;
}

static CompareNode* Tree (compare_options_t const& options = GitOptions())
{
	CompareNode* root = CompareBuildTree(Fixture().left, Fixture().right, options);
	OAK_ASSERT(root != nil);
	return root;
}

static CompareStatus StatusOf (CompareNode* root, NSString* relativePath)
{
	CompareNode* node = [root nodeAtRelativePath:relativePath];
	OAK_ASSERT(node != nil);
	return node ? node.status : 0;
}

void test_file_statuses ()
{
	CompareNode* root = Tree();
	OAK_ASSERT_EQ((int)(StatusOf(root, @"same.txt")), (int)(CompareStatusIdentical));
	OAK_ASSERT_EQ((int)(StatusOf(root, @"same-size.txt")), (int)(CompareStatusModified));
	OAK_ASSERT_EQ((int)(StatusOf(root, @"grown.txt")), (int)(CompareStatusModified));
	OAK_ASSERT_EQ((int)(StatusOf(root, @"left-only.txt")), (int)(CompareStatusLeftOnly));
	OAK_ASSERT_EQ((int)(StatusOf(root, @"newdir/x.txt")), (int)(CompareStatusRightOnly));
	OAK_ASSERT_EQ((int)(StatusOf(root, @"link")), (int)(CompareStatusModified));
	OAK_ASSERT_EQ((int)(StatusOf(root, @"multi.txt")), (int)(CompareStatusModified));
}

void test_tracked_file_deleted_on_disk_is_missing ()
{
	OAK_ASSERT_EQ((int)(StatusOf(Tree(), @"gone.txt")), (int)(CompareStatusLeftOnly));
}

void test_type_change ()
{
	CompareNode* root = Tree();
	CompareNode* kind = [root nodeAtRelativePath:@"kind"];
	OAK_ASSERT(kind.isFolder);
	OAK_ASSERT_EQ((int)(kind.leftKind), (int)(CompareKindFile));
	OAK_ASSERT_EQ((int)(kind.rightKind), (int)(CompareKindDirectory));
	OAK_ASSERT_EQ((int)(kind.status), (int)(CompareStatusTypeChanged));
	OAK_ASSERT_EQ((int)(StatusOf(root, @"kind/inner.txt")), (int)(CompareStatusRightOnly));
}

void test_unicode_normalised_names_match ()
{
	CompareNode* root = Tree();
	CompareNode* node = [root nodeAtRelativePath:@"é.txt"];
	OAK_ASSERT(node != nil);
	OAK_ASSERT_EQ((int)(node.status), (int)(CompareStatusIdentical));
	OAK_ASSERT(node.leftPath && node.rightPath);
	OAK_ASSERT([root nodeAtRelativePath:@"é.txt"] == node);
}

void test_folder_aggregation ()
{
	CompareNode* root = Tree();
	OAK_ASSERT_EQ((int)(StatusOf(root, @"deep/a/c.txt")), (int)(CompareStatusIdentical));
	OAK_ASSERT_EQ((int)(StatusOf(root, @"deep/a/b.txt")), (int)(CompareStatusModified));
	OAK_ASSERT_EQ((int)(StatusOf(root, @"deep/a")), (int)(CompareStatusModified));
	OAK_ASSERT_EQ((int)(StatusOf(root, @"deep")), (int)(CompareStatusModified));
	OAK_ASSERT_EQ((int)(StatusOf(root, @"newdir")), (int)(CompareStatusRightOnly));
	OAK_ASSERT_EQ((int)([root nodeAtRelativePath:@"deep"].mask), (int)(CompareStatusModified|CompareStatusIdentical));
	OAK_ASSERT_EQ((int)(root.status), (int)(CompareStatusModified));
	OAK_ASSERT(root.mask & CompareStatusLeftOnly);
	OAK_ASSERT(root.mask & CompareStatusRightOnly);
	OAK_ASSERT(root.mask & CompareStatusTypeChanged);
}

void test_ignored_files_excluded_by_default ()
{
	CompareNode* root = Tree();
	OAK_ASSERT([root nodeAtRelativePath:@"build"] == nil);
	OAK_ASSERT([root nodeAtRelativePath:@".git"] == nil);
}

void test_include_ignored_walks_folders ()
{
	compare_options_t options = GitOptions();
	options.include_ignored = YES;
	CompareNode* root = Tree(options);
	OAK_ASSERT_EQ((int)(StatusOf(root, @"build/out.o")), (int)(CompareStatusLeftOnly));
	OAK_ASSERT([root nodeAtRelativePath:@".git"] == nil); // directory on the left, file on the right
	OAK_ASSERT_EQ((int)(StatusOf(root, @"same.txt")), (int)(CompareStatusIdentical));
}

void test_without_git_walks_folders ()
{
	CompareNode* root = Tree(compare_options_t());
	OAK_ASSERT_EQ((int)(StatusOf(root, @"build/out.o")), (int)(CompareStatusLeftOnly));
	OAK_ASSERT([root nodeAtRelativePath:@".git"] == nil);
	OAK_ASSERT_EQ((int)(StatusOf(root, @"gone.txt")), (int)(CompareStatusLeftOnly));
}

void test_children_sorted_folders_first ()
{
	CompareNode* root = Tree();
	NSArray<CompareNode*>* children = root.children;
	OAK_ASSERT_EQ(children.count, 12);
	OAK_ASSERT([[[children subarrayWithRange:NSMakeRange(0, 3)] valueForKey:@"name"] isEqual:(@[ @"deep", @"kind", @"newdir" ])]);
	for(NSUInteger i = 3; i < children.count; ++i)
		OAK_ASSERT(!children[i].isFolder);
	for(NSUInteger i = 4; i < children.count; ++i)
		OAK_ASSERT([children[i - 1].name localizedStandardCompare:children[i].name] != NSOrderedDescending);
	OAK_ASSERT([root nodeAtRelativePath:@"deep/a"].parent == [root nodeAtRelativePath:@"deep"]);
	OAK_ASSERT([root nodeAtRelativePath:@"same.txt"].children == nil);
}

void test_leaf_counts ()
{
	NSDictionary* counts = CompareLeafCounts(Tree());
	OAK_ASSERT_EQ([counts[@(CompareStatusIdentical)] intValue],   4); // same.txt, deep/a/c.txt, é.txt, .gitignore
	OAK_ASSERT_EQ([counts[@(CompareStatusModified)] intValue],    5); // same-size, grown, deep/a/b, link, multi
	OAK_ASSERT_EQ([counts[@(CompareStatusLeftOnly)] intValue],    2); // left-only.txt, gone.txt
	OAK_ASSERT_EQ([counts[@(CompareStatusRightOnly)] intValue],   1); // newdir/x.txt (kind/inner.txt is part of the type change)
	OAK_ASSERT_EQ([counts[@(CompareStatusTypeChanged)] intValue], 1); // kind: file on the left, folder on the right
}

void test_cancelled_returns_nil ()
{
	compare_options_t options = GitOptions();
	options.cancelled = ^BOOL{ return YES; };
	OAK_ASSERT(CompareBuildTree(Fixture().left, Fixture().right, options) == nil);
}

void test_branch_labels ()
{
	OAK_ASSERT([CompareBranchLabel(Fixture().left, @COMPARE_TEST_GIT) isEqualToString:@"main"]);
	OAK_ASSERT([CompareBranchLabel(Fixture().right, @COMPARE_TEST_GIT) isEqualToString:@"feature"]);
	OAK_ASSERT(CompareBranchLabel(NSTemporaryDirectory(), @COMPARE_TEST_GIT) == nil);
	OAK_ASSERT(CompareBranchLabel(Fixture().left, nil) == nil);
}

void test_ignored_paths ()
{
	NSSet* ignored = CompareIgnoredPaths(Fixture().left, @[ @"build/out.o", @"build/new.o", @"same.txt", @"newfile.txt" ], @COMPARE_TEST_GIT);
	OAK_ASSERT([ignored isEqualToSet:([NSSet setWithObjects:@"build/out.o", @"build/new.o", nil])]);
	OAK_ASSERT(CompareIgnoredPaths(Fixture().left, @[ @"same.txt" ], @COMPARE_TEST_GIT).count == 0);
	OAK_ASSERT(CompareIgnoredPaths(Fixture().left, @[ @"build/out.o" ], nil).count == 0);
}

void test_git_timeout_fails_without_walking ()
{
	compare_options_t options = GitOptions();
	options.git_timeout = 0.000001;
	__block NSString* reason = nil;
	options.failed = ^(NSString* why){ reason = why; };
	OAK_ASSERT(CompareListEntries(Fixture().left, options) == nil); // not a folder walk with build/out.o
	OAK_ASSERT([reason containsString:@"longer than"]);
	reason = nil;
	OAK_ASSERT(CompareBuildTree(Fixture().left, Fixture().right, options) == nil);
	OAK_ASSERT(reason != nil);
}
