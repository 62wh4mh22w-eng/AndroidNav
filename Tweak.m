// AndroidNav — Android-style virtual navigation bar for iOS 15/16 SpringBoard
// v0.5.0: touch pass-through window + IOHIDEvent hardware-key simulation
//         (most reliable way to trigger Home / App Switcher on iOS 16)

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

#pragma mark - Hardware key simulation (IOHIDEvent)

// Types from IOHIDEvent / SpringBoardServices
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

static IOHIDEventRef (*s_createKbEvent)(CFAllocatorRef, uint32_t, uint32_t, uint32_t, uint32_t, int32_t);
static void (*s_sendEvent)(IOHIDEventSystemClientRef, IOHIDEventRef, int);
static IOHIDEventSystemClientRef (*s_clientCreate)(CFAllocatorRef);
static void (*s_setDispatch)(IOHIDEventSystemClientRef, dispatch_queue_t);
static void (*s_setService)(IOHIDEventSystemClientRef, uint32_t);

static void an_load_hid(void) {
    if (s_createKbEvent) return;
    void *h = dlopen("/usr/lib/libIOHID.dylib", RTLD_NOW);
    if (!h) h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!h) return;
    s_createKbEvent = dlsym(h, "IOHIDEventCreateKeyboardEvent");
    s_sendEvent = dlsym(h, "IOHIDEventSystemClientDispatchEvent");
    s_clientCreate = dlsym(h, "IOHIDEventSystemClientCreate");
    s_setDispatch = dlsym(h, "IOHIDEventSystemClientSetDispatchQueue");
    s_setService = dlsym(h, "IOHIDEventSystemClientSetService");
}

static void an_post_key(uint32_t usage) {
    an_load_hid();
    if (!s_createKbEvent || !s_sendEvent || !s_clientCreate) {
        NSLog(@"[AndroidNav] IOHID unavailable");
        return;
    }
    static IOHIDEventSystemClientRef client = NULL;
    if (!client) {
        client = s_clientCreate(kCFAllocatorDefault);
        if (s_setDispatch) s_setDispatch(client, dispatch_get_main_queue());
        if (s_setService) s_setService(client, 1); // kIOHIDEventSystemClientServiceTypeAppleVendor
    }
    IOHIDEventRef down = s_createKbEvent(kCFAllocatorDefault, 0, usage, 1, 0, 0);
    IOHIDEventRef up = s_createKbEvent(kCFAllocatorDefault, 0, usage, 0, 0, 0);
    if (down) { s_sendEvent(client, down, 0); CFRelease(down); }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (up) { s_sendEvent(client, up, 0); CFRelease(up); }
    });
    NSLog(@"[AndroidNav] posted HID usage 0x%X", usage);
}

// HID usage codes
#define HID_USAGE_HOME      0x40  // Keyboard Home
#define HID_USAGE_APP_SWITCH 0x68 // Keyboard power/power key variant used by springboard

#pragma mark - Actions

static BOOL an_goHome(void) {
    // 1) Hardware Home key via IOHID (most reliable)
    an_post_key(HID_USAGE_HOME);

    // 2) Private API fallbacks
    id uic = an_call_class("SBUIController", "sharedInstance");
    if (an_send(uic, "handleHomeButtonPress")) return YES;
    if (an_send(uic, "handleHomeButtonSinglePressUp")) return YES;

    id workspace = an_call_class("SBMainWorkspace", "sharedInstance");
    if (an_send(workspace, "handleHomeButtonPress")) return YES;

    return NO;
}

static BOOL an_openRecents(void) {
    // 1) Two rapid Home presses = app switcher gesture
    an_post_key(HID_USAGE_HOME);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ an_post_key(HID_USAGE_HOME); });

    // 2) Direct switcher APIs
    id switcher = an_call_class("SBMainSwitcherViewController", "sharedInstance");
    if (!switcher) switcher = an_call_class("SBMainSwitcherViewController", "sharedInstanceIfExists");
    if (an_send(switcher, "toggleSwitcher")) return YES;
    if (an_send(switcher, "presentSwitcher")) return YES;

    return NO;
}

