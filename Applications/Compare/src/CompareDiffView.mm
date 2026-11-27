#import "CompareDiffView.h"
#import "compare_tree.h"
#import "compare_diff.h"
#import "compare_colors.h"
#import "compare_transfer.h"
#import "compare_syntax.h"
#import "CompareLanguage.h"
#include <algorithm>
#include <memory>
#include <vector>

NSAttributedStringKey const CompareLineTintAttributeName = @"CompareLineTint";

@implementation CompareSeparatorView
{
	BOOL _vertical;
}

- (instancetype)initVertical:(BOOL)vertical
{
	if(self = [super initWithFrame:NSZeroRect])
	{
		_vertical = vertical;
		self.translatesAutoresizingMaskIntoConstraints = NO;
		NSLayoutConstraintOrientation across = vertical ? NSLayoutConstraintOrientationHorizontal : NSLayoutConstraintOrientationVertical;
		[self setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:across];
		[self setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:across];
	}
	return self;
}

- (NSSize)intrinsicContentSize
{
	return _vertical ? NSMakeSize(1, NSViewNoIntrinsicMetric) : NSMakeSize(NSViewNoIntrinsicMetric, 1);
}

// Views do not clip to their bounds by default (macOS 14); every view here
// that draws keeps its drawing, and so its backing layer, inside its bounds.
- (BOOL)clipsToBounds { return YES; }

- (void)drawRect:(NSRect)dirtyRect
{
	[NSColor.separatorColor set];
	NSRectFill(self.bounds);
}
@end

// ===========================================
// = Full-width line backgrounds (TextKit 1) =
// ===========================================

@interface CompareLineLayoutManager : NSLayoutManager
@end

@implementation CompareLineLayoutManager
- (void)drawBackgroundForGlyphRange:(NSRange)glyphsToShow atPoint:(NSPoint)origin
{
	NSTextStorage* storage = self.textStorage;
	[self enumerateLineFragmentsForGlyphRange:glyphsToShow usingBlock:^(NSRect rect, NSRect usedRect, NSTextContainer* container, NSRange glyphRange, BOOL* stop){
		NSUInteger index = [self characterIndexForGlyphAtIndex:glyphRange.location];
		NSColor* tint = index < storage.length ? [storage attribute:CompareLineTintAttributeName atIndex:index effectiveRange:nullptr] : nil;
		if(!tint)
			return;
		NSTextView* textView = container.textView;
		compare::fill_row(tint, NSMakeRect(0, NSMinY(rect) + origin.y, NSWidth(textView.bounds), NSHeight(rect)));
	}];
	// Changed-text spans (NSBackgroundColorAttributeName) draw on top.
	[super drawBackgroundForGlyphRange:glyphsToShow atPoint:origin];
}
@end

// ==========================
// = Line numbers per row =
// ==========================

struct side_rows_t
{
	std::vector<NSUInteger> starts; // character index where each row begins
	std::vector<long> lines;        // 0-based line shown on each row, -1 for gaps
	std::vector<NSColor*> tints;    // each row's background, nil for unchanged rows
};

@interface CompareLineNumberRuler : NSRulerView
@property (nonatomic) std::shared_ptr<side_rows_t> rows;
@end

@implementation CompareLineNumberRuler
- (instancetype)initWithScrollView:(NSScrollView*)scrollView
{
	if(self = [super initWithScrollView:scrollView orientation:NSVerticalRuler])
		self.ruleThickness = 36;
	return self;
}

- (void)setRows:(std::shared_ptr<side_rows_t>)rows
{
	_rows = rows;
	long last = rows && !rows->lines.empty() ? *std::max_element(rows->lines.begin(), rows->lines.end()) + 1 : 1;
	NSString* widest = [@"" stringByPaddingToLength:MAX(3, (NSUInteger)log10(MAX(last, 1)) + 1) withString:@"8" startingAtIndex:0];
	self.ruleThickness = ceil([widest sizeWithAttributes:@{ NSFontAttributeName: self.font }].width) + 14;
	self.needsDisplay = YES;
}

