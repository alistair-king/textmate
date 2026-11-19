#ifndef CONTEXTUALBUNDLEMENUS_H_Q8M3ZK2T
#define CONTEXTUALBUNDLEMENUS_H_Q8M3ZK2T

// Promotes bundles relevant to the frontmost document window to top-level
// menus, inserted directly after the Bundles menu. The bundles stay in the
// Bundles menu as well.
//
// Project-wide bundles (matched by window scope attributes such as
// attr.scm.git or attr.project.cargo, either through their items’ scope
// selectors or by bundle name, e.g. attr.scm.git → Git) are shown while a
// document window is open. File-specific bundles (matched by the selected document’s file type)
// are only shown while a document is selected; a window with no documents
// (e.g. only the file browser) keeps just the project-wide ones.
//
// Controlled by kUserDefaultsShowContextualBundleMenusKey.

@interface ContextualBundleMenus : NSObject
- (instancetype)initWithBundlesMenu:(NSMenu*)bundlesMenu;
@end

#endif /* end of include guard: CONTEXTUALBUNDLEMENUS_H_Q8M3ZK2T */
