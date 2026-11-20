#ifndef COMPARE_COLORS_H_K5W2PQ8T
#define COMPARE_COLORS_H_K5W2PQ8T

#import <Cocoa/Cocoa.h>
#import "compare_tree.h"

// Difference tints shared by the tree rows and (later) the file diff view.
// They are translucent overlays on the normal background, slightly stronger
// in dark appearance so they stay visible.

namespace compare {

	inline NSColor* tint (NSString* name, NSColor* base, CGFloat lightAlpha, CGFloat darkAlpha)
	{
		return [NSColor colorWithName:name dynamicProvider:^NSColor*(NSAppearance* appearance){
			BOOL dark = [[appearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] isEqualToString:NSAppearanceNameDarkAqua];
			return [base colorWithAlphaComponent:dark ? darkAlpha : lightAlpha];
		}];
	}

	inline NSColor* modified_color ()     { static NSColor* color = tint(@"compare.modified",    NSColor.systemOrangeColor, 0.22, 0.30); return color; }
	inline NSColor* added_color ()        { static NSColor* color = tint(@"compare.added",       NSColor.systemGreenColor,  0.20, 0.28); return color; }
	inline NSColor* placeholder_color ()  { static NSColor* color = tint(@"compare.placeholder", NSColor.systemGrayColor,   0.14, 0.20); return color; }
	inline NSColor* changed_text_color () { static NSColor* color = tint(@"compare.changedText", NSColor.systemOrangeColor, 0.38, 0.50); return color; }
	inline NSColor* type_changed_color () { static NSColor* color = tint(@"compare.typeChanged", NSColor.systemRedColor,    0.20, 0.28); return color; }

	// The dot marking a folder whose contents differ.
	inline NSColor* marker_color () { return NSColor.systemOrangeColor; }

	// Only differences get a background, so they stand out: a folder on both
	// sides is not itself a difference, even when something inside it is.
	inline BOOL contains_differences (CompareNode* node)
	{
		return node.isFolder && node.status == CompareStatusModified;
	}

	// Background for a node's row on one side; nil (the default background)
	// for identical entries and for folders that only contain differences.
	inline NSColor* row_color (CompareNode* node, BOOL leftSide)
	{
		BOOL present = (leftSide ? node.leftKind : node.rightKind) != CompareKindNone;
		switch(node.status)
		{
			case CompareStatusModified:    return node.isFolder ? nil : modified_color();
			case CompareStatusLeftOnly:
			case CompareStatusRightOnly:   return present ? added_color() : placeholder_color();
			case CompareStatusTypeChanged: return type_changed_color();
			default:                       return nil;
		}
	}

} /* compare */

#endif /* end of include guard: COMPARE_COLORS_H_K5W2PQ8T */
