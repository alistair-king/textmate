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

// ==============================================
// = Settings → Ignore folders and files       =
// ==============================================

void test_excludes_parse_comma_separated_patterns ()
{
	compare_excludes_t excludes(@" node_modules, *.log ,, /docs/build/ ,");
	OAK_ASSERT([excludes.patterns() isEqual:(@[ @"node_modules", @"*.log", @"docs/build" ])]);
	OAK_ASSERT(compare_excludes_t(@"").empty());
	OAK_ASSERT(compare_excludes_t(@" , ").empty());
	OAK_ASSERT(!compare_excludes_t(@"").matches(@"node_modules"));
}

void test_excludes_match_names_at_any_depth ()
{
	compare_excludes_t excludes(@"node_modules, *.log, cache?, [Tt]mp");
	OAK_ASSERT(excludes.matches(@"node_modules"));
	OAK_ASSERT(excludes.matches(@"node_modules/react/index.js")); // everything inside
	OAK_ASSERT(excludes.matches(@"web/app/node_modules"));
	OAK_ASSERT(excludes.matches(@"Node_Modules"));               // case is ignored
	OAK_ASSERT(excludes.matches(@"logs/debug.log"));
	OAK_ASSERT(excludes.matches(@"cache1/x.txt"));
	OAK_ASSERT(excludes.matches(@"src/tmp"));
	OAK_ASSERT(!excludes.matches(@"node_modules_backup"));
	OAK_ASSERT(!excludes.matches(@"src/node_modules.txt"));
	OAK_ASSERT(!excludes.matches(@"cache12"));
	OAK_ASSERT(!excludes.matches(@"debug.log.txt"));
	OAK_ASSERT(!excludes.matches(@"src/main.cc"));
}

void test_excludes_with_a_slash_match_paths_from_the_top ()
{
	compare_excludes_t excludes(@"docs/build, packages/*/dist");
	OAK_ASSERT(excludes.matches(@"docs/build"));
	OAK_ASSERT(excludes.matches(@"docs/build/index.html"));
	OAK_ASSERT(excludes.matches(@"packages/ui/dist/ui.js"));
	OAK_ASSERT(!excludes.matches(@"other/docs/build"));   // anchored at the roots
	OAK_ASSERT(!excludes.matches(@"build"));
	OAK_ASSERT(!excludes.matches(@"packages/ui/src/dist.ts"));
	OAK_ASSERT(!excludes.matches(@"packages/a/b/dist"));  // * does not cross a slash
}

// A pair of folders where node_modules is untracked but not gitignored, so
// Git lists it, and a walk would enter it.
static fixture_t const& ExcludesFixture ()
{
	static fixture_t fixture = []{
		NSString* base = [[NSTemporaryDirectory() stringByAppendingPathComponent:[@"compare-excludes-" stringByAppendingString:NSUUID.UUID.UUIDString]] stringByResolvingSymlinksInPath];
		NSString* left  = [base stringByAppendingPathComponent:@"left"];
		NSString* right = [base stringByAppendingPathComponent:@"right"];
		for(NSString* root in @[ left, right ])
		{
			OAK_ASSERT(compare_fixture::write(root, @"src/app.js", [root isEqualToString:left] ? @"left\n" : @"right\n") == nil);
			OAK_ASSERT(compare_fixture::write(root, @"node_modules/react/index.js", [root isEqualToString:left] ? @"v18\n" : @"v19\n") == nil);
			OAK_ASSERT(compare_fixture::write(root, @"web/node_modules/x.js", @"x\n") == nil);
			OAK_ASSERT(compare_fixture::write(root, @"docs/build/index.html", @"<p>\n") == nil);
			OAK_ASSERT(compare_fixture::write(root, @"other/docs/build/keep.html", @"<p>\n") == nil);
		}
		OAK_ASSERT(compare_fixture::write(left, @"debug.log", @"only on the left\n") == nil);
		OAK_ASSERT(compare_fixture::run_git(@COMPARE_TEST_GIT, left, @[ @"init", @"-q", @"-b", @"main" ]) == nil);
		return fixture_t{ left, right };
	}();
	return fixture;
}

void test_excluded_entries_are_not_listed ()
{
	fixture_t const& fixture = ExcludesFixture();
	compare_options_t options = GitOptions();
	options.excludes = compare_excludes_t(@"node_modules, *.log, docs/build");
	for(BOOL git : { YES, NO }) // Git's list (left) and a walk (both sides)
	{
		options.git = git ? @COMPARE_TEST_GIT : nil;
		NSArray* entries = [CompareListEntries(fixture.left, options) sortedArrayUsingSelector:@selector(compare:)];
		OAK_ASSERT([entries isEqual:(@[ @"other/docs/build/keep.html", @"src/app.js" ])]);
	}
	OAK_ASSERT_EQ(CompareListEntries(fixture.left, GitOptions()).count, 6); // Git does list them

}

void test_excluded_folders_are_hidden_on_both_sides ()
{
	fixture_t const& fixture = ExcludesFixture();
	compare_options_t options = GitOptions();
	options.excludes = compare_excludes_t(@"node_modules");
	CompareNode* root = CompareBuildTree(fixture.left, fixture.right, options);
	OAK_ASSERT(root != nil);
	OAK_ASSERT([root nodeAtRelativePath:@"node_modules"] == nil);
	OAK_ASSERT([root nodeAtRelativePath:@"web/node_modules"] == nil);
	OAK_ASSERT([root nodeAtRelativePath:@"src/app.js"] != nil);
	OAK_ASSERT([root nodeAtRelativePath:@"web"] == nil); // nothing left inside it

	// Without the setting they are compared like anything else.
	CompareNode* all = CompareBuildTree(fixture.left, fixture.right, GitOptions());
	OAK_ASSERT_EQ((int)[all nodeAtRelativePath:@"node_modules/react/index.js"].status, (int)CompareStatusModified);
}

void test_rereading_paths_skips_excluded_entries ()
{
	fixture_t const& fixture = ExcludesFixture();
	compare_options_t options = compare_options_t();
	options.excludes = compare_excludes_t(@"node_modules, docs/build");
	CompareNode* root = CompareBuildTree(fixture.left, fixture.right, options);
	OAK_ASSERT(root != nil);
	// Re-reading a folder lists it with path patterns still anchored at the roots.
	CompareRestatPaths(root, @[ @"other", @"docs", @"node_modules/react/index.js" ], options);
	OAK_ASSERT([root nodeAtRelativePath:@"other/docs/build/keep.html"] != nil);
	OAK_ASSERT([root nodeAtRelativePath:@"docs/build"] == nil);
	OAK_ASSERT([root nodeAtRelativePath:@"node_modules"] == nil);
}
