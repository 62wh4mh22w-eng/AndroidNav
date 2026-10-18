// AndroidNav — Android-style virtual navigation bar for iOS 15/16 SpringBoard
// v0.3.0: robust actions using multiple private-API fallbacks.
//   Home     -> SBUIController / SBHomeHardwareButton / SBMainWorkspace ...
//   Recents  -> SBMainSwitcherViewController / SBWorkspace ...
//   Back     -> best-effort: goBack action, nav pop, modal dismiss, keyboard dismiss
// Pure Objective-C, no Theos/Logos/Substrate headers required.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - Globals

static UIWindow *gNavWindow = nil;
static UIView *gNavBar = nil;
static CGFloat gBarHeight = 54.0;
#define ANDROIDNAV_DIAG 1

#pragma mark - Runtime helpers

static id an_call_class(const char *clsName, const char *selName) {
    Class c = objc_getClass(clsName);
    if (!c) return nil;
    SEL s = sel_registerName(selName);
    if (![c respondsToSelector:s]) return nil;
    IMP imp = [c methodForSelector:s];
    if (!imp) return nil;
    return ((id (*)(id, SEL))imp)(c, s);
}

static BOOL an_send(id obj, const char *selName) {
    if (!obj) return NO;
    SEL s = sel_registerName(selName);
    if (![obj respondsToSelector:s]) return NO;
    IMP imp = [obj methodForSelector:s];
    if (!imp) return NO;
    ((void (*)(id, SEL))imp)(obj, s);
    return YES;
}

#pragma mark - Actions

// ---- HOME ----
static BOOL an_goHome(void) {
    // 1) SBUIController (classic, still present on iOS 15/16)
    id uic = an_call_class("SBUIController", "sharedInstance");
    if (an_send(uic, "handleHomeButtonPress")) return YES;
    if (an_send(uic, "handleHomeButtonSinglePressUp")) return YES;
    if (an_send(uic, "clickedMenuButton")) return YES;

    // 2) SBHomeHardwareButton / _SBHomeHardwareButton
    const char *hbClasses[] = {
        "SBHomeHardwareButton", "_SBHomeHardwareButton",
        "SBHomeHardwareButtonGestureRecognizer", NULL
    };
    for (int i = 0; hbClasses[i]; i++) {
        Class c = objc_getClass(hbClasses[i]);
        if (!c) continue;
        id inst = nil;
        if ([c respondsToSelector:@selector(sharedInstance)])
            inst = ((id (*)(id, SEL))[c methodForSelector:@selector(sharedInstance)])(c, @selector(sharedInstance));
        if (!inst && [c respondsToSelector:@selector(sharedInstanceIfExists)])
            inst = ((id (*)(id, SEL))[c methodForSelector:@selector(sharedInstanceIfExists)])(c, @selector(sharedInstanceIfExists));
        if (inst && (an_send(inst, "handleButtonDown") || an_send(inst, "handleButtonUp") ||
                     an_send(inst, "performActionsForButtonDown") || an_send(inst, "singlePressUp")))
            return YES;
    }

    // 3) SBMainWorkspace
    id workspace = an_call_class("SBMainWorkspace", "sharedInstance");
    if (an_send(workspace, "handleHomeButtonPress")) return YES;

    return NO;
}

// ---- RECENTS (app switcher) ----
static BOOL an_openRecents(void) {
    // 1) SBMainSwitcherViewController
    id switcher = an_call_class("SBMainSwitcherViewController", "sharedInstance");
    if (!switcher) switcher = an_call_class("SBMainSwitcherViewController", "sharedInstanceIfExists");
    if (an_send(switcher, "toggleSwitcher")) return YES;
    if (an_send(switcher, "beginPresentationOrDismissalIfNecessary")) return YES;
    if (an_send(switcher, "presentSwitcher")) return YES;

    // 2) SBWorkspace / SBMainWorkspace transitions
    id workspace = an_call_class("SBMainWorkspace", "sharedInstance");
    if (an_send(workspace, "toggleSwitcher")) return YES;
    if (an_send(workspace, "showAppSwitcher")) return YES;

    // 3) SBUIController fallback
    id uic = an_call_class("SBUIController", "sharedInstance");
    if (an_send(uic, "toggleSwitcher")) return YES;
    if (an_send(uic, "handleSwitcherButtonPress")) return YES;

    return NO;
}

// ---- BACK ----
static BOOL an_goBack(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return NO;

    // 1) High-level goBack action (works in many system apps)
    if ([app respondsToSelector:NSSelectorFromString(@"sendAction:to:from:forEvent:")]) {
        [app sendAction:NSSelectorFromString(@"goBack") to:nil from:nil forEvent:nil];
    }

    UIWindow *keyWindow = nil;
    for (UIWindow *w in [app windows]) {
        if ([w isKeyWindow]) { keyWindow = w; break; }
    }
    if (!keyWindow && [app windows].count) keyWindow = [app windows][0];

    UIViewController *root = nil;
    if (keyWindow && [keyWindow respondsToSelector:@selector(rootViewController)])
        root = [keyWindow rootViewController];

    // 2) Dismiss any presented view controller (modal / alert / sheet)
    UIViewController *top = root;
    while (top.presentedViewController) top = top.presentedViewController;
    if (top && top != root) {
        [top dismissViewControllerAnimated:YES completion:nil];
        return YES;
    }

    // 3) Pop navigation stack (all levels)
    if ([root isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)root;
        if (nav.viewControllers.count > 1) {
            [nav popViewControllerAnimated:YES];
            return YES;
        }
    }
    // search for nav controller in presented stack
    if ([top isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)top;
        if (nav.viewControllers.count > 1) { [nav popViewControllerAnimated:YES]; return YES; }
    }

    // 4) Dismiss the keyboard
    [keyWindow endEditing:YES];

    // 5) SpringBoard-level back: SBBackButton / SBGesture
    id sbBack = an_call_class("SBBackButton", "sharedInstance");
    if (an_send(sbBack, "performBack")) return YES;

    return NO;
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

- (void)an_haptic {
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [gen prepare];
        [gen impactOccurred];
    }
}

