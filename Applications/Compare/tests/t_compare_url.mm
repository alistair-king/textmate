#import "../src/compare_url.h"

static compare::request_t RoundTrip (NSString* left, NSString* right, NSString* focus)
{
	compare::request_t request;
	NSURL* url = compare::url(left, right, focus);
	OAK_ASSERT(url != nil);
	OAK_ASSERT(compare::parse(url, &request));
	return request;
}

void test_round_trip_plain_paths ()
{
	compare::request_t request = RoundTrip(@"/Users/me/develop", @"/Users/me/feature", nil);
	OAK_ASSERT([request.left isEqualToString:@"/Users/me/develop"]);
	OAK_ASSERT([request.right isEqualToString:@"/Users/me/feature"]);
	OAK_ASSERT(request.focus == nil);
}

void test_round_trip_separator_characters ()
{
	NSString* left  = @"/tmp/a&b=c+d#e;f%20g?h";
	NSString* right = @"/tmp/space é\ncheckout";
	compare::request_t request = RoundTrip(left, right, @"Frameworks/a&b");
	OAK_ASSERT([request.left isEqualToString:left]);
	OAK_ASSERT([request.right isEqualToString:right]);
	OAK_ASSERT([request.focus isEqualToString:@"Frameworks/a&b"]);
}

void test_empty_focus_is_omitted ()
{
	compare::request_t request = RoundTrip(@"/a", @"/b", @"");
	OAK_ASSERT(request.focus == nil);
	OAK_ASSERT([compare::url(@"/a", @"/b", @"").absoluteString rangeOfString:@"focus"].location == NSNotFound);
}

void test_rejects_invalid_requests ()
{
	OAK_ASSERT(compare::url(@"relative", @"/b") == nil);
	OAK_ASSERT(compare::url(@"/a", nil) == nil);
	OAK_ASSERT(compare::url(@"/a", @"/b", @"/absolute") == nil);
	OAK_ASSERT(compare::url(@"/a", @"/b", @"x/../y") == nil);
	OAK_ASSERT(compare::url(@"/a", @"/b", @"x//y") == nil);
	OAK_ASSERT(compare::url(@"/a", @"/b", @"./x") == nil);

	OAK_ASSERT(!compare::parse([NSURL URLWithString:@"textmate-theme-editor://compare/?left=%2Fa&right=%2Fb"], nullptr));
	OAK_ASSERT(!compare::parse([NSURL URLWithString:@"textmate-compare://other/?left=%2Fa&right=%2Fb"], nullptr));
	OAK_ASSERT(!compare::parse([NSURL URLWithString:@"textmate-compare://compare/?left=%2Fa"], nullptr));
	OAK_ASSERT(!compare::parse([NSURL URLWithString:@"textmate-compare://compare/?left=a&right=%2Fb"], nullptr));
	OAK_ASSERT(!compare::parse([NSURL URLWithString:@"textmate-compare://compare/?left=%2Fa&right=%2Fb&left=%2Fc"], nullptr));
	OAK_ASSERT(!compare::parse([NSURL URLWithString:@"textmate-compare://compare/?left=%2Fa&right=%2Fb&extra=1"], nullptr));
	OAK_ASSERT(!compare::parse([NSURL URLWithString:@"textmate-compare://compare/?left=%2Fa&right=%2Fb&focus=..%2Fx"], nullptr));
	OAK_ASSERT(!compare::parse([NSURL URLWithString:@"textmate-compare://compare/?left=%2Fa&right=%2Fb&flag"], nullptr));
}

void test_parses_unencoded_plus_literally ()
{
	compare::request_t request;
	OAK_ASSERT(compare::parse([NSURL URLWithString:@"textmate-compare://compare/?left=%2Fa+b&right=%2Fc"], &request));
	OAK_ASSERT([request.left isEqualToString:@"/a+b"]);
}
