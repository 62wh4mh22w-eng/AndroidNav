// AndroidNav — Android-style virtual navigation bar for iOS 16 SpringBoard
// v0.0.2: attach bar to SpringBoard's existing main window (new UIWindow doesn't show
// on iOS 16 SB). DIAG build: red background to verify injection + UI path.
// Pure Objective-C, no Theos/Logos/Substrate headers required.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - Forward declarations

@interface SBUIController : NSObject
+ (instancetype)sharedInstance;
- (void)clickedMenuButton;
- (void)handleHomeButtonPress;
- (void)handleHomeButtonSinglePressUp;
@end

@interface SBMainSwitcherViewController : NSObject
+ (instancetype)sharedInstanceIfExists;
+ (instancetype)sharedInstance;
- (void)toggleSwitcher;
- (void)beginPresentationOrDismissalIfNecessary;
@end

#pragma mark - Globals

static UIView *gNavBar = nil;
static CGFloat gBarHeight = 54.0;
#define ANDROIDNAV_DIAG 1

#pragma mark - Helpers

static void an_goHome(void) {
    Class cls = NSClassFromString(@"SBUIController");
    if (!cls) return;
    id controller = [cls sharedInstance];
    if (!controller) return;
    if ([controller respondsToSelector:@selector(handleHomeButtonPress)]) {
        [controller handleHomeButtonPress];
    } else if ([controller respondsToSelector:@selector(clickedMenuButton)]) {
        [controller clickedMenuButton];
    } else if ([controller respondsToSelector:@selector(handleHomeButtonSinglePressUp)]) {
        [controller handleHomeButtonSinglePressUp];
    }
}

static void an_openRecents(void) {
    Class cls = NSClassFromString(@"SBMainSwitcherViewController");
    if (!cls) return;
    id switcher = nil;
    if ([cls respondsToSelector:@selector(sharedInstance)]) {
        switcher = [cls sharedInstance];
    } else if ([cls respondsToSelector:@selector(sharedInstanceIfExists)]) {
        switcher = [cls sharedInstanceIfExists];
    }
    if (!switcher) return;
    if ([switcher respondsToSelector:@selector(toggleSwitcher)]) {
        [switcher toggleSwitcher];
    } else if ([switcher respondsToSelector:@selector(beginPresentationOrDismissalIfNecessary)]) {
        [switcher beginPresentationOrDismissalIfNecessary];
    }
}

static void an_goBack(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return;

    [app sendAction:@selector(goBack) to:nil from:nil forEvent:nil];

    UIWindow *keyWindow = nil;
    for (UIWindow *w in [app windows]) {
        if ([w isKeyWindow]) { keyWindow = w; break; }
    }
    if (!keyWindow && [app windows].count) keyWindow = [app windows][0];
    if (keyWindow && [keyWindow respondsToSelector:@selector(rootViewController)]) {
        UIViewController *root = [keyWindow rootViewController];
        if ([root isKindOfClass:[UINavigationController class]]) {
            [(UINavigationController *)root popViewControllerAnimated:YES];
        } else if (root.presentedViewController) {
            [root.presentedViewController dismissViewControllerAnimated:YES completion:nil];
        }
    }
}

#pragma mark - Bar view

@interface ANavBarView : UIView
@end

@implementation ANavBarView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
#if ANDROIDNAV_DIAG
        self.backgroundColor = [UIColor colorWithRed:0.85 green:0.1 blue:0.1 alpha:0.85];
#else
        self.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.92];
#endif
        self.userInteractionEnabled = YES;
        self.clipsToBounds = YES;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        [self an_buildButtons];
    }
    return self;
}

- (void)an_buildButtons {
    for (UIView *v in [self.subviews copy]) [v removeFromSuperview];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat btnW = w / 3.0;
    NSArray *titles = @[@"◁", @"○", @"□"];
    for (NSInteger i = 0; i < 3; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(i * btnW, 2, btnW, h - 4);
        btn.backgroundColor = [UIColor clearColor];
        [btn setTitle:titles[i] forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightMedium];
        btn.tag = i;
        SEL sel = i == 0 ? @selector(an_backTapped:) : (i == 1 ? @selector(an_homeTapped:) : @selector(an_recentsTapped:));
        [btn addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:btn];
    }
}

- (void)an_touchDown:(UIButton *)sender {
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [gen prepare];
        [gen impactOccurred];
    }
}

- (void)an_backTapped:(UIButton *)sender   { an_goBack(); }
- (void)an_homeTapped:(UIButton *)sender   { an_goHome(); }
- (void)an_recentsTapped:(UIButton *)sender { an_openRecents(); }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat btnW = w / 3.0;
    for (UIView *v in self.subviews) {
        if ([v isKindOfClass:[UIButton class]]) {
            NSInteger i = v.tag;
            v.frame = CGRectMake(i * btnW, 2, btnW, h - 4);
        }
    }
}

@end

#pragma mark - Attach logic

// Pick SpringBoard's biggest visible window (its main home screen window).
static UIWindow *an_springBoardMainWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;
    UIWindow *best = nil;
    CGFloat bestArea = 0;
    for (UIWindow *w in [app windows]) {
        if (!w || w.hidden) continue;
        CGRect f = w.bounds;
        CGFloat area = f.size.width * f.size.height;
        if (area > bestArea) { bestArea = area; best = w; }
    }
    return best;
}

static void an_attachBar(void) {
    if (gNavBar && gNavBar.superview) return; // already attached
    if ([NSThread isMainThread]) {
        UIWindow *win = an_springBoardMainWindow();
        if (!win) return;
        if (!gNavBar) {
            CGRect screen = [[UIScreen mainScreen] bounds];
            CGRect frame = CGRectMake(0, screen.size.height - gBarHeight, screen.size.width, gBarHeight);
            gNavBar = [[ANavBarView alloc] initWithFrame:frame];
        }
        gNavBar.frame = CGRectMake(0, win.bounds.size.height - gBarHeight, win.bounds.size.width, gBarHeight);
        gNavBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        [win addSubview:gNavBar];
        [win bringSubviewToFront:gNavBar];
        gNavBar.hidden = NO;
    }
}

static void an_attachOnMain(void) {
    if (gNavBar && gNavBar.superview) return;
    dispatch_async(dispatch_get_main_queue(), ^{ an_attachBar(); });
}

#pragma mark - Hook

static void (*orig_appDidFinishLaunching)(id, SEL, id) = NULL;

static void hooked_appDidFinishLaunching(id self, SEL _cmd, id arg1) {
    orig_appDidFinishLaunching(self, _cmd, arg1);
    an_attachOnMain();
}

static void __attribute__((constructor)) an_init(void) {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (![bundleID isEqualToString:@"com.apple.springboard"]) return;

        Class sbClass = objc_getClass("SpringBoard");
        if (sbClass) {
            SEL sel = @selector(applicationDidFinishLaunching:);
            Method m = class_getInstanceMethod(sbClass, sel);
            if (m) {
                orig_appDidFinishLaunching = (void (*)(id, SEL, id))method_getImplementation(m);
                method_setImplementation(m, (IMP)hooked_appDidFinishLaunching);
            }
        }

        // Fallback: tweak loaded after launch, or hook point missing.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ an_attachBar(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ an_attachBar(); });
    }
}