static BOOL an_goBack(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return NO;

    [app sendAction:NSSelectorFromString(@"goBack") to:nil from:nil forEvent:nil];

    UIWindow *keyWindow = nil;
    for (UIWindow *w in [app windows]) {
        if ([w isKeyWindow]) { keyWindow = w; break; }
    }
    if (!keyWindow && [app windows].count) keyWindow = [app windows][0];

    UIViewController *root = nil;
    if (keyWindow && [keyWindow respondsToSelector:@selector(rootViewController)])
        root = [keyWindow rootViewController];

    UIViewController *top = root;
    while (top.presentedViewController) top = top.presentedViewController;
    if (top && top != root) {
        [top dismissViewControllerAnimated:YES completion:nil];
        return YES;
    }

    if ([root isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)root;
        if (nav.viewControllers.count > 1) {
            [nav popViewControllerAnimated:YES];
            return YES;
        }
    }
    if ([top isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)top;
        if (nav.viewControllers.count > 1) { [nav popViewControllerAnimated:YES]; return YES; }
    }

    [keyWindow endEditing:YES];

    // Hardware Back isn't standard on iOS; simulate the "swipe back" fallback
    // by sending Escape which many apps handle
    an_post_key(0x29);
    return YES;
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
        // Fire on touch-down for immediate response (Android-like)
        SEL sel = i == 0 ? @selector(an_backTapped:) : (i == 1 ? @selector(an_homeTapped:) : @selector(an_recentsTapped:));
        [btn addTarget:self action:sel forControlEvents:UIControlEventTouchDown];
        [self addSubview:btn];
    }
}

- (void)an_flash:(UIButton *)b color:(UIColor *)c {
    UIColor *orig = b.backgroundColor;
    b.backgroundColor = c;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ b.backgroundColor = orig; });
}

- (void)an_backTapped:(UIButton *)b {
    [self an_flash:b color:[UIColor colorWithWhite:1 alpha:0.6]];
    an_goBack();
}

- (void)an_homeTapped:(UIButton *)b {
    [self an_flash:b color:[UIColor colorWithWhite:1 alpha:0.6]];
    an_goHome();
}

- (void)an_recentsTapped:(UIButton *)b {
    [self an_flash:b color:[UIColor colorWithWhite:1 alpha:0.6]];
    an_openRecents();
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

#pragma mark - Root controller (touch pass-through)

// The root view only accepts touches inside the nav bar rect. Returning nil
// from hitTest lets SpringBoard's own windows get every other touch.
@interface ANavRootVC : UIViewController
@end

@implementation ANavRootVC

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.view.backgroundColor = [UIColor clearColor];
    self.view.userInteractionEnabled = YES;
}

- (UIView *)hitTestForPoint:(CGPoint)pt withEvent:(UIEvent *)e {
    if (!gNavBar) return nil;
    if (CGRectContainsPoint(gNavBar.frame, pt)) return [gNavBar hitTest:pt withEvent:e];
    return nil;
}

@end

// Custom window: overrides hitTest so only the bar area swallows touches.
@interface ANavWindow : UIWindow
@property (nonatomic, weak) ANavRootVC *navVC;
@end

@implementation ANavWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!gNavBar) return nil;
    if (CGRectContainsPoint(gNavBar.frame, point)) {
        UIView *v = [gNavBar hitTest:point withEvent:event];
        return v;
    }
    return nil; // pass everything else to SpringBoard below
}

@end

#pragma mark - Attach logic

static void an_attachBar(void) {
    if (![NSThread isMainThread]) return;
    if (gNavWindow && gNavBar && gNavBar.superview) return;

    CGRect screen = [[UIScreen mainScreen] bounds];

    if (!gNavWindow) {
        UIWindowScene *scene = nil;
        for (UIScene *sc in [[UIApplication sharedApplication] connectedScenes]) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            if (sc.activationState == UISceneActivationStateForegroundActive) { scene = (UIWindowScene *)sc; break; }
        }
        if (!scene) {
            for (UIScene *sc in [[UIApplication sharedApplication] connectedScenes]) {
                if ([sc isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)sc; break; }
            }
        }
        if (scene) {
            if (@available(iOS 13.0, *)) {
                gNavWindow = [[ANavWindow alloc] initWithWindowScene:scene];
                gNavWindow.frame = screen;
            }
        }
        if (!gNavWindow) gNavWindow = [[ANavWindow alloc] initWithFrame:screen];

        gNavWindow.windowLevel = UIWindowLevelStatusBar + 100.0;
        gNavWindow.backgroundColor = [UIColor clearColor];
        gNavWindow.userInteractionEnabled = YES;
        ((ANavWindow *)gNavWindow).navVC = [[ANavRootVC alloc] init];
        gNavWindow.rootViewController = ((ANavWindow *)gNavWindow).navVC;
        gNavWindow.hidden = NO;
        // NOTE: never call makeKeyAndVisible — that steals every touch.
    }

    if (!gNavBar) {
        CGRect frame = CGRectMake(0, screen.size.height - gBarHeight, screen.size.width, gBarHeight);
        gNavBar = [[ANavBarView alloc] initWithFrame:frame];
    }

    gNavBar.frame = CGRectMake(0, screen.size.height - gBarHeight, screen.size.width, gBarHeight);
    gNavBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;

    UIView *host = gNavWindow.rootViewController.view;
    if (gNavBar.superview != host) {
        [gNavBar removeFromSuperview];
        [host addSubview:gNavBar];
    }
    gNavWindow.hidden = NO;
    NSLog(@"[AndroidNav] bar attached, level=%.0f", gNavWindow.windowLevel);
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