- (void)an_flash:(UIButton *)b color:(UIColor *)c {
    UIColor *orig = b.backgroundColor;
    b.backgroundColor = c;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ b.backgroundColor = orig; });
}

- (void)an_backTapped:(UIButton *)sender {
    [self an_haptic];
    [self an_flash:sender color:[UIColor colorWithWhite:1 alpha:0.55]];
    BOOL ok = an_goBack();
    NSLog(@"[AndroidNav] TAP back -> %@", ok ? @"OK" : @"NO-OP");
}

- (void)an_homeTapped:(UIButton *)sender {
    [self an_haptic];
    [self an_flash:sender color:[UIColor colorWithWhite:1 alpha:0.55]];
    BOOL ok = an_goHome();
    NSLog(@"[AndroidNav] TAP home -> %@", ok ? @"OK" : @"NO-OP");
}

- (void)an_recentsTapped:(UIButton *)sender {
    [self an_haptic];
    [self an_flash:sender color:[UIColor colorWithWhite:1 alpha:0.55]];
    BOOL ok = an_openRecents();
    NSLog(@"[AndroidNav] TAP recents -> %@", ok ? @"OK" : @"NO-OP");
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    NSLog(@"[AndroidNav] hitTest point=(%.0f,%.0f) -> %@", point.x, point.y,
          v ? NSStringFromClass([v class]) : @"nil");
    return v;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    NSLog(@"[AndroidNav] touchesBegan on bar (%lu touches)", (unsigned long)touches.count);
    [super touchesBegan:touches withEvent:event];
}

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

static void an_attachBar(void) {
    if (![NSThread isMainThread]) return;
    if (gNavWindow && gNavBar.superview == gNavWindow) return;

    CGRect screen = [[UIScreen mainScreen] bounds];

    if (!gNavWindow) {
        // iOS 13+: attach to the foreground-active window scene so touches work
        UIWindowScene *scene = nil;
        for (UIScene *sc in [[UIApplication sharedApplication] connectedScenes]) {
            if ([sc isKindOfClass:[UIWindowScene class]] &&
                sc.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)sc; break;
            }
        }
        if (!scene) {
            for (UIScene *sc in [[UIApplication sharedApplication] connectedScenes]) {
                if ([sc isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)sc; break; }
            }
        }
        if (scene) {
            if (@available(iOS 13.0, *)) {
                gNavWindow = [[UIWindow alloc] initWithWindowScene:scene];
                gNavWindow.frame = screen;
            }
        }
        if (!gNavWindow) gNavWindow = [[UIWindow alloc] initWithFrame:screen];
        // Above status bar / alerts, below system alerts
        gNavWindow.windowLevel = UIWindowLevelStatusBar + 100.0;
        gNavWindow.backgroundColor = [UIColor clearColor];
        gNavWindow.hidden = NO;
        gNavWindow.userInteractionEnabled = YES;

        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor clearColor];
        vc.view.userInteractionEnabled = YES;
        gNavWindow.rootViewController = vc;
    }

    if (!gNavBar) {
        CGRect frame = CGRectMake(0, screen.size.height - gBarHeight, screen.size.width, gBarHeight);
        gNavBar = [[ANavBarView alloc] initWithFrame:frame];
    }

    UIViewController *vc = gNavWindow.rootViewController;
    gNavBar.frame = CGRectMake(0, vc.view.bounds.size.height - gBarHeight,
                               vc.view.bounds.size.width, gBarHeight);
    gNavBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;

    if (gNavBar.superview != vc.view) {
        [gNavBar removeFromSuperview];
        [vc.view addSubview:gNavBar];
    }

    gNavWindow.hidden = NO;
    [gNavWindow makeKeyAndVisible];
    // keep key window sane: makeKeyAndVisible steals key status; restore after
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *best = nil; CGFloat bestArea = 0;
        for (UIWindow *w in [[UIApplication sharedApplication] windows]) {
            if (w == gNavWindow) continue;
            CGFloat a = w.bounds.size.width * w.bounds.size.height;
            if (a > bestArea) { bestArea = a; best = w; }
        }
        if (best) [best makeKeyWindow];
    });
    NSLog(@"[AndroidNav] bar attached as its own window (level=%.0f)", gNavWindow.windowLevel);
}

#pragma mark - Hook

static void (*orig_appDidFinishLaunching)(id, SEL, id) = NULL;

static void hooked_appDidFinishLaunching(id self, SEL _cmd, id arg1) {
    orig_appDidFinishLaunching(self, _cmd, arg1);
    dispatch_async(dispatch_get_main_queue(), ^{ an_attachBar(); });
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

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ an_attachBar(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ an_attachBar(); });
    }
}