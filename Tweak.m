// AndroidNav — Android-style virtual navigation bar for iOS 15/16 SpringBoard
// v0.5.0: touch pass-through window + IOHIDEvent hardware-key simulation
//         (most reliable way to trigger Home / App Switcher on iOS 16)

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

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

#pragma mark - Class / selector discovery

static int an_count_classes(void) {
    int n = 0;
    unsigned int count = 0;
    objc_copyClassNamesForImage ? (void)0 : (void)0;
    Class *list = objc_copyClassList(&count);
    if (list) n = (int)count;
    free(list);
    return n;
}

// List class names in this process matching any of the keywords
static NSString *an_scan_classes(NSArray<NSString *> *keywords) {
    unsigned int count = 0;
    Class *list = objc_copyClassList(&count);
    NSMutableArray *hits = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        const char *nm = class_getName(list[i]);
        if (!nm) continue;
        NSString *name = [NSString stringWithUTF8String:nm];
        for (NSString *k in keywords) {
            if ([name rangeOfString:k].location != NSNotFound) {
                [hits addObject:name];
                break;
            }
        }
    }
    free(list);
    return [hits componentsJoinedByString:@","];
}

static NSString *an_scan_methods(const char *clsName, NSArray<NSString *> *keywords) {
    Class c = objc_getClass(clsName);
    if (!c) return [NSString stringWithFormat:@"(no class %s)", clsName];
    unsigned int count = 0;
    Method *ms = class_copyMethodList(object_getClass(c), &count); // class methods
    NSMutableArray *hits = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        NSString *n = NSStringFromSelector(method_getName(ms[i]));
        for (NSString *k in keywords) {
            if ([n rangeOfString:k].location != NSNotFound) { [hits addObject:[@"+" stringByAppendingString:n]]; break; }
        }
    }
    free(ms);
    Class meta = object_getClass(c);
    (void)meta;

    count = 0;
    ms = class_copyMethodList(c, &count);
    for (unsigned int i = 0; i < count; i++) {
        NSString *n = NSStringFromSelector(method_getName(ms[i]));
        for (NSString *k in keywords) {
            if ([n rangeOfString:k].location != NSNotFound) { [hits addObject:[@"-" stringByAppendingString:n]]; break; }
        }
    }
    free(ms);
    return [hits componentsJoinedByString:@" "];
}

#pragma mark - Instance discovery

// Walk every live object of a class via the ObjC runtime's reference tables.
static BOOL an_is_live_object(id obj, const char *clsName) {
    if (!obj) return NO;
    Class c = objc_getClass(clsName);
    return c ? [obj isKindOfClass:c] : NO;
}

// SBHomeHardwareButton is not a singleton -> find live instances by scanning
// the class's weak/strong reference tables through _objc_debug helpers is not
// public, so instead we hook object creation earlier. Simpler approach used
// here: ask the responder chain / UIApplication for known owners.
static id an_find_home_hardware_button(void) {
    // Try common owners in order
    const char *owners[] = {
        "SBHardwareButtonManager", "SBHomeHardwareButtonActions",
        "SBHardwareButtonService", "SBSystemGestureManager",
        "SBHomeGestureManager", "SBMainController", NULL
    };
    for (int i = 0; owners[i]; i++) {
        Class c = objc_getClass(owners[i]);
        if (!c) continue;
        id inst = nil;
        if ([c respondsToSelector:NSSelectorFromString(@"sharedInstance")])
            inst = ((id (*)(id, SEL))[c methodForSelector:NSSelectorFromString(@"sharedInstance")])(c, NSSelectorFromString(@"sharedInstance"));
        if (inst) return inst;
    }
    return nil;
}

