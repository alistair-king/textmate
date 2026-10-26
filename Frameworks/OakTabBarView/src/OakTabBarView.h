#import <oak/misc.h>

typedef NS_ENUM(NSInteger, OakTabStatus) {
    OakTabStatusNone, OakTabStatusWorking, OakTabStatusBlocked, OakTabStatusDone, OakTabStatusError
};

@protocol OakTabBarViewDelegate, OakTabBarViewDataSource;

@interface OakTabBarView : NSView
@property (nonatomic, weak) id <OakTabBarViewDelegate> delegate;
@property (nonatomic, weak) id <OakTabBarViewDataSource> dataSource;
@property (nonatomic, readonly) NSInteger countOfVisibleTabs;
@property (nonatomic) NSUInteger selectedTabIndex;
- (void)reloadData;
- (void)performClose:(id)sender;

@property (nonatomic) BOOL neverHideLeftBorder;
@end

@protocol OakTabBarViewDelegate <NSObject>
@optional
- (BOOL)tabBarView:(OakTabBarView*)aTabBarView shouldSelectIndex:(NSUInteger)anIndex;
- (void)tabBarView:(OakTabBarView*)aTabBarView didDoubleClickIndex:(NSUInteger)anIndex;
- (void)tabBarView:(OakTabBarView*)aTabBarView setTitle:(NSString*)title forIndex:(NSUInteger)anIndex;
- (void)tabBarViewDidDoubleClick:(OakTabBarView*)aTabBarView;
- (NSMenu*)menuForTabBarView:(OakTabBarView*)aTabBarView;

// Methods sent to the delegate which the tab was dragged to
- (BOOL)performDropOfTabItem:(NSUUID*)tabItemUUID fromTabBar:(OakTabBarView*)sourceTabBar index:(NSUInteger)dragIndex toTabBar:(OakTabBarView*)destTabBar index:(NSUInteger)droppedIndex operation:(NSDragOperation)operation;

- (void)performCloseTab:(OakTabBarView*)sender;
- (void)performCloseOtherTabsXYZ:(OakTabBarView*)sender;
@end

@protocol OakTabBarViewDataSource <NSObject>
- (NSUInteger)numberOfRowsInTabBarView:(OakTabBarView*)aTabBarView;

- (NSString*)tabBarView:(OakTabBarView*)aTabBarView titleForIndex:(NSUInteger)anIndex;
- (NSString*)tabBarView:(OakTabBarView*)aTabBarView pathForIndex:(NSUInteger)anIndex;
- (NSUUID*)tabBarView:(OakTabBarView*)aTabBarView UUIDForIndex:(NSUInteger)anIndex;
- (BOOL)tabBarView:(OakTabBarView*)aTabBarView isEditedAtIndex:(NSUInteger)anIndex;
@optional
- (OakTabStatus)tabBarView:(OakTabBarView*)bar statusForIndex:(NSUInteger)index;
- (NSString*)tabBarView:(OakTabBarView*)bar statusDescriptionForIndex:(NSUInteger)index;
@end