- (NSFont*)font
{
	return [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
}

- (BOOL)clipsToBounds { return YES; }

- (void)drawHashMarksAndLabelsInRect:(NSRect)rect
{
	rect = NSIntersectionRect(rect, self.bounds);
	[NSColor.controlBackgroundColor set];
	NSRectFill(rect);
	[NSColor.separatorColor set];
	NSRectFill(NSMakeRect(NSMaxX(self.bounds) - 1, NSMinY(rect), 1, NSHeight(rect)));

	NSTextView* textView = (NSTextView*)self.clientView;
	if(!_rows || _rows->starts.empty() || ![textView isKindOfClass:NSTextView.class])
		return;

	NSLayoutManager* layoutManager = textView.layoutManager;
	NSRange glyphs = [layoutManager glyphRangeForBoundingRect:textView.visibleRect inTextContainer:textView.textContainer];
	NSDictionary* attributes = @{ NSFontAttributeName: self.font, NSForegroundColorAttributeName: NSColor.secondaryLabelColor };
	auto const& starts = _rows->starts;
	auto const& lines  = _rows->lines;
	auto const& tints  = _rows->tints;
	[layoutManager enumerateLineFragmentsForGlyphRange:glyphs usingBlock:^(NSRect fragment, NSRect usedRect, NSTextContainer* container, NSRange glyphRange, BOOL* stop){
		NSUInteger index = [layoutManager characterIndexForGlyphAtIndex:glyphRange.location];
		auto it = std::upper_bound(starts.begin(), starts.end(), index);
		if(it == starts.begin())
			return;
		size_t row = it - starts.begin() - 1;
		// The row's difference tint continues into the gutter (left of the separator).
		if(row < tints.size() && tints[row])
		{
			NSRect band = [self convertRect:NSMakeRect(0, NSMinY(fragment) + textView.textContainerOrigin.y, 1, NSHeight(fragment)) fromView:textView];
			compare::fill_row(tints[row], NSIntersectionRect(rect, NSMakeRect(0, NSMinY(band), self.ruleThickness - 1, NSHeight(band))));
		}
		if(row >= lines.size() || lines[row] < 0)
			return;
		NSString* label = [NSString stringWithFormat:@"%ld", lines[row] + 1];
		NSSize size = [label sizeWithAttributes:attributes];
		NSPoint top = [self convertPoint:NSMakePoint(0, NSMinY(fragment) + textView.textContainerOrigin.y) fromView:textView];
		[label drawAtPoint:NSMakePoint(self.ruleThickness - size.width - 7, top.y + (NSHeight(fragment) - size.height) / 2) withAttributes:attributes];
	}];
}
@end

// =================
// = The diff view =
// =================

// How far loading a file comparison has got, written by the worker queue.
struct load_progress_t
{
	enum phase_t { reading, highlighting, building, laying_out };
	std::atomic<int> phase{reading};
	std::atomic<long> lines{0};       // lines highlighted so far, both sides
	std::atomic<long> total_lines{0}; // lines to highlight, both sides
	std::atomic<long> rows{0};        // rows of text built so far
	std::atomic<long> total_rows{0};
};

// Covers the empty text while a file loads: a spinner, the file, and the step.
@interface CompareFileLoadingView : NSView
@end

@implementation CompareFileLoadingView
- (void)drawRect:(NSRect)dirtyRect
{
	[NSColor.textBackgroundColor setFill];
	NSRectFill(dirtyRect);
}
@end

struct prepared_diff_t
{
	NSString* message = nil;
	NSString* status  = nil;
	NSAttributedString* left  = nil;
	NSAttributedString* right = nil;
	std::shared_ptr<side_rows_t> left_rows, right_rows;
	std::vector<long> hunk_rows; // first row of each change
	std::vector<compare::diff_hunk_t> hunks;
	NSData* left_data  = nil;
	NSData* right_data = nil;
	CGFloat row_height = 0;
	NSColor* background[2] = { nil, nil }; // the theme's, per side
	BOOL dark[2] = { NO, NO };
	NSString* file_type[2] = { nil, nil };   // for choosing a language server
};

static NSFont* DefaultFont ()
{
	return [NSFont userFixedPitchFontOfSize:11] ?: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
}

static CGFloat LineHeight (NSFont* font)
{
	return ceil(font.ascender - font.descender + font.leading);
}

static CGFloat const kTextInset = 2; // textContainerInset.height

// The font with bold and/or italic, as the theme asks (sizes stay the same so
// rows keep one height).
static NSFont* FontWithTraits (NSFont* font, NSFontTraitMask traits)
{
	CTFontSymbolicTraits symbolic = ((traits & NSBoldFontMask) ? kCTFontBoldTrait : 0) | ((traits & NSItalicFontMask) ? kCTFontItalicTrait : 0);
	if(!symbolic)
		return font;
	CTFontRef variant = CTFontCreateCopyWithSymbolicTraits((__bridge CTFontRef)font, 0, nullptr, symbolic, kCTFontBoldTrait|kCTFontItalicTrait);
	return variant ? (__bridge_transfer NSFont*)variant : font;
}

static NSString* Plural (NSUInteger count, NSString* singular, NSString* plural)
{
	return [NSString stringWithFormat:@"%lu %@", count, count == 1 ? singular : plural];
}

// Builds both sides off the main thread, in each file's editor font and
// theme colors, with its syntax highlighting.
static prepared_diff_t Prepare (compare::text_diff_t const& diff, compare::side_syntax_t const syntax[2], std::atomic<long>* builtRows = nullptr)
{
	prepared_diff_t result;
	if(diff.problem)
	{
		result.message = diff.problem;
		return result;
	}

	NSFont* fonts[2];
	for(size_t i = 0; i < 2; ++i)
		fonts[i] = syntax[i].font ?: DefaultFont();
	result.row_height = MAX(LineHeight(fonts[0]), LineHeight(fonts[1]));
	NSMutableParagraphStyle* style = [NSMutableParagraphStyle new];
	style.minimumLineHeight = style.maximumLineHeight = result.row_height;
	NSDictionary* bases[2];
	for(size_t i = 0; i < 2; ++i)
	{
		bases[i] = @{ NSFontAttributeName: fonts[i], NSForegroundColorAttributeName: syntax[i].foreground ?: NSColor.textColor, NSParagraphStyleAttributeName: style };
		result.background[i] = syntax[i].background;
		result.dark[i]       = syntax[i].dark;
		result.file_type[i]  = syntax[i].fileType;
	}

	NSMutableAttributedString* left  = [[NSMutableAttributedString alloc] init];
	NSMutableAttributedString* right = [[NSMutableAttributedString alloc] init];
	auto leftRows  = std::make_shared<side_rows_t>();
	auto rightRows = std::make_shared<side_rows_t>();

	auto append = [&](NSMutableAttributedString* text, size_t side, side_rows_t& rows, long line, NSArray<NSString*>* lines, NSColor* tint, NSString* other){
		rows.starts.push_back(text.length);
		rows.lines.push_back(line);
		rows.tints.push_back(tint);
		NSString* content = line >= 0 ? lines[line] : @"";
		NSUInteger start = text.length;
		[text appendAttributedString:[[NSAttributedString alloc] initWithString:[content stringByAppendingString:@"\n"] attributes:bases[side]]];
		if(line >= 0 && (size_t)line < syntax[side].lines.size())
		{
			for(auto const& run : syntax[side].lines[line])
			{
				NSRange range = NSIntersectionRange(run.range, NSMakeRange(0, content.length));
				if(!range.length)
					continue;
				range.location += start;
				NSMutableDictionary* attributes = [NSMutableDictionary dictionary];
				if(run.foreground)
					attributes[NSForegroundColorAttributeName] = run.foreground;
				if(run.traits)
					attributes[NSFontAttributeName] = FontWithTraits(fonts[side], run.traits);
				if(run.underline)
					attributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
				if(run.strikethrough)
					attributes[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle);
				[text addAttributes:attributes range:range];
			}
		}
		if(tint)
			[text addAttribute:CompareLineTintAttributeName value:tint range:NSMakeRange(start, content.length + 1)];
		if(other)
		{
			NSRange changed = compare::changed_range(content, other);
			if(changed.length)
				[text addAttribute:NSBackgroundColorAttributeName value:compare::changed_text_color() range:NSMakeRange(start + changed.location, changed.length)];
		}
	};

	long previousHunk = -1;
	for(size_t i = 0; i < diff.rows.size(); ++i)
	{
		if(builtRows)
			++*builtRows;
		auto const& row = diff.rows[i];
		if(row.hunk != -1 && row.hunk != previousHunk)
			result.hunk_rows.push_back(i);
		previousHunk = row.hunk;

		NSColor* leftTint  = nil;
		NSColor* rightTint = nil;
		NSString* leftOther  = nil;
		NSString* rightOther = nil;
		switch(row.kind)
		{
			case compare::row_kind::same: break;
			case compare::row_kind::changed:
				leftTint   = rightTint = compare::modified_color();
				leftOther  = diff.right_lines[row.right];
				rightOther = diff.left_lines[row.left];
			break;
			case compare::row_kind::removed:
				leftTint  = compare::added_color();
				rightTint = compare::placeholder_color();
			break;
			case compare::row_kind::added:
				leftTint  = compare::placeholder_color();
				rightTint = compare::added_color();
			break;
		}
		append(left,  0, *leftRows,  row.left,  diff.left_lines,  leftTint,  leftOther);
		append(right, 1, *rightRows, row.right, diff.right_lines, rightTint, rightOther);
	}

	NSMutableArray* status = [NSMutableArray array];
	if(diff.hunks.empty())
	{
		[status addObject:diff.rows.empty() ? @"Empty" : @"No differences"];
	}
	else
	{
		long removed = 0, added = 0, changed = 0;
		for(auto const& row : diff.rows)
		{
			changed += row.kind == compare::row_kind::changed;
			removed += row.kind == compare::row_kind::removed;
			added   += row.kind == compare::row_kind::added;
		}
		[status addObject:Plural(diff.hunks.size(), @"change", @"changes")];
		if(changed) [status addObject:Plural(changed, @"line modified", @"lines modified")];
		if(removed) [status addObject:Plural(removed, @"line only on the left", @"lines only on the left")];
		if(added)   [status addObject:Plural(added, @"line only on the right", @"lines only on the right")];
	}
	if(diff.left_crlf != diff.right_crlf)
		[status addObject:[NSString stringWithFormat:@"CRLF line endings on the %@", diff.left_crlf ? @"left" : @"right"]];
	if(diff.left_missing_newline != diff.right_missing_newline)
		[status addObject:[NSString stringWithFormat:@"no newline at end of file on the %@", diff.left_missing_newline ? @"left" : @"right"]];

	result.hunks      = diff.hunks;
	result.left_data  = diff.left_data;
	result.right_data = diff.right_data;
	result.status     = [status componentsJoinedByString:@" · "];
	result.left       = left;
	result.right      = right;
	result.left_rows  = leftRows;
	result.right_rows = rightRows;
	return result;
}

static NSString* KindName (CompareKind kind)
{
	switch(kind)
	{
		case CompareKindFile:      return @"a file";
		case CompareKindDirectory: return @"a folder";
		case CompareKindSymlink:   return @"a symbolic link";
		default:                   return @"a special item";
	}
}

// A message when the entry has no text to compare, otherwise nil.
static NSString* MessageForNode (CompareNode* node)
{
	if(!node)
		return @"Select a file to compare its contents.";
	if(node.status == CompareStatusTypeChanged)
		return [NSString stringWithFormat:@"“%@” is %@ on the left and %@ on the right.", node.name, KindName(node.leftKind), KindName(node.rightKind)];
	if(node.isFolder)
		return node.status == CompareStatusIdentical ? @"The folders are identical." : @"Select a file to compare its contents.";

	CompareKind kind = node.leftKind != CompareKindNone ? node.leftKind : node.rightKind;
	if(kind == CompareKindSymlink)
	{
		NSString* leftTarget  = node.leftPath  ? [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:node.leftPath error:nil]  : nil;
		NSString* rightTarget = node.rightPath ? [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:node.rightPath error:nil] : nil;
		if(leftTarget && rightTarget)
			return node.status == CompareStatusIdentical ? [NSString stringWithFormat:@"Both symbolic links point to “%@”.", leftTarget] : [NSString stringWithFormat:@"The symbolic link points to “%@” on the left and “%@” on the right.", leftTarget, rightTarget];
		return [NSString stringWithFormat:@"A symbolic link to “%@”, only on the %@.", leftTarget ?: rightTarget, leftTarget ? @"left" : @"right"];
	}
	if(kind != CompareKindFile)
		return @"Submodules and nested repositories are not compared.";
	return nil;
}

// ==============================================
// = Copy arrows between the two sides, per change =
// ==============================================

// One match of the find bar's string: a side and a range in its text.
struct find_match_t
{
	size_t side;
	NSRange range;
	long row;
};

@interface CompareDiffView (Strip)
- (std::vector<std::pair<long, long>>)changeRows; // first row and row count of each change
- (CGFloat)scrollOffset;
- (NSColor*)stripTintForRow:(long)row;
- (void)stripClickedChange:(NSInteger)change toRight:(BOOL)toRight;
@end

static CGFloat const kStripWidth = 34;

@interface CompareChangeStrip : NSView
@property (nonatomic, weak) CompareDiffView* diffView;
@end

@implementation CompareChangeStrip
- (BOOL)isFlipped { return YES; }
- (BOOL)clipsToBounds { return YES; }

- (NSSize)intrinsicContentSize
{
	return NSMakeSize(kStripWidth, NSViewNoIntrinsicMetric);
}

// The arrows sit on each change's first row: → copies it to the right, ← to the left.
- (NSRect)arrowRectForChange:(std::pair<long, long> const&)rows toRight:(BOOL)toRight
{
	CGFloat height = self.diffView.rowHeight;
	CGFloat y = kTextInset + rows.first * height - self.diffView.scrollOffset;
	return NSMakeRect(toRight ? 1 : kStripWidth / 2, y, kStripWidth / 2 - 1, height);
}

- (void)drawRect:(NSRect)dirtyRect
{
	dirtyRect = NSIntersectionRect(dirtyRect, self.bounds);
	[NSColor.controlBackgroundColor set];
	NSRectFill(dirtyRect);
	[NSColor.separatorColor set];
	NSRectFill(NSMakeRect(0, NSMinY(dirtyRect), 1, NSHeight(dirtyRect)));
	NSRectFill(NSMakeRect(NSMaxX(self.bounds) - 1, NSMinY(dirtyRect), 1, NSHeight(dirtyRect)));

	CGFloat height = self.diffView.rowHeight;
	NSImageSymbolConfiguration* configuration = [[NSImageSymbolConfiguration configurationWithPointSize:height * 0.62 weight:NSFontWeightSemibold] configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:NSColor.secondaryLabelColor]];
	NSImage* right = [[NSImage imageWithSystemSymbolName:@"arrow.right" accessibilityDescription:@"Copy to the right"] imageWithSymbolConfiguration:configuration];
	NSImage* left  = [[NSImage imageWithSystemSymbolName:@"arrow.left" accessibilityDescription:@"Copy to the left"] imageWithSymbolConfiguration:configuration];
	for(auto const& rows : self.diffView.changeRows)
	{
		CGFloat y = kTextInset + rows.first * height - self.diffView.scrollOffset;
		NSRect band = NSMakeRect(1, y, NSWidth(self.bounds) - 2, MAX(rows.second, 1) * height);
		if(!NSIntersectsRect(band, dirtyRect))
			continue;
		// Row by row: orange where both sides have a changed line, neutral
		// beside lines on one side only.
		long first = MAX(rows.first, (long)floor((NSMinY(dirtyRect) - y) / height) + rows.first);
		long last  = MIN(rows.first + MAX(rows.second, 1L), (long)ceil((NSMaxY(dirtyRect) - y) / height) + rows.first);
		for(long row = first; row < last; ++row)
		{
			if(NSColor* tint = [self.diffView stripTintForRow:row])
			{
				[tint set];
				NSRectFillUsingOperation(NSMakeRect(1, y + (row - rows.first) * height, NSWidth(self.bounds) - 2, height), NSCompositingOperationSourceOver);
			}
		}
		for(BOOL toRight : { YES, NO })
		{
			NSImage* image = toRight ? right : left;
			NSRect cell = [self arrowRectForChange:rows toRight:toRight];
			NSSize size = image.size;
			NSRect target = NSMakeRect(round(NSMidX(cell) - size.width / 2), round(NSMidY(cell) - size.height / 2), size.width, size.height);
			[image drawInRect:target fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
		}
	}
}

- (void)mouseDown:(NSEvent*)event
{
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	auto changes = self.diffView.changeRows;
	for(size_t i = 0; i < changes.size(); ++i)
	{
		for(BOOL toRight : { YES, NO })
		{
			if(NSPointInRect(point, [self arrowRectForChange:changes[i] toRight:toRight]))
			{
				[self.diffView stripClickedChange:i toRight:toRight];
				return;
			}
		}
	}
}

- (void)resetCursorRects
{
	for(auto const& rows : self.diffView.changeRows)
	{
		for(BOOL toRight : { YES, NO })
			[self addCursorRect:NSIntersectionRect([self arrowRectForChange:rows toRight:toRight], self.bounds) cursor:NSCursor.pointingHandCursor];
	}
}
@end

// ===================
// = Language server =
// ===================

// ⌘-click asks the handler first: it returns NO when the side has no
// language server, and the click selects as usual.
@interface CompareTextView : NSTextView
@property (nonatomic, copy) BOOL (^commandClickHandler)(CompareTextView* textView, NSUInteger index);
@end

@implementation CompareTextView
- (void)mouseDown:(NSEvent*)event
{
	NSEventModifierFlags const modifiers = NSEventModifierFlagCommand|NSEventModifierFlagShift|NSEventModifierFlagOption|NSEventModifierFlagControl;
	if((event.modifierFlags & modifiers) == NSEventModifierFlagCommand && event.clickCount == 1 && _commandClickHandler)
	{
		NSUInteger index = [self characterIndexAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
		if(index != NSNotFound && _commandClickHandler(self, index))
			return;
	}
	[super mouseDown:event];
}

// The character under a point in the view, NSNotFound past the end of a line.
- (NSUInteger)characterIndexAtPoint:(NSPoint)point
{
	NSLayoutManager* layoutManager = self.layoutManager;
	point.x -= self.textContainerOrigin.x;
	point.y -= self.textContainerOrigin.y;
	NSUInteger glyph = [layoutManager glyphIndexForPoint:point inTextContainer:self.textContainer fractionOfDistanceThroughGlyph:nullptr];
	if(glyph >= layoutManager.numberOfGlyphs)
		return NSNotFound;
	NSRect rect = [layoutManager boundingRectForGlyphRange:NSMakeRange(glyph, 1) inTextContainer:self.textContainer];
	if(!NSPointInRect(point, rect))
		return NSNotFound;
	return [layoutManager characterIndexForGlyphAtIndex:glyph];
}
@end

// A hover's contents: fenced code in the file's font, the rest as inline
// Markdown (or plain text, as the server sent it).
static NSAttributedString* HoverText (NSDictionary* hover, NSFont* codeFont)
{
	NSString* value = hover[@"value"];
	if(!value.length)
		return nil;
	NSFont* textFont = [NSFont systemFontOfSize:NSFont.systemFontSize];
	NSDictionary* codeAttributes = @{ NSFontAttributeName: codeFont, NSForegroundColorAttributeName: NSColor.labelColor };
	NSDictionary* textAttributes = @{ NSFontAttributeName: textFont, NSForegroundColorAttributeName: NSColor.labelColor };
	NSCharacterSet* whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
	if(![hover[@"kind"] isEqualToString:@"markdown"])
		return [[NSAttributedString alloc] initWithString:[value stringByTrimmingCharactersInSet:whitespace] attributes:hover[@"language"] ? codeAttributes : textAttributes];

	NSMutableAttributedString* result = [NSMutableAttributedString new];
	NSArray<NSString*>* parts = [value componentsSeparatedByString:@"```"];
	for(NSUInteger i = 0; i < parts.count; ++i)
	{
		NSString* part = parts[i];
		NSAttributedString* text;
		if(i % 2) // inside a fence: the first line names the language
		{
			NSRange newline = [part rangeOfString:@"\n"];
			part = [(newline.location == NSNotFound ? part : [part substringFromIndex:NSMaxRange(newline)]) stringByTrimmingCharactersInSet:whitespace];
			text = part.length ? [[NSAttributedString alloc] initWithString:part attributes:codeAttributes] : nil;
		}
		else
		{
			part = [[part stringByReplacingOccurrencesOfString:@"\n---\n" withString:@"\n\n"] stringByTrimmingCharactersInSet:whitespace];
			if(!part.length || [part isEqualToString:@"---"])
				continue;
			NSAttributedStringMarkdownParsingOptions* options = [NSAttributedStringMarkdownParsingOptions new];
			options.interpretedSyntax = NSAttributedStringMarkdownInterpretedSyntaxInlineOnlyPreservingWhitespace;
			NSMutableAttributedString* markdown = [[[NSAttributedString alloc] initWithMarkdownString:part options:options baseURL:nil error:nil] mutableCopy];
			if(!markdown)
			{
				text = [[NSAttributedString alloc] initWithString:part attributes:textAttributes];
			}
			else
			{
				// AppKit draws fonts, not presentation intents.
				[markdown addAttributes:textAttributes range:NSMakeRange(0, markdown.length)];
				[markdown enumerateAttribute:NSInlinePresentationIntentAttributeName inRange:NSMakeRange(0, markdown.length) options:0 usingBlock:^(NSNumber* value, NSRange range, BOOL*){
					NSUInteger intent = value.unsignedIntegerValue;
					if(intent & NSInlinePresentationIntentCode)
						[markdown addAttribute:NSFontAttributeName value:codeFont range:range];
					else if(intent & (NSInlinePresentationIntentStronglyEmphasized|NSInlinePresentationIntentEmphasized))
						[markdown addAttribute:NSFontAttributeName value:[NSFontManager.sharedFontManager convertFont:textFont toHaveTrait:(intent & NSInlinePresentationIntentStronglyEmphasized ? NSBoldFontMask : 0)|(intent & NSInlinePresentationIntentEmphasized ? NSItalicFontMask : 0)] range:range];
				}];
				text = markdown;
			}
		}
		if(!text.length)
			continue;
		if(result.length)
			[result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n\n" attributes:textAttributes]];
		[result appendAttributedString:text];
	}
	return result.length ? result : nil;
}

@interface CompareDiffView () <NSSearchFieldDelegate, NSPopoverDelegate>
@end

@implementation CompareDiffView
{
	NSTextField* _pathLabel;
	NSTextField* _statusLabel;
	NSTextField* _changeLabel;
	NSSegmentedControl* _navigation;
	NSTextField* _messageLabel;
	CompareFileLoadingView* _loadingView;
	NSProgressIndicator* _loadingSpinner;
	NSTextField* _loadingTitle;
	NSTextField* _loadingDetail;
	NSTimer* _loadingTimer;
	std::shared_ptr<load_progress_t> _loadProgress;
	NSString* _loadingSize;          // “2.4 MB”, for the detail line
	NSView* _findBar;                // Edit → Find: searches both sides
	NSLayoutConstraint* _findBarHeight;
	NSSearchField* _findField;
	NSTextField* _findCountLabel;
	NSSegmentedControl* _findNavigation;
	NSButton* _matchCaseButton;
	std::vector<find_match_t> _findMatches;
	NSInteger _findIndex;            // the current match, -1 for none
	size_t _lastFindSide;            // where the current match is, for focus on closing
	NSView* _sidesHeader;            // above each side: name, branch and path
	NSTextField* _sideNames[2];
	NSTextField* _sideBranches[2];
	NSTextField* _sidePaths[2];
	NSString* _branches[2];
	NSScrollView* _scrollViews[2];
	NSTextView* _textViews[2];
	CompareLineNumberRuler* _rulers[2];
	NSView* _body;
	std::vector<long> _hunkRows;
	std::vector<compare::diff_hunk_t> _hunks;
	BOOL _shownDarkAppearance;
	NSData* _data[2];
	CompareChangeStrip* _strip;
	NSUInteger _generation;
	BOOL _synchronizing;
	CompareLanguageService* _language[2]; // nil without a language server for that side's file
	struct { BOOL active; NSUInteger line, character; BOOL left; } _pendingReveal; // revealLine: while loading
	NSPopover* _hoverPopover;
	NSString* _hoverText;
}

- (instancetype)initWithFrame:(NSRect)frame
{
	if(self = [super initWithFrame:frame])
	{
		_currentChange = -1;
		_rowHeight = LineHeight(DefaultFont());

		_pathLabel = [NSTextField labelWithString:@""];
		_pathLabel.font = [NSFont boldSystemFontOfSize:NSFont.smallSystemFontSize];
		_pathLabel.lineBreakMode = NSLineBreakByTruncatingHead;
		[_pathLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

		_statusLabel = [NSTextField labelWithString:@""];
		_statusLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
		_statusLabel.textColor = NSColor.secondaryLabelColor;
		_statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
		[_statusLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow - 1 forOrientation:NSLayoutConstraintOrientationHorizontal];

		_changeLabel = [NSTextField labelWithString:@""];
		_changeLabel.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
		_changeLabel.textColor = NSColor.secondaryLabelColor;

		_navigation = [NSSegmentedControl segmentedControlWithImages:@[
			[NSImage imageWithSystemSymbolName:@"chevron.up" accessibilityDescription:@"Previous Change"],
			[NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:@"Next Change"],
		] trackingMode:NSSegmentSwitchTrackingMomentary target:self action:@selector(navigate:)];
		_navigation.controlSize = NSControlSizeSmall;
		[_navigation setToolTip:@"Previous Change (⌃⌘↑)" forSegment:0];
		[_navigation setToolTip:@"Next Change (⌃⌘↓)" forSegment:1];

		// The status label takes the spare width.
		[_statusLabel setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
		NSStackView* header = [NSStackView stackViewWithViews:@[ _pathLabel, _statusLabel, _changeLabel, _navigation ]];
		header.spacing    = 8;
		header.edgeInsets = NSEdgeInsetsMake(5, 10, 5, 10);
		[header setHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];

		CompareSeparatorView* divider = [[CompareSeparatorView alloc] initVertical:NO];

		_body = [NSView new];
		[_body setContentHuggingPriority:NSLayoutPriorityDefaultLow - 10 forOrientation:NSLayoutConstraintOrientationVertical];
		for(size_t i = 0; i < 2; ++i)
		{
			[self makeTextViewAtIndex:i];
			_scrollViews[i].translatesAutoresizingMaskIntoConstraints = NO;
			[_body addSubview:_scrollViews[i]];
			[_scrollViews[i].topAnchor constraintEqualToAnchor:_body.topAnchor].active = YES;
			[_scrollViews[i].bottomAnchor constraintEqualToAnchor:_body.bottomAnchor].active = YES;
		}
		_strip = [[CompareChangeStrip alloc] initWithFrame:NSZeroRect];
		_strip.diffView = self;
		_strip.translatesAutoresizingMaskIntoConstraints = NO;
		[_strip setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
		NSView* middle = _strip;
		[_body addSubview:middle];
		[NSLayoutConstraint activateConstraints:@[
			[_scrollViews[0].leadingAnchor constraintEqualToAnchor:_body.leadingAnchor],
			[middle.leadingAnchor constraintEqualToAnchor:_scrollViews[0].trailingAnchor],
			[middle.topAnchor constraintEqualToAnchor:_body.topAnchor],
			[middle.bottomAnchor constraintEqualToAnchor:_body.bottomAnchor],
			[_scrollViews[1].leadingAnchor constraintEqualToAnchor:middle.trailingAnchor],
			[_scrollViews[1].trailingAnchor constraintEqualToAnchor:_body.trailingAnchor],
			[_scrollViews[0].widthAnchor constraintEqualToAnchor:_scrollViews[1].widthAnchor],
		]];

		// Each side's file, as the Files tab's headers show each folder.
		_sidesHeader = [NSView new];
		NSStackView* sideHeaders[2];
		for(size_t i = 0; i < 2; ++i)
		{
			_sideNames[i] = [NSTextField labelWithString:@""];
			_sideNames[i].font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
			_sideNames[i].lineBreakMode = NSLineBreakByTruncatingMiddle;
			[_sideNames[i] setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
			[_sideNames[i] setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];

			_sideBranches[i] = [NSTextField labelWithString:@""];
			_sideBranches[i].font = [NSFont systemFontOfSize:NSFont.systemFontSize];
			_sideBranches[i].textColor = NSColor.secondaryLabelColor;
			_sideBranches[i].lineBreakMode = NSLineBreakByTruncatingMiddle;
			[_sideBranches[i] setContentHuggingPriority:NSLayoutPriorityDefaultHigh + 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
			[_sideBranches[i] setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow - 1 forOrientation:NSLayoutConstraintOrientationHorizontal];

			NSStackView* title = [NSStackView stackViewWithViews:@[ _sideNames[i], _sideBranches[i] ]];
			title.spacing = 6;
			[title setHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];

			_sidePaths[i] = [NSTextField labelWithString:@""];
			_sidePaths[i].font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
			_sidePaths[i].textColor = NSColor.secondaryLabelColor;
			_sidePaths[i].lineBreakMode = NSLineBreakByTruncatingMiddle;
			[_sidePaths[i] setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

			sideHeaders[i] = [NSStackView stackViewWithViews:@[ title, _sidePaths[i] ]];
			sideHeaders[i].orientation = NSUserInterfaceLayoutOrientationVertical;
			sideHeaders[i].alignment   = NSLayoutAttributeLeading;
			sideHeaders[i].spacing     = 2;
			sideHeaders[i].edgeInsets  = NSEdgeInsetsMake(8, 10, 8, 10);
			sideHeaders[i].translatesAutoresizingMaskIntoConstraints = NO;
			[_sidesHeader addSubview:sideHeaders[i]];
			[sideHeaders[i].topAnchor constraintEqualToAnchor:_sidesHeader.topAnchor].active = YES;
			[sideHeaders[i].bottomAnchor constraintLessThanOrEqualToAnchor:_sidesHeader.bottomAnchor].active = YES;
		}
		[_sidesHeader setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];
		CompareSeparatorView* sidesDivider = [[CompareSeparatorView alloc] initVertical:NO];

		_messageLabel = [NSTextField wrappingLabelWithString:@""];
		_messageLabel.alignment = NSTextAlignmentCenter;
		_messageLabel.textColor = NSColor.secondaryLabelColor;
		_messageLabel.translatesAutoresizingMaskIntoConstraints = NO;

		_loadingView = [self makeLoadingView];
		_findBar = [self makeFindBar];
		_findIndex = -1;
		for(NSView* view in @[ header, divider, _findBar, _sidesHeader, sidesDivider, _body, _messageLabel, _loadingView ])
		{
			view.translatesAutoresizingMaskIntoConstraints = NO;
			[self addSubview:view];
		}
		[NSLayoutConstraint activateConstraints:@[
			[header.topAnchor constraintEqualToAnchor:self.topAnchor],
			[header.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
			[header.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
			[divider.topAnchor constraintEqualToAnchor:header.bottomAnchor],
			[divider.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
			[divider.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
			[_findBar.topAnchor constraintEqualToAnchor:divider.bottomAnchor],
			[_findBar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
			[_findBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
			_findBarHeight = [_findBar.heightAnchor constraintEqualToConstant:0],
			[_sidesHeader.topAnchor constraintEqualToAnchor:_findBar.bottomAnchor],
			[_sidesHeader.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
			[_sidesHeader.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
			// Each side's header lines up with its text.
			[sideHeaders[0].leadingAnchor constraintEqualToAnchor:_scrollViews[0].leadingAnchor],
			[sideHeaders[0].trailingAnchor constraintEqualToAnchor:_scrollViews[0].trailingAnchor],
			[sideHeaders[1].leadingAnchor constraintEqualToAnchor:_scrollViews[1].leadingAnchor],
			[sideHeaders[1].trailingAnchor constraintEqualToAnchor:_scrollViews[1].trailingAnchor],
			[_sidesHeader.bottomAnchor constraintEqualToAnchor:sideHeaders[0].bottomAnchor],
			[sidesDivider.topAnchor constraintEqualToAnchor:_sidesHeader.bottomAnchor],
			[sidesDivider.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
			[sidesDivider.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
			[_body.topAnchor constraintEqualToAnchor:sidesDivider.bottomAnchor],
			[_body.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
			[_body.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
			[_body.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
			[_loadingView.topAnchor constraintEqualToAnchor:_body.topAnchor],
			[_loadingView.bottomAnchor constraintEqualToAnchor:_body.bottomAnchor],
			[_loadingView.leadingAnchor constraintEqualToAnchor:_body.leadingAnchor],
			[_loadingView.trailingAnchor constraintEqualToAnchor:_body.trailingAnchor],
			[_messageLabel.centerXAnchor constraintEqualToAnchor:_body.centerXAnchor],
			[_messageLabel.centerYAnchor constraintEqualToAnchor:_body.centerYAnchor],
			[_messageLabel.widthAnchor constraintLessThanOrEqualToAnchor:_body.widthAnchor multiplier:0.8],
		]];

		[self showMessage:@"Select a file to compare its contents."];
	}
	return self;
}

- (void)dealloc
{
	[_loadingTimer invalidate];
	[_hoverPopover close];
	[self closeLanguageServers];
	[NSNotificationCenter.defaultCenter removeObserver:self];
}

// ============
// = Find bar =
// ============

static CGFloat const kFindBarHeight = 34;

- (NSView*)makeFindBar
{
	_findField = [NSSearchField new];
	_findField.placeholderString = @"Find in both sides";
	_findField.controlSize = NSControlSizeSmall;
	_findField.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
	_findField.delegate = self;
	_findField.sendsSearchStringImmediately = YES;
	_findField.accessibilityLabel = @"Find";
	[_findField.widthAnchor constraintEqualToConstant:240].active = YES;

	_findCountLabel = [NSTextField labelWithString:@""];
	_findCountLabel.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
	_findCountLabel.textColor = NSColor.secondaryLabelColor;

	_findNavigation = [NSSegmentedControl segmentedControlWithImages:@[
		[NSImage imageWithSystemSymbolName:@"chevron.left" accessibilityDescription:@"Previous Match"],
		[NSImage imageWithSystemSymbolName:@"chevron.right" accessibilityDescription:@"Next Match"],
	] trackingMode:NSSegmentSwitchTrackingMomentary target:self action:@selector(findNavigate:)];
	_findNavigation.controlSize = NSControlSizeSmall;
	[_findNavigation setToolTip:@"Find Previous (⇧⌘G)" forSegment:0];
	[_findNavigation setToolTip:@"Find Next (⌘G)" forSegment:1];

	_matchCaseButton = [NSButton checkboxWithTitle:@"Match Case" target:self action:@selector(findOptionsChanged:)];
	_matchCaseButton.controlSize = NSControlSizeSmall;
	_matchCaseButton.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];

	NSButton* done = [NSButton buttonWithTitle:@"Done" target:self action:@selector(hideFindBar:)];
	done.controlSize = NSControlSizeSmall;
	done.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];

	NSStackView* row = [NSStackView new];
	row.spacing = 8;
	row.edgeInsets = NSEdgeInsetsMake(0, 10, 0, 10);
	for(NSView* view in @[ _findField, _findNavigation, _findCountLabel ])
		[row addView:view inGravity:NSStackViewGravityLeading];
	[row addView:_matchCaseButton inGravity:NSStackViewGravityTrailing];
	[row addView:done inGravity:NSStackViewGravityTrailing];
	row.translatesAutoresizingMaskIntoConstraints = NO;

	CompareSeparatorView* line = [[CompareSeparatorView alloc] initVertical:NO];
	line.translatesAutoresizingMaskIntoConstraints = NO;

	NSView* bar = [NSView new];
	bar.hidden = YES;
	bar.wantsLayer = YES;
	bar.layer.masksToBounds = YES; // collapsed to no height while hidden
	[bar addSubview:row];
	[bar addSubview:line];
	[NSLayoutConstraint activateConstraints:@[
		[row.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
		[row.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],
		[row.topAnchor constraintEqualToAnchor:bar.topAnchor],
		[row.heightAnchor constraintEqualToConstant:kFindBarHeight - 1],
		[line.topAnchor constraintEqualToAnchor:row.bottomAnchor],
		[line.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
		[line.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],
	]];
	return bar;
}

- (BOOL)isFindBarVisible
{
	return !_findBar.hidden;
}

- (IBAction)showFindBar:(id)sender
{
	if(_findBar.hidden)
	{
		_findBar.hidden = NO;
		_findBarHeight.constant = kFindBarHeight;
		[self updateFind];
	}
	[self.window makeFirstResponder:_findField];
	[_findField selectText:nil];
}

- (IBAction)hideFindBar:(id)sender
{
	if(_findBar.hidden)
		return;
	_findBar.hidden = YES;
	_findBarHeight.constant = 0;
	[self clearFindHighlights];
	_findMatches.clear();
	_findIndex = -1;
	// Back to the text, keeping the match selected.
	[self.window makeFirstResponder:_textViews[_lastFindSide]];
}

- (NSString*)findString
{
	return _findField.stringValue;
}

- (void)setFindString:(NSString*)string
{
	_findField.stringValue = string ?: @"";
	[self updateFind];
}

- (BOOL)matchesCase
{
	return _matchCaseButton.state == NSControlStateValueOn;
}

- (void)setMatchesCase:(BOOL)flag
{
	_matchCaseButton.state = flag ? NSControlStateValueOn : NSControlStateValueOff;
	[self updateFind];
}

- (NSInteger)findMatchCount  { return _findMatches.size(); }
- (NSInteger)currentFindMatch { return _findIndex; }
- (BOOL)currentFindMatchIsOnLeft { return _findIndex >= 0 && _findMatches[_findIndex].side == 0; }

- (void)controlTextDidChange:(NSNotification*)notification
{
	if(notification.object == _findField)
		[self updateFind];
}

// Return finds the next match (⇧Return the previous), Esc closes the bar.
- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)command
{
	if(control != _findField)
		return NO;
	if(command == @selector(insertNewline:))
	{
		BOOL shift = (NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift) != 0;
		shift ? [self findPrevious:self] : [self findNext:self];
		return YES;
	}
	if(command == @selector(cancelOperation:))
	{
		[self hideFindBar:self];
		return YES;
	}
	return NO;
}

- (void)findOptionsChanged:(id)sender
{
	[self updateFind];
}

- (void)findNavigate:(NSSegmentedControl*)sender
{
	sender.selectedSegment == 0 ? [self findPrevious:sender] : [self findNext:sender];
}

- (IBAction)findNext:(id)sender     { [self moveToFindMatch:_findIndex + 1]; }
- (IBAction)findPrevious:(id)sender { [self moveToFindMatch:_findIndex - 1]; }

// Every match on both sides, in reading order: row by row, the left side's
// before the right's. Gaps (blank rows opposite missing lines) match nothing.
- (void)updateFind
{
	[self findMatchesAgain];

	// Start from the first match at or below what is in view.
	_findIndex = -1;
	if(!_findMatches.empty())
	{
		long top = (long)floor(MAX(0, self.scrollOffset - kTextInset) / MAX(_rowHeight, 1));
		size_t first = 0;
		while(first < _findMatches.size() && _findMatches[first].row < top)
			++first;
		[self moveToFindMatch:first < _findMatches.size() ? first : 0];
	}
	[self updateFindCount];
}

// After the text was reloaded (a copied change, a live refresh): the
// matches again, staying on the same match number and not scrolling.
- (void)findMatchesAgainKeepingPosition
{
	if(_findBar.hidden)
		return;
	[self findMatchesAgain];
	_findIndex = _findMatches.empty() ? -1 : MIN(MAX(_findIndex, 0), (NSInteger)_findMatches.size() - 1);
	[self updateFindCount];
}

- (void)findMatchesAgain
{
	[self clearFindHighlights];
	_findMatches.clear();
	NSString* needle = _findField.stringValue;
	if(!_findBar.hidden && needle.length && !_message && !_loading)
	{
		NSStringCompareOptions options = self.matchesCase ? 0 : NSCaseInsensitiveSearch;
		static size_t const kMaxMatches = 10000;
		for(size_t side = 0; side < 2; ++side)
		{
			NSString* text = _textViews[side].textStorage.string;
			auto const& starts = _rulers[side].rows ? _rulers[side].rows->starts : std::vector<NSUInteger>();
			NSRange search = NSMakeRange(0, text.length);
			while(search.length && _findMatches.size() < kMaxMatches)
			{
				NSRange found = [text rangeOfString:needle options:options range:search];
				if(found.location == NSNotFound)
					break;
				long row = std::upper_bound(starts.begin(), starts.end(), found.location) - starts.begin() - 1;
				_findMatches.push_back({ side, found, row });
				search = NSMakeRange(NSMaxRange(found), text.length - NSMaxRange(found));
			}
		}
		std::stable_sort(_findMatches.begin(), _findMatches.end(), [](find_match_t const& a, find_match_t const& b){
			return a.row != b.row ? a.row < b.row : a.side != b.side ? a.side < b.side : a.range.location < b.range.location;
		});
		for(auto const& match : _findMatches)
			[_textViews[match.side].layoutManager addTemporaryAttribute:NSBackgroundColorAttributeName value:[NSColor.systemYellowColor colorWithAlphaComponent:0.35] forCharacterRange:match.range];
	}
}

- (void)moveToFindMatch:(NSInteger)index
{
	if(_findMatches.empty())
		return NSBeep();
	NSInteger count = _findMatches.size();
	_findIndex = (index % count + count) % count; // wraps around
	auto const& match = _findMatches[_findIndex];
	for(size_t side = 0; side < 2; ++side)
		[_textViews[side] setSelectedRange:NSMakeRange(side == match.side ? match.range.location : 0, 0)];
	NSTextView* textView = _textViews[match.side];
	[textView setSelectedRange:match.range];
	[textView scrollRangeToVisible:match.range];
	[textView showFindIndicatorForRange:match.range];
	_lastFindSide = match.side;
	[self updateFindCount];
}

- (void)updateFindCount
{
	_findField.textColor = _findField.stringValue.length && _findMatches.empty() ? NSColor.systemRedColor : NSColor.controlTextColor;
	if(!_findField.stringValue.length)
		_findCountLabel.stringValue = @"";
	else if(_findMatches.empty())
		_findCountLabel.stringValue = @"No matches";
	else
		_findCountLabel.stringValue = [NSString stringWithFormat:@"%ld of %ld", _findIndex + 1, (long)_findMatches.size()];
	[_findNavigation setEnabled:_findMatches.size() > 0 forSegment:0];
	[_findNavigation setEnabled:_findMatches.size() > 0 forSegment:1];
}

- (void)clearFindHighlights
{
	for(size_t side = 0; side < 2; ++side)
	{
		NSLayoutManager* layoutManager = _textViews[side].layoutManager;
		[layoutManager removeTemporaryAttribute:NSBackgroundColorAttributeName forCharacterRange:NSMakeRange(0, _textViews[side].textStorage.length)];
	}
}

// ===========
// = Loading =
// ===========

- (CompareFileLoadingView*)makeLoadingView
{
	_loadingSpinner = [NSProgressIndicator new];
	_loadingSpinner.style = NSProgressIndicatorStyleSpinning;
	_loadingSpinner.controlSize = NSControlSizeRegular;
	_loadingSpinner.displayedWhenStopped = NO;
	_loadingSpinner.usesThreadedAnimation = YES; // keeps turning while the text is laid out

	_loadingTitle = [NSTextField labelWithString:@""];
	_loadingTitle.font = [NSFont systemFontOfSize:15 weight:NSFontWeightMedium];
	_loadingTitle.textColor = NSColor.secondaryLabelColor;
	_loadingTitle.alignment = NSTextAlignmentCenter;
	_loadingTitle.lineBreakMode = NSLineBreakByTruncatingMiddle;
	[_loadingTitle setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

	_loadingDetail = [NSTextField labelWithString:@""];
	_loadingDetail.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
	_loadingDetail.textColor = NSColor.tertiaryLabelColor;
	_loadingDetail.alignment = NSTextAlignmentCenter;

	NSStackView* stack = [NSStackView stackViewWithViews:@[ _loadingSpinner, _loadingTitle, _loadingDetail ]];
	stack.orientation = NSUserInterfaceLayoutOrientationVertical;
	stack.alignment   = NSLayoutAttributeCenterX;
	stack.spacing     = 8;
	[stack setCustomSpacing:14 afterView:_loadingSpinner];
	stack.translatesAutoresizingMaskIntoConstraints = NO;

	CompareFileLoadingView* view = [CompareFileLoadingView new];
	view.hidden = YES;
	[view addSubview:stack];
	[NSLayoutConstraint activateConstraints:@[
		[stack.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
		[stack.centerYAnchor constraintEqualToAnchor:view.centerYAnchor constant:-20],
		[stack.widthAnchor constraintLessThanOrEqualToAnchor:view.widthAnchor constant:-40],
	]];
	return view;
}

// Over the empty text area (a new tab, or one showing a message); a tab
// that already shows the file keeps its text while it reloads.
- (void)showLoadingTitled:(NSString*)title progress:(std::shared_ptr<load_progress_t>)progress
{
	_loadProgress = progress;
	_message = nil;
	_messageLabel.hidden = YES;
	_body.hidden = YES;
	_loadingTitle.stringValue = title;
	_loadingView.hidden = NO;
	[_loadingSpinner startAnimation:self];
	[self updateLoadingDetail];
	if(!_loadingTimer)
	{
		__weak CompareDiffView* weakSelf = self;
		_loadingTimer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer* timer){
			[weakSelf updateLoadingDetail];
		}];
		[NSRunLoop.currentRunLoop addTimer:_loadingTimer forMode:NSRunLoopCommonModes];
	}
}

- (void)showLoading:(NSString*)title
{
	_loadingSize = nil;
	[self showLoadingTitled:title progress:nullptr];
}

- (void)hideLoading
{
	[_loadingTimer invalidate];
	_loadingTimer = nil;
	[_loadingSpinner stopAnimation:self];
	_loadingView.hidden = YES;
}

- (void)updateLoadingDetail
{
	auto progress = _loadProgress;
	auto number = ^NSString*(long value){
		return [NSNumberFormatter localizedStringFromNumber:@(value) numberStyle:NSNumberFormatterDecimalStyle];
	};
	NSString* step = @"Reading the files…";
	if(!progress)
		;
	else if(progress->phase == load_progress_t::reading)
		step = @"Reading and comparing the files…";
	else if(progress->phase == load_progress_t::highlighting && progress->total_lines > 0)
		step = [NSString stringWithFormat:@"Highlighting: %@ of %@ lines", number(MIN(progress->lines.load(), progress->total_lines.load())), number(progress->total_lines)];
	else if(progress->phase == load_progress_t::building && progress->total_rows > 0)
		step = [NSString stringWithFormat:@"Building the text: %@ of %@ rows", number(MIN(progress->rows.load(), progress->total_rows.load())), number(progress->total_rows)];
	else
		step = @"Laying out the text…";
	_loadingDetail.stringValue = _loadingSize ? [NSString stringWithFormat:@"%@ · %@", _loadingSize, step] : step;
}

- (BOOL)isShowingLoading
{
	return !_loadingView.hidden;
}

- (NSString*)loadingText
{
	return [NSString stringWithFormat:@"%@|%@", _loadingTitle.stringValue, _loadingDetail.stringValue];
}

- (void)makeTextViewAtIndex:(size_t)index
{
	NSTextStorage* storage = [NSTextStorage new];
	CompareLineLayoutManager* layoutManager = [CompareLineLayoutManager new];
	[storage addLayoutManager:layoutManager];
	NSTextContainer* container = [[NSTextContainer alloc] initWithSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
	container.widthTracksTextView = NO;
	container.lineFragmentPadding = 4;
	[layoutManager addTextContainer:container];

	CompareTextView* textView = [[CompareTextView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100) textContainer:container];
	__weak CompareDiffView* weakSelf = self;
	textView.commandClickHandler = ^BOOL(CompareTextView* view, NSUInteger index){
		return [weakSelf commandClickedIndex:index onLeft:view == weakSelf.leftTextView];
	};
	textView.editable                = NO;
	textView.selectable              = YES;
	textView.richText                = NO;
	textView.usesRuler               = NO;
	textView.horizontallyResizable   = YES;
	textView.verticallyResizable     = YES;
	textView.maxSize                 = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
	textView.autoresizingMask        = NSViewWidthSizable|NSViewHeightSizable;
	textView.textContainerInset      = NSMakeSize(0, 2);
	textView.drawsBackground         = YES;
	textView.backgroundColor         = NSColor.textBackgroundColor;
	textView.accessibilityLabel      = index == 0 ? @"Left contents" : @"Right contents";
	textView.automaticLinkDetectionEnabled = NO;

	NSScrollView* scrollView = [NSScrollView new];
	scrollView.borderType            = NSNoBorder;
	scrollView.hasVerticalScroller   = YES;
	scrollView.hasHorizontalScroller = YES;
	scrollView.autohidesScrollers    = YES;
	scrollView.documentView          = textView;

	CompareLineNumberRuler* ruler = [[CompareLineNumberRuler alloc] initWithScrollView:scrollView];
	ruler.clientView = textView;
	scrollView.verticalRulerView = ruler;
	scrollView.hasVerticalRuler  = YES;
	scrollView.rulersVisible     = YES;

	scrollView.contentView.postsBoundsChangedNotifications = YES;
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(clipViewBoundsDidChange:) name:NSViewBoundsDidChangeNotification object:scrollView.contentView];

	_textViews[index]   = textView;
	_scrollViews[index] = scrollView;
	_rulers[index]      = ruler;
}

- (NSTextView*)leftTextView  { return _textViews[0]; }
- (NSTextView*)rightTextView { return _textViews[1]; }
- (NSString*)statusText      { return _statusLabel.stringValue; }

// ===========
// = Content =
// ===========

- (void)showMessage:(NSString*)message
{
	++_generation;
	[self hideLoading];
	[self hideHover];
	[self closeLanguageServers];
	_pendingReveal.active = NO;
	_findMatches.clear();
	_findIndex = -1;
	[self updateFindCount];
	_loading = NO;
	_message = [message copy];
	_messageLabel.stringValue = message ?: @"";
	_messageLabel.hidden = !message;
	_body.hidden = message != nil;
	_hunkRows.clear();
	_hunks.clear();
	_data[0] = _data[1] = nil;
	_currentChange = -1;
	_strip.needsDisplay = YES;
	for(size_t i = 0; i < 2; ++i)
	{
		[_textViews[i].textStorage setAttributedString:[NSAttributedString new]];
		_rulers[i].rows = nullptr;
	}
	[self updateNavigation];
}

- (void)updateNode:(CompareNode*)node
{
	_node = node;
	[self updateSideHeaders];
}

- (void)setBranch:(NSString*)branch onLeft:(BOOL)left
{
	_branches[left ? 0 : 1] = [branch copy];
	[self updateSideHeaders];
}

- (NSString*)branchOnLeft:(BOOL)left
{
	return _branches[left ? 0 : 1];
}

// Each side's file name and branch, and its path below; a side without the
// file shows where it would be, dimmed.
- (void)updateSideHeaders
{
	for(size_t i = 0; i < 2; ++i)
	{
		BOOL left = i == 0;
		NSString* path = [_node pathOnLeft:left];
		BOOL present = (left ? _node.leftKind : _node.rightKind) != CompareKindNone;
		_sideNames[i].stringValue    = path.lastPathComponent ?: @"";
		_sideNames[i].textColor      = present ? NSColor.labelColor : NSColor.tertiaryLabelColor;
		_sideBranches[i].stringValue = _branches[i] ?: @"";
		_sidePaths[i].stringValue    = path.stringByAbbreviatingWithTildeInPath ?: @"";
		_sidePaths[i].toolTip        = path;
	}
}

- (NSString*)sideHeaderTextOnLeft:(BOOL)left
{
	size_t i = left ? 0 : 1;
	return [NSString stringWithFormat:@"%@|%@|%@", _sideNames[i].stringValue, _sideBranches[i].stringValue, _sidePaths[i].stringValue];
}

- (void)showNode:(CompareNode*)node
{
	[self showNode:node keepingChange:NO];
}

- (void)showNode:(CompareNode*)node keepingChange:(BOOL)keep
{
	_node = node;
	[self updateSideHeaders];
	[self hideHover];
	NSInteger keptChange = keep ? _currentChange : -1;
	_pathLabel.stringValue  = node.relativePath ?: @"";
	_statusLabel.stringValue = @"";
	if(NSString* message = MessageForNode(node))
	{
		[self showMessage:message];
		return;
	}

	NSUInteger generation = ++_generation;
	_loading = YES;
	_statusLabel.stringValue = @"Loading…";
	NSString* left  = node.leftKind  == CompareKindFile ? node.leftPath  : nil;
	NSString* right = node.rightKind == CompareKindFile ? node.rightPath : nil;
	BOOL darkAppearance = self.darkAppearance;
	_shownDarkAppearance = darkAppearance;
	auto progress = std::make_shared<load_progress_t>();
	if(_body.hidden) // nothing of this file shown yet
	{
		long long size = MAX(node.leftStamp.size, node.rightStamp.size);
		_loadingSize = size > 0 ? [NSByteCountFormatter stringFromByteCount:size countStyle:NSByteCountFormatterCountStyleFile] : nil;
		[self showLoadingTitled:[NSString stringWithFormat:@"Opening “%@”…", node.name.length ? node.name : (left ?: right).lastPathComponent] progress:progress];
	}
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		compare::text_diff_t diff = compare::diff_files(left, right);
		// A side without the file still gets the other file's theme and font.
		compare::side_syntax_t syntax[2];
		if(!diff.problem)
		{
			progress->total_lines = (long)(diff.left_lines.count + diff.right_lines.count);
			progress->phase = load_progress_t::highlighting;
			syntax[0] = compare::syntax_for_lines(diff.left_lines,  left ?: right, diff.left_data,  darkAppearance, &progress->lines);
			syntax[1] = compare::syntax_for_lines(diff.right_lines, right ?: left, diff.right_data, darkAppearance, &progress->lines);
		}
		progress->total_rows = (long)diff.rows.size();
		progress->phase = load_progress_t::building;
		auto prepared = std::make_shared<prepared_diff_t>(Prepare(diff, syntax, &progress->rows));
		progress->phase = load_progress_t::laying_out;
		dispatch_async(dispatch_get_main_queue(), ^{
			if(generation != _generation)
				return;
			[self showPrepared:*prepared change:keptChange];
		});
	});
}

// The appearance of the window this view is in, or will be in once its tab
// is shown (a tab's view is not in the window until it is selected).
- (BOOL)darkAppearance
{
	NSAppearance* appearance = self.window ? self.effectiveAppearance : (_hostWindow.effectiveAppearance ?: NSApp.effectiveAppearance);
	return [[appearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] isEqualToString:NSAppearanceNameDarkAqua];
}

// Like TextMate's editor, switch to the other appearance's theme when the
// appearance changes (also when the view first joins its window).
- (void)viewDidChangeEffectiveAppearance
{
	[super viewDidChangeEffectiveAppearance];
	if(_node && !_message && self.darkAppearance != _shownDarkAppearance)
		[self showNode:_node keepingChange:YES];
}

- (void)showPrepared:(prepared_diff_t const&)prepared change:(NSInteger)keptChange
{
	if(prepared.message)
	{
		[self showMessage:prepared.message];
		return;
	}
	// Laying the text out blocks the main thread: say so before it starts.
	if(!_loadingView.hidden)
	{
		[self updateLoadingDetail];
		[_loadingView displayIfNeeded];
		[CATransaction flush];
	}
	_loading = NO;
	_message = nil;
	_messageLabel.hidden = YES;
	_body.hidden = NO;
	// Selected while loading, the hidden text could not take the focus.
	if(self.window.firstResponder == self.window)
		[self.window makeFirstResponder:self.leftTextView];
	_statusLabel.stringValue = prepared.status ?: @"";
	_hunkRows = prepared.hunk_rows;
	_hunks    = prepared.hunks;
	_data[0]  = prepared.left_data;
	_data[1]  = prepared.right_data;

	_rowHeight = prepared.row_height;
	NSAttributedString* texts[2] = { prepared.left, prepared.right };
	std::shared_ptr<side_rows_t> rows[2] = { prepared.left_rows, prepared.right_rows };
	for(size_t i = 0; i < 2; ++i)
	{
		// The theme's background; a dark theme draws the text (and the
		// difference tints, which follow the appearance) as dark.
		_textViews[i].backgroundColor = prepared.background[i] ?: NSColor.textBackgroundColor;
		_scrollViews[i].appearance = prepared.background[i] ? [NSAppearance appearanceNamed:prepared.dark[i] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua] : nil;
		[_textViews[i].textStorage setAttributedString:texts[i]];
		_rulers[i].rows = rows[i];
		[_textViews[i] scrollPoint:NSZeroPoint];
	}

	_currentChange = -1;
	if(!_hunkRows.empty())
		[self goToChange:MIN(MAX(keptChange, 0), (NSInteger)_hunkRows.size() - 1)];
	else
		[self updateNavigation];
	[self updateLanguageServersWithFileTypes:prepared.file_type];
	if(_pendingReveal.active) // a definition in this file, asked for while it loaded
	{
		_pendingReveal.active = NO;
		[self revealLine:_pendingReveal.line character:_pendingReveal.character onLeft:_pendingReveal.left];
	}
	[self.window invalidateCursorRectsForView:_strip];
	_strip.needsDisplay = YES;
	[self findMatchesAgainKeepingPosition];
	[self hideLoading]; // last: the text is laid out and scrolled to its change
}

// ===================
// = Copying changes =
// ===================

- (std::vector<std::pair<long, long>>)changeRows
{
	std::vector<std::pair<long, long>> rows;
	if(!_message)
	{
		for(auto const& hunk : _hunks)
			rows.emplace_back(hunk.first_row, hunk.row_count);
	}
	return rows;
}

// The strip's color for a row: tinted only where a line changed on both
// sides; beside a line on one side only (a gap on the other) it stays neutral.
- (NSColor*)stripTintForRow:(long)row
{
	NSColor* tints[2] = { nil, nil };
	for(size_t i = 0; i < 2; ++i)
	{
		if(_rulers[i].rows && row >= 0 && (size_t)row < _rulers[i].rows->tints.size())
			tints[i] = _rulers[i].rows->tints[row];
	}
	return tints[0] == compare::modified_color() && tints[1] == compare::modified_color() ? tints[0] : nil;
}

- (CGFloat)scrollOffset
{
	return _scrollViews[0].contentView.bounds.origin.y;
}

- (void)stripClickedChange:(NSInteger)change toRight:(BOOL)toRight
{
	_currentChange = change;
	[self updateNavigation];
	if(_changeHandler)
		_changeHandler(self, change, toRight);
}

- (NSData*)comparedDataOnLeft:(BOOL)left
{
	return _data[left ? 0 : 1];
}

- (NSInteger)editingLineOnLeft:(BOOL)left
{
	if(_hunks.empty())
		return 1;
	auto const& hunk = _hunks[std::clamp<NSInteger>(_currentChange, 0, _hunks.size() - 1)];
	return std::max<long>(left ? hunk.left_start : hunk.right_start, 0) + 1;
}

- (NSData*)contentsWithChange:(NSInteger)change toRight:(BOOL)toRight
{
	if(change < 0 || change >= (NSInteger)_hunks.size() || !_data[0] || !_data[1])
		return nil;
	return compare::apply_hunk(_data[0], _data[1], _hunks[change], toRight);
}

// ==============
// = Navigation =
// ==============

- (NSInteger)changeCount
{
	return _hunkRows.size();
}

- (void)updateNavigation
{
	NSInteger count = self.changeCount;
	_navigation.hidden = _changeLabel.hidden = count == 0;
	[_navigation setEnabled:_currentChange > 0 forSegment:0];
	[_navigation setEnabled:_currentChange + 1 < count forSegment:1];
	_changeLabel.stringValue = count ? [NSString stringWithFormat:@"Change %ld of %ld", MAX(_currentChange, 0) + 1, count] : @"";
}

- (void)goToChange:(NSInteger)change
{
	if(change < 0 || change >= self.changeCount)
		return;
	_currentChange = change;
	[self updateNavigation];
	[self scrollRowIntoView:_hunkRows[change]];
}

// Puts the row a quarter of the way down, on both sides.
- (void)scrollRowIntoView:(long)row
{
	// Rows have a fixed height and start at the same offset on both sides.
	// Both sides are laid out first as far as the row and a screenful
	// below it: a side not laid out that far is still too short to scroll
	// there, so its scroll view pulls the position back (and the other side
	// with it, as they scroll together). The rest is laid out later; it only
	// makes the sides taller, which moves nothing.
	NSClipView* clip = _scrollViews[0].contentView;
	long visibleRows = (long)ceil(NSHeight(clip.bounds) / MAX(_rowHeight, 1)) + 2;
	for(size_t i = 0; i < 2; ++i)
	{
		NSTextView* side = _textViews[i];
		auto const& starts = _rulers[i].rows->starts;
		size_t end = (size_t)row + visibleRows;
		NSUInteger length = end < starts.size() ? starts[end] : side.textStorage.length;
		[side.layoutManager ensureLayoutForCharacterRange:NSMakeRange(0, MIN(length, side.textStorage.length))];
	}
	NSTextView* textView = _textViews[0];
	NSUInteger index = _rulers[0].rows->starts[row];
	NSRange glyphs = [textView.layoutManager glyphRangeForCharacterRange:NSMakeRange(index, 0) actualCharacterRange:nullptr];
	NSRect line = [textView.layoutManager lineFragmentRectForGlyphAtIndex:glyphs.location effectiveRange:nullptr];
	CGFloat y = MAX(0, NSMinY(line) + textView.textContainerOrigin.y - NSHeight(clip.bounds) / 4);
	y = MIN(y, MAX(0, NSHeight(textView.frame) - NSHeight(clip.bounds)));
	[clip scrollToPoint:NSMakePoint(clip.bounds.origin.x, y)];
	[_scrollViews[0] reflectScrolledClipView:clip];
}

- (IBAction)nextChange:(id)sender     { [self goToChange:_currentChange + 1]; }
- (IBAction)previousChange:(id)sender { [self goToChange:_currentChange - 1]; }

- (void)navigate:(NSSegmentedControl*)sender
{
	if(sender.selectedSegment == 0)
			[self previousChange:sender];
	else	[self nextChange:sender];
}

- (BOOL)validateMenuItem:(NSMenuItem*)item
{
	if(item.action == @selector(goToDefinition:) || item.action == @selector(showHoverInfo:))
		return !_loading && !_message && _language[self.focusedSide].available;
	if(item.action == @selector(nextChange:))
		return _currentChange + 1 < self.changeCount;
	if(item.action == @selector(previousChange:))
		return _currentChange > 0;
	return YES;
}

- (void)clipViewBoundsDidChange:(NSNotification*)notification
{
	if(_synchronizing)
		return;
	NSClipView* source = notification.object;
	NSScrollView* other = source == _scrollViews[0].contentView ? _scrollViews[1] : _scrollViews[0];
	NSClipView* destination = other.contentView;
	if(NSEqualPoints(destination.bounds.origin, source.bounds.origin))
	{
		_strip.needsDisplay = YES;
		return;
	}
	_synchronizing = YES;
	[destination scrollToPoint:source.bounds.origin];
	[other reflectScrolledClipView:destination];
	_synchronizing = NO;
	_strip.needsDisplay = YES;
	[self.window invalidateCursorRectsForView:_strip];
}

// ===================
// = Language server =
// ===================

- (void)closeLanguageServers
{
	for(size_t i = 0; i < 2; ++i)
	{
		[_language[i] close];
		_language[i] = nil;
	}
}

// Once a file is shown: a server for each side's file, kept while it stays
// the same file (reloads after changes on disk keep the document).
- (void)updateLanguageServersWithFileTypes:(NSString* const*)fileTypes
{
	NSString* paths[2] = {
		_node.leftKind  == CompareKindFile ? _node.leftPath  : nil,
		_node.rightKind == CompareKindFile ? _node.rightPath : nil,
	};
	for(size_t i = 0; i < 2; ++i)
	{
		if(_language[i] && [_language[i].path isEqualToString:paths[i]])
			continue;
		[_language[i] close];
		_language[i] = [CompareLanguageService serviceForPath:paths[i] fileType:fileTypes[i]];
	}
}

- (BOOL)hasLanguageServerOnLeft:(BOOL)left     { return _language[left ? 0 : 1].available; }
- (BOOL)isLanguageServerReadyOnLeft:(BOOL)left { return _language[left ? 0 : 1].ready; }

// The side with the focus, else the left.
- (size_t)focusedSide
{
	return self.window.firstResponder == _textViews[1] ? 1 : 0;
}

// The 0-based line and UTF-16 character shown at a character index of one
// side. NO on a gap.
- (BOOL)position:(NSUInteger)index onSide:(size_t)side line:(NSUInteger*)line character:(NSUInteger*)character
{
	std::shared_ptr<side_rows_t> const& rows = _rulers[side].rows;
	if(!rows || rows->starts.empty())
		return NO;
	size_t row = std::upper_bound(rows->starts.begin(), rows->starts.end(), index) - rows->starts.begin() - 1; // starts[0] is 0
	if(rows->lines[row] < 0)
		return NO;
	*line      = rows->lines[row];
	*character = index - rows->starts[row];
	return YES;
}

- (void)revealLine:(NSUInteger)line character:(NSUInteger)character onLeft:(BOOL)left
{
	if(_loading)
	{
		_pendingReveal = { YES, line, character, left };
		return;
	}
	size_t side = left ? 0 : 1;
	std::shared_ptr<side_rows_t> const rows = _rulers[side].rows;
	if(!rows || rows->starts.empty())
		return;
	// Lines go up down the rows, with gaps (-1) between them.
	auto found = std::find(rows->lines.begin(), rows->lines.end(), (long)line);
	if(found == rows->lines.end())
		return;
	long row = found - rows->lines.begin();
	[self scrollRowIntoView:row];

	NSTextView* textView = _textViews[side];
	NSUInteger start = rows->starts[row];
	NSUInteger end   = (row + 1 < (long)rows->starts.size() ? rows->starts[row + 1] : textView.textStorage.length) - 1; // before the newline
	NSUInteger index = MIN(start + character, end);
	NSRange word = NSIntersectionRange([textView selectionRangeForProposedRange:NSMakeRange(index, 0) granularity:NSSelectByWord], NSMakeRange(start, end - start));
	[self.window makeFirstResponder:textView];
	textView.selectedRange = word.length ? word : NSMakeRange(index, 0);
	if(word.length && self.window)
		[textView showFindIndicatorForRange:word];
}

- (BOOL)commandClickedIndex:(NSUInteger)index onLeft:(BOOL)left
{
	size_t side = left ? 0 : 1;
	if(!_language[side].available)
		return NO;
	[self.window makeFirstResponder:_textViews[side]];
	_textViews[side].selectedRange = NSMakeRange(index, 0);
	[self goToDefinitionAtIndex:index onLeft:left];
	return YES;
}

- (IBAction)goToDefinition:(id)sender
{
	size_t side = self.focusedSide;
	[self goToDefinitionAtIndex:_textViews[side].selectedRange.location onLeft:side == 0];
}

- (void)goToDefinitionAtIndex:(NSUInteger)index onLeft:(BOOL)left
{
	size_t side = left ? 0 : 1;
	CompareLanguageService* service = _language[side];
	NSUInteger line, character;
	if(_loading || !service.available || ![self position:index onSide:side line:&line character:&character])
		return NSBeep();

	__weak CompareDiffView* weakSelf = self;
	[service definitionAtLine:line character:character completion:^(NSArray<NSDictionary*>* locations){
		CompareDiffView* strongSelf = weakSelf;
		if(!strongSelf || strongSelf->_language[side] != service) // another file, or sides swapped, since
			return;
		NSDictionary* location = CompareBestDefinition(locations, service.path, line);
		NSString* path = location ? [NSURL URLWithString:location[@"uri"]].path : nil;
		if(!path)
			return NSBeep();
		NSUInteger targetLine      = [location[@"line"] unsignedIntegerValue];
		NSUInteger targetCharacter = [location[@"character"] unsignedIntegerValue];
		if([CompareCanonicalPath(path) isEqualToString:CompareCanonicalPath(service.path)])
			[strongSelf revealLine:targetLine character:targetCharacter onLeft:left];
		else if(strongSelf.definitionHandler)
			strongSelf.definitionHandler(strongSelf, path, targetLine, targetCharacter, left);
	}];
}

- (IBAction)showHoverInfo:(id)sender
{
	size_t side = self.focusedSide;
	[self showHoverAtIndex:_textViews[side].selectedRange.location onLeft:side == 0];
}

- (void)showHoverAtIndex:(NSUInteger)index onLeft:(BOOL)left
{
	[self hideHover];
	size_t side = left ? 0 : 1;
	CompareLanguageService* service = _language[side];
	NSUInteger line, character;
	if(_loading || !service.available || ![self position:index onSide:side line:&line character:&character])
		return NSBeep();

	// `index` is into the text shown now: a reload (same file, same service)
	// may have replaced it by the time the answer comes.
	NSUInteger generation = _generation;
	__weak CompareDiffView* weakSelf = self;
	[service hoverAtLine:line character:character completion:^(NSDictionary* hover){
		CompareDiffView* strongSelf = weakSelf;
		if(!strongSelf || strongSelf->_language[side] != service || strongSelf->_generation != generation)
			return;
		NSTextView* textView = strongSelf->_textViews[side];
		NSFont* font = index < textView.textStorage.length ? [textView.textStorage attribute:NSFontAttributeName atIndex:index effectiveRange:nullptr] : nil;
		NSAttributedString* text = HoverText(hover, font ?: DefaultFont());
		if(!text)
			return NSBeep();
		[strongSelf showHover:text atIndex:index side:side];
	}];
}

- (void)showHover:(NSAttributedString*)text atIndex:(NSUInteger)index side:(size_t)side
{
	NSTextView* textView = _textViews[side];
	NSUInteger length = textView.textStorage.length;
	NSRange word = [textView selectionRangeForProposedRange:NSMakeRange(index, 0) granularity:NSSelectByWord];
	if(!word.length)
		word = NSMakeRange(MIN(index, length), index < length ? 1 : 0);
	NSLayoutManager* layoutManager = textView.layoutManager;
	NSRect rect = [layoutManager boundingRectForGlyphRange:[layoutManager glyphRangeForCharacterRange:word actualCharacterRange:nullptr] inTextContainer:textView.textContainer];
	rect = NSOffsetRect(rect, textView.textContainerOrigin.x, textView.textContainerOrigin.y);

	CGFloat const maxWidth = 560, maxHeight = 320, inset = 10;
	NSRect bounds = [text boundingRectWithSize:NSMakeSize(maxWidth - 2 * inset, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin|NSStringDrawingUsesFontLeading];
	NSSize size = NSMakeSize(MIN(maxWidth, ceil(NSWidth(bounds)) + 2 * inset + 10), MIN(maxHeight, ceil(NSHeight(bounds)) + 2 * inset));

	NSTextView* contents = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
	contents.editable           = NO;
	contents.selectable         = YES;
	contents.drawsBackground    = NO;
	contents.textContainerInset = NSMakeSize(inset, inset);
	contents.autoresizingMask   = NSViewWidthSizable;
	[contents.textStorage setAttributedString:text];
	NSScrollView* scrollView = [[NSScrollView alloc] initWithFrame:contents.frame];
	scrollView.drawsBackground     = NO;
	scrollView.hasVerticalScroller = NSHeight(bounds) + 2 * inset > maxHeight;
	scrollView.documentView        = contents;
	NSViewController* controller = [NSViewController new];
	controller.view = scrollView;

	_hoverPopover = [NSPopover new];
	_hoverPopover.behavior = NSPopoverBehaviorTransient;
	_hoverPopover.contentViewController = controller;
	_hoverPopover.contentSize = size;
	_hoverPopover.delegate = self;
	_hoverText = text.string;
	if(textView.window)
		[_hoverPopover showRelativeToRect:rect ofView:textView preferredEdge:NSRectEdgeMaxY];
}

- (void)hideHover
{
	[_hoverPopover close];
	_hoverPopover = nil;
	_hoverText = nil;
}

- (void)popoverDidClose:(NSNotification*)notification
{
	if(notification.object == _hoverPopover)
	{
		_hoverPopover = nil;
		_hoverText = nil;
	}
}
@end