// List all classes with "HardwareButton" in the name
static NSString *an_button_classes(void) {
    unsigned int count = 0;
    Class *list = objc_copyClassList(&count);
    NSMutableArray *hits = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        const char *nm = class_getName(list[i]);
        if (!nm) continue;
        NSString *n = [NSString stringWithUTF8String:nm];
        if ([n rangeOfString:@"HardwareButton"].location != NSNotFound &&
            [n hasPrefix:@"SB"])
            [hits addObject:n];
    }
    free(list);
    return [hits componentsJoinedByString:@"\n"];
}

#pragma mark - Actions

static BOOL an_dbg(const char *what, BOOL ok) {
    NSLog(@"[AndroidNav] %s -> %@", what, ok ? @"OK" : @"NO");
    return ok;
}

// Call a class method returning id, with one id argument
static id an_cls_call1(const char *cls, const char *sel, id a1) {
    Class c = objc_getClass(cls);
    if (!c) return nil;
    SEL s = sel_registerName(sel);
    if (![c respondsToSelector:s]) return nil;
    id (*f)(id, SEL, id) = (id (*)(id, SEL, id))[c methodForSelector:s];
    return f((id)c, s, a1);
}

// ---- HOME ----
// Strategy A: SBUIController (works on many iOS 15/16 jailbreaks)
// Strategy B: SBHomeHardwareButtonActions via SBHomeHardwareButton
// Strategy C: ask SpringBoard to go to home screen through SBWorkspace
static BOOL an_goHome(void) {
    // A
    id uic = an_call_class("SBUIController", "sharedInstance");
    if (an_send(uic, "handleHomeButtonPress")) return an_dbg("home/UIController", YES);
    if (an_send(uic, "handleHomeButtonSinglePressUp")) return an_dbg("home/UIController-up", YES);

    // B: SBHomeHardwareButtonActions
    id hb = an_call_class("SBHomeHardwareButton", "sharedInstance");
    if (!hb) hb = an_call_class("_SBHomeHardwareButton", "sharedInstance");
    if (hb) {
        if (an_send(hb, "performSinglePressAction")) return an_dbg("home/HW-actions", YES);
        if (an_send(hb, "handleButtonDown")) return an_dbg("home/HW-down", YES);
        if (an_send(hb, "handleButtonUp")) return an_dbg("home/HW-up", YES);
    }

    // C: SBMainWorkspace
    id ws = an_call_class("SBMainWorkspace", "sharedInstance");
    if (an_send(ws, "handleHomeButtonPress")) return an_dbg("home/workspace", YES);

    // D: SBApplicationController — dismiss foreground app
    id appCtrl = an_call_class("SBApplicationController", "sharedInstance");
    if (an_send(appCtrl, "handleHomeButtonPress")) return an_dbg("home/appctrl", YES);

    // E: last resort — IOHID (no-op in many jailbreaks but harmless)
    an_post_key(HID_USAGE_HOME);
    return an_dbg("home/IOHID-only", NO);
}

// ---- RECENTS ----
static BOOL an_openRecents(void) {
    // A: SBMainSwitcherViewController
    id sw = an_call_class("SBMainSwitcherViewController", "sharedInstance");
    if (!sw) sw = an_call_class("SBMainSwitcherViewController", "sharedInstanceIfExists");
    if (an_send(sw, "toggleSwitcher")) return an_dbg("recents/switcher", YES);
    if (an_send(sw, "presentSwitcher")) return an_dbg("recents/present", YES);
    if (an_send(sw, "beginPresentationOrDismissalIfNecessary")) return an_dbg("recents/begin", YES);

    // B: SBAppSwitcherController
    id asc = an_call_class("SBAppSwitcherController", "sharedInstance");
    if (an_send(asc, "handleSwitcherButtonPress")) return an_dbg("recents/ASC", YES);
    if (an_send(asc, "toggleSwitcher")) return an_dbg("recents/ASC-toggle", YES);

    // C: SBUIController
    id uic = an_call_class("SBUIController", "sharedInstance");
    if (an_send(uic, "toggleSwitcher")) return an_dbg("recents/UIC", YES);
    if (an_send(uic, "handleSwitcherButtonPress")) return an_dbg("recents/UIC-btn", YES);
    if (an_send(uic, "clickedMenuButton")) return an_dbg("recents/UIC-menu", YES);

    // D: SBMainWorkspace
    id ws = an_call_class("SBMainWorkspace", "sharedInstance");
    if (an_send(ws, "toggleSwitcher")) return an_dbg("recents/workspace", YES);

    an_post_key(HID_USAGE_HOME);
    return an_dbg("recents/IOHID-only", NO);
}

