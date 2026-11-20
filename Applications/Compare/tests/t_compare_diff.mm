#import "../src/compare_diff.h"

static NSData* Data (NSString* text)
{
	return [text dataUsingEncoding:NSUTF8StringEncoding];
}

// One letter per row: s(ame), c(hanged), r(emoved), a(dded).
static NSString* Kinds (compare::text_diff_t const& diff)
{
	NSMutableString* kinds = [NSMutableString string];
	for(auto const& row : diff.rows)
	{
		switch(row.kind)
		{
			case compare::row_kind::same:    [kinds appendString:@"s"]; break;
			case compare::row_kind::changed: [kinds appendString:@"c"]; break;
			case compare::row_kind::removed: [kinds appendString:@"r"]; break;
			case compare::row_kind::added:   [kinds appendString:@"a"]; break;
		}
	}
	return kinds;
}

void test_identical ()
{
	auto diff = compare::diff_data(Data(@"a\nb\n"), Data(@"a\nb\n"));
	OAK_ASSERT(diff.problem == nil);
	OAK_ASSERT([Kinds(diff) isEqualToString:@"ss"]);
	OAK_ASSERT(diff.hunks.empty());
	OAK_ASSERT([diff.left_lines isEqual:(@[ @"a", @"b" ])]);
}

void test_change_insert_and_delete ()
{
	auto diff = compare::diff_data(Data(@"one\ntwo\nthree\nfour\nfive\n"), Data(@"one\nTWO\nthree\nfive\nsix\nseven\n"));
	OAK_ASSERT([Kinds(diff) isEqualToString:@"scsrsaa"]);
	OAK_ASSERT_EQ(diff.hunks.size(), 3);

	// Rows map to lines on each side, with -1 for gaps.
	OAK_ASSERT_EQ(diff.rows[1].left, 1);
	OAK_ASSERT_EQ(diff.rows[1].right, 1);
	OAK_ASSERT_EQ(diff.rows[3].left, 3);
	OAK_ASSERT_EQ(diff.rows[3].right, -1);
	OAK_ASSERT_EQ(diff.rows[5].left, -1);
	OAK_ASSERT_EQ(diff.rows[5].right, 4);
	OAK_ASSERT_EQ(diff.rows[6].right, 5);

	// Hunks know their rows and lines.
	OAK_ASSERT_EQ(diff.hunks[0].first_row, 1);
	OAK_ASSERT_EQ(diff.hunks[0].row_count, 1);
	OAK_ASSERT_EQ(diff.hunks[1].left_start, 3);
	OAK_ASSERT_EQ(diff.hunks[1].left_count, 1);
	OAK_ASSERT_EQ(diff.hunks[1].right_count, 0);
	OAK_ASSERT_EQ(diff.hunks[2].first_row, 5);
	OAK_ASSERT_EQ(diff.hunks[2].row_count, 2);
	OAK_ASSERT_EQ(diff.rows[6].hunk, 2);
	OAK_ASSERT_EQ(diff.rows[0].hunk, -1);
}

void test_uneven_change_pairs_then_pads ()
{
	auto diff = compare::diff_data(Data(@"a\nx\ny\nz\nb\n"), Data(@"a\nX\nb\n"));
	OAK_ASSERT([Kinds(diff) isEqualToString:@"scrrs"]);
	OAK_ASSERT_EQ(diff.hunks.size(), 1);
}

void test_empty_sides ()
{
	auto added = compare::diff_data(nil, Data(@"new\nfile\n"));
	OAK_ASSERT([Kinds(added) isEqualToString:@"aa"]);
	OAK_ASSERT_EQ(added.left_lines.count, 0);

	auto removed = compare::diff_data(Data(@"old\n"), [NSData data]);
	OAK_ASSERT([Kinds(removed) isEqualToString:@"r"]);

	auto empty = compare::diff_data(nil, nil);
	OAK_ASSERT(empty.rows.empty());
	OAK_ASSERT(empty.problem == nil);
}

void test_missing_trailing_newline ()
{
	auto diff = compare::diff_data(Data(@"a\nb"), Data(@"a\nb\n"));
	OAK_ASSERT([Kinds(diff) isEqualToString:@"sc"]);
	OAK_ASSERT(diff.left_missing_newline);
	OAK_ASSERT(!diff.right_missing_newline);
	OAK_ASSERT([diff.left_lines.lastObject isEqualToString:@"b"]);
	OAK_ASSERT([diff.right_lines.lastObject isEqualToString:@"b"]);
}

void test_crlf_lines_differ_but_display_without_cr ()
{
	auto diff = compare::diff_data(Data(@"a\r\nb\r\n"), Data(@"a\nb\n"));
	OAK_ASSERT([Kinds(diff) isEqualToString:@"cc"]);
	OAK_ASSERT(diff.left_crlf);
	OAK_ASSERT(!diff.right_crlf);
	OAK_ASSERT([diff.left_lines isEqual:(@[ @"a", @"b" ])]);
}

void test_binary_and_latin1 ()
{
	char const bytes[] = { 'a', 0, 'b' };
	auto binary = compare::diff_data([NSData dataWithBytes:bytes length:sizeof(bytes)], Data(@"ab"));
	OAK_ASSERT(binary.problem != nil);
	OAK_ASSERT(binary.rows.empty());

	char const latin1[] = { 'c', 'a', 'f', (char)0xE9, '\n' };
	auto text = compare::diff_data([NSData dataWithBytes:latin1 length:sizeof(latin1)], Data(@"café\n"));
	OAK_ASSERT(text.problem == nil);
	OAK_ASSERT([text.left_lines.firstObject isEqualToString:@"café"]);
	OAK_ASSERT([Kinds(text) isEqualToString:@"c"]); // bytes differ
}

void test_diff_files ()
{
	NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"compare-diff-" stringByAppendingString:NSUUID.UUID.UUIDString]];
	[@"x\n" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
	auto added = compare::diff_files(nil, path);
	OAK_ASSERT([Kinds(added) isEqualToString:@"a"]);
	auto missing = compare::diff_files(path, [path stringByAppendingString:@"-missing"]);
	OAK_ASSERT(missing.problem != nil);
	[NSFileManager.defaultManager removeItemAtPath:path error:nil];
}

void test_changed_range ()
{
	OAK_ASSERT(NSEqualRanges(compare::changed_range(@"let value = 1;", @"let value = 42;"), NSMakeRange(12, 1)));
	OAK_ASSERT(NSEqualRanges(compare::changed_range(@"let value = 42;", @"let value = 1;"), NSMakeRange(12, 2)));
	OAK_ASSERT(NSEqualRanges(compare::changed_range(@"same", @"same"), NSMakeRange(4, 0)));
	OAK_ASSERT(NSEqualRanges(compare::changed_range(@"", @"abc"), NSMakeRange(0, 0)));
	OAK_ASSERT(NSEqualRanges(compare::changed_range(@"abc", @""), NSMakeRange(0, 3)));
	OAK_ASSERT(NSEqualRanges(compare::changed_range(@"aaa", @"aa"), NSMakeRange(2, 1)));
	// A changed accent stays with its base letter.
	OAK_ASSERT(NSEqualRanges(compare::changed_range(@"café", @"cafè"), NSMakeRange(3, 2)));
}
