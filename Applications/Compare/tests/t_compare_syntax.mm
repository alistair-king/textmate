#import "../src/compare_syntax.h"
#import "syntax_fixture.h"

static void SetUpBundles ()
{
	OAK_ASSERT(syntax_fixture::install());
}

static NSString* Hex (NSColor* color)
{
	return syntax_fixture::hex(color);
}

static compare::side_syntax_t Syntax (NSArray<NSString*>* lines, NSString* name, BOOL dark = NO)
{
	SetUpBundles();
	NSData* data = [[[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
	return compare::syntax_for_lines(lines, [NSTemporaryDirectory() stringByAppendingPathComponent:name], data, dark);
}

// The run covering `location` on `line`.
static compare::syntax_run_t RunAt (compare::side_syntax_t const& syntax, size_t line, NSUInteger location)
{
	OAK_ASSERT(line < syntax.lines.size());
	for(auto const& run : syntax.lines[line])
	{
		if(NSLocationInRange(location, run.range))
			return run;
	}
	return compare::syntax_run_t();
}

void test_file_type_theme_and_scopes ()
{
	auto syntax = Syntax(@[ @"// note", @"keyword x" ], @"sample.cmpt");
	OAK_ASSERT([syntax.fileType isEqualToString:@"source.comparetest"]);
	OAK_ASSERT([Hex(syntax.background) isEqualToString:@"#FAFAFA"]);
	OAK_ASSERT([Hex(syntax.foreground) isEqualToString:@"#111111"]);
	OAK_ASSERT(!syntax.dark);
	OAK_ASSERT(syntax.font != nil);
	OAK_ASSERT_EQ(syntax.lines.size(), 2);

	auto comment = RunAt(syntax, 0, 3);
	OAK_ASSERT([Hex(comment.foreground) isEqualToString:@"#FF0000"]);
	OAK_ASSERT(comment.traits & NSItalicFontMask);
	OAK_ASSERT(NSMaxRange(comment.range) == 7);

	auto keyword = RunAt(syntax, 1, 0);
	OAK_ASSERT([Hex(keyword.foreground) isEqualToString:@"#0000FF"]);
	OAK_ASSERT(keyword.traits & NSBoldFontMask);
	OAK_ASSERT(keyword.underline);
	OAK_ASSERT(NSEqualRanges(keyword.range, NSMakeRange(0, 7)));

	auto plain = RunAt(syntax, 1, 8);
	OAK_ASSERT([Hex(plain.foreground) isEqualToString:@"#111111"]);
	OAK_ASSERT(plain.traits == 0 && !plain.underline);
}

void test_state_carries_across_lines ()
{
	auto syntax = Syntax(@[ @"/* open", @"still inside", @"done */ keyword" ], @"block.cmpt");
	OAK_ASSERT([Hex(RunAt(syntax, 1, 2).foreground) isEqualToString:@"#FF0000"]);
	OAK_ASSERT([Hex(RunAt(syntax, 2, 0).foreground) isEqualToString:@"#FF0000"]);
	OAK_ASSERT([Hex(RunAt(syntax, 2, 9).foreground) isEqualToString:@"#0000FF"]);
}

void test_utf16_ranges ()
{
	// “é” and an emoji take one and two UTF-16 units; the keyword after them must line up.
	auto syntax = Syntax(@[ @"é😀 keyword" ], @"unicode.cmpt");
	NSUInteger start = [@"é😀 " length];
	OAK_ASSERT(NSEqualRanges(RunAt(syntax, 0, start).range, NSMakeRange(start, 7)));
	OAK_ASSERT([Hex(RunAt(syntax, 0, start).foreground) isEqualToString:@"#0000FF"]);
}

void test_dark_appearance_picks_the_dark_theme ()
{
	auto syntax = Syntax(@[ @"keyword" ], @"dark.cmpt", YES);
	OAK_ASSERT([Hex(syntax.background) isEqualToString:@"#101010"]);
	OAK_ASSERT(syntax.dark);
	OAK_ASSERT([Hex(RunAt(syntax, 0, 0).foreground) isEqualToString:@"#0000FF"]);
}

void test_without_a_grammar_uses_theme_colors_only ()
{
	auto syntax = Syntax(@[ @"keyword" ], @"plain.unknownext");
	OAK_ASSERT(syntax.fileType == nil);
	OAK_ASSERT(syntax.lines.empty());
	OAK_ASSERT([Hex(syntax.background) isEqualToString:@"#FAFAFA"]);
}

void test_large_files_are_not_parsed ()
{
	SetUpBundles();
	NSMutableData* big = [NSMutableData dataWithLength:compare::kSyntaxSizeLimit + 1];
	auto syntax = compare::syntax_for_lines(@[ @"keyword" ], [NSTemporaryDirectory() stringByAppendingPathComponent:@"big.cmpt"], big, NO);
	OAK_ASSERT(syntax.lines.empty());
	OAK_ASSERT([Hex(syntax.background) isEqualToString:@"#FAFAFA"]);
}