// ---- BACK ----
// Global back isn't an iOS concept; do the best generic thing:
// 1) send the goBack action (App-level)
// 2) dismiss modals / pop nav stacks in the frontmost app window
// 3) ask SpringBoard's app-return stack to step back
static BOOL an_goBack(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return NO;

    [app sendAction:NSSelectorFromString(@"goBack") to:nil from:nil forEvent:nil];

    UIWindow *keyWindow = nil;
    CGFloat bestArea = 0;
    for (UIWindow *w in [app windows]) {
        if (w.hidden) continue;
        CGFloat a = w.bounds.size.width * w.bounds.size.height;
        if (a > bestArea) { bestArea = a; keyWindow = w; }
    }

    UIViewController *root = nil;
    if (keyWindow && [keyWindow respondsToSelector:@selector(rootViewController)])
        root = [keyWindow rootViewController];

    UIViewController *top = root;
    while (top.presentedViewController) top = top.presentedViewController;
    if (top && top != root) {
        [top dismissViewControllerAnimated:YES completion:nil];
        return an_dbg("back/dismiss", YES);
    }

    for (UIViewController *vc in @[top ?: [NSNull null], root ?: [NSNull null]]) {
        if (![vc isKindOfClass:[UINavigationController class]]) continue;
        UINavigationController *nav = (UINavigationController *)vc;
        if (nav.viewControllers.count > 1) {
            [nav popViewControllerAnimated:YES];
            return an_dbg("back/pop", YES);
        }
    }

    if ([top isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tb = (UITabBarController *)top;
        if (tb.selectedIndex > 0) { tb.selectedIndex -= 1; return an_dbg("back/tab", YES); }
    }

    [keyWindow endEditing:YES];
    an_post_key(0x29); // Escape
    return an_dbg("back/escape", NO);
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
        [btn addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:btn];
    }
    // small status label at the far right to show action results on screen
    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(w - 110, 2, 108, h - 4)];
    lbl.tag = 999;
    lbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    lbl.textColor = [UIColor yellowColor];
    lbl.textAlignment = NSTextAlignmentRight;
    lbl.backgroundColor = [UIColor clearColor];
    lbl.userInteractionEnabled = NO;
    [self addSubview:lbl];
}

- (void)an_status:(NSString *)msg {
    UILabel *lbl = [self viewWithTag:999];
    if (!lbl) return;
    lbl.text = msg;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ lbl.text = @""; });
}

- (void)an_flash:(UIButton *)b color:(UIColor *)c {
    UIColor *orig = b.backgroundColor;
    b.backgroundColor = c;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ b.backgroundColor = orig; });
}

- (void)an_backTapped:(UIButton *)b {
    [self an_flash:b color:[UIColor colorWithWhite:1 alpha:0.6]];
    NSString *r = an_goBack() ? @"back OK" : @"back FAIL";
    [self an_status:r];
    NSLog(@"[AndroidNav] TAP %@", r);
}

- (void)an_homeTapped:(UIButton *)b {
    [self an_flash:b color:[UIColor colorWithWhite:1 alpha:0.6]];
    NSString *r = an_goHome() ? @"home OK" : @"home FAIL";
    [self an_status:r];
    NSLog(@"[AndroidNav] TAP %@", r);
}

