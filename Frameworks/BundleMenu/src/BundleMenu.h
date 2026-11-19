#ifndef BUNDLEMENU_H_BI4UDOAR
#define BUNDLEMENU_H_BI4UDOAR

#import <bundles/bundles.h>

@interface BundleMenuDelegate : NSObject <NSMenuDelegate>
@property (class, readonly) BundleMenuDelegate* sharedInstance;
@end

// Replace the contents of aMenu with the menu of umbrellaItem (a bundle or bundle submenu).
void OakPopulateMenuWithBundleMenuItem (NSMenu* aMenu, bundles::item_ptr umbrellaItem);

bundles::item_ptr OakShowMenuForBundleItems (std::vector<bundles::item_ptr> const& items, NSView* view, NSPoint pos);

#endif /* end of include guard: BUNDLEMENU_H_BI4UDOAR */