- (void)an_recentsTapped:(UIButton *)b {
    [self an_flash:b color:[UIColor colorWithWhite:1 alpha:0.6]];

    NSMutableArray *log = [NSMutableArray array];

    // Full method dump (no filtering) for the classes that matter
    NSString *svcAll = an_scan_methods("SBHardwareButtonService", @[]);
    NSString *actAll = an_scan_methods("SBHomeHardwareButtonActions", @[]);
    NSString *lockAll = an_scan_methods("SBLockHardwareButtonActions", @[]);
    NSString *wsAll = an_scan_methods("SBMainWorkspace", @[@"ome", @"witch", @"ctuat"]);

    [log addObject:[NSString stringWithFormat:@"SVC: %lu chars", (unsigned long)svcAll.length]];
    [log addObject:[NSString stringWithFormat:@"ACT: %lu chars", (unsigned long)actAll.length]];

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(0, 80, self.window.bounds.size.width, 580)];
    panel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.96];
    panel.layer.cornerRadius = 10;
    [self.window addSubview:panel];

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(8, 8, panel.bounds.size.width - 16, panel.bounds.size.height - 16)];
    tv.backgroundColor = [UIColor clearColor];
    tv.textColor = [UIColor greenColor];
    tv.font = [UIFont fontWithName:@"Menlo" size:9.5];
    tv.editable = NO;
    tv.text = [NSString stringWithFormat:
        @"=== SBHardwareButtonService ===\n%@\n\n=== SBHomeHardwareButtonActions ===\n%@\n\n=== SBMainWorkspace(home/sw) ===\n%@\n\n=== SBLockHardwareButtonActions ===\n%@\n\n(点关闭)",
        svcAll.length ? svcAll : @"(empty)", actAll.length ? actAll : @"(empty)",
        wsAll.length ? wsAll : @"(empty)", lockAll.length ? lockAll : @"(empty)"];
    [panel addSubview:tv];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(an_closePanel:)];
    [panel addGestureRecognizer:tap];
}

- (void)an_closePanel:(UITapGestureRecognizer *)g {
    [[g view] removeFromSuperview];
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

#pragma mark - Touch pass-through window

// Window that only swallows touches inside the nav bar rect.
@interface ANavWindow : UIWindow
@end

@implementation ANavWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!gNavBar) return nil;
    CGRect f = gNavBar.frame;
    if (CGRectContainsPoint(f, point)) {
        CGPoint local = [gNavBar convertPoint:point fromView:self];
        return [gNavBar hitTest:local withEvent:event];
    }
    return nil; // everything else goes to SpringBoard
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
            }
        }
        if (!gNavWindow) gNavWindow = [[ANavWindow alloc] initWithFrame:screen];

        gNavWindow.frame = screen;
        gNavWindow.windowLevel = UIWindowLevelStatusBar + 100.0;
        gNavWindow.backgroundColor = [UIColor clearColor];
        gNavWindow.userInteractionEnabled = YES;
        gNavWindow.rootViewController = [[UIViewController alloc] init];
        gNavWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
        gNavWindow.hidden = NO;
        // never makeKeyAndVisible — it steals all touches
    }

    // Bar sits in window coordinates, bottom of screen.
    if (!gNavBar) {
        CGRect frame = CGRectMake(0, screen.size.height - gBarHeight, screen.size.width, gBarHeight);
        gNavBar = [[ANavBarView alloc] initWithFrame:frame];
    }
    gNavBar.frame = CGRectMake(0, screen.size.height - gBarHeight, screen.size.width, gBarHeight);
    gNavBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;

    if (gNavBar.superview != gNavWindow) {
        [gNavBar removeFromSuperview];
        [gNavWindow addSubview:gNavBar];
    }
    gNavWindow.hidden = NO;
    [gNavWindow bringSubviewToFront:gNavBar];
    NSLog(@"[AndroidNav] bar attached frame=%@", NSStringFromCGRect(gNavBar.frame));
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
