#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include "RuntimeLoader.h"

static enum MadeiraRuntime activeRuntime;
static NSString *startupFailure;
static void *runtimeHandle;

static NSURL *documentsFile(NSString *name) {
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                          inDomains:NSUserDomainMask].firstObject;
    return [documents URLByAppendingPathComponent:name];
}

static BOOL saveChoice(enum MadeiraRuntime choice) {
    NSError *error = nil;
    BOOL written = [@(madeira_runtime_name(choice)) writeToURL:documentsFile(@"madeira-runtime.txt")
                                                 atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (!written) NSLog(@"[runtime] Could not save choice: %@", error);
    return written;
}

/* Original Madeira ignores new Codable fields when saving the library. Keep
 * only QoL-owned fields in a sidecar, matched by ID, without restoring removed
 * games or overwriting shared settings changed in the original interface. */
static void preserveQoLProfiles(void) {
    NSURL *file = documentsFile(@"madeira-library.json");
    NSURL *sidecar = documentsFile(@"madeira-qol-profiles.json");
    NSData *data = [NSData dataWithContentsOfURL:file];
    if (!data) return;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if (![parsed isKindOfClass:NSDictionary.class] || ![parsed[@"version"] isEqual:@1] ||
        ![parsed[@"entries"] isKindOfClass:NSArray.class]) return;
    NSMutableDictionary *library = parsed;
    NSData *saved = [NSData dataWithContentsOfURL:sidecar];
    id decoded = saved ? [NSJSONSerialization JSONObjectWithData:saved options:NSJSONReadingMutableContainers error:nil] : nil;
    // Preserve corrupt/unknown sidecars instead of overwriting them.
    if (saved && ![decoded isKindOfClass:NSDictionary.class]) return;
    NSMutableDictionary *profiles = decoded ?: [NSMutableDictionary dictionary];
    NSArray *keys = @[@"performanceUpgrade", @"metadataRevision"];
    NSString *previous = [NSUserDefaults.standardUserDefaults stringForKey:@"madeiraLastLoadedRuntime"];
    BOOL restoring = activeRuntime == MadeiraRuntimeQoL && [previous isEqualToString:@"original"];
    BOOL backingUp = activeRuntime == MadeiraRuntimeOriginal && ![previous isEqualToString:@"original"];
    if (!restoring && !backingUp) return;
    for (id item in library[@"entries"]) {
        if (![item isKindOfClass:NSDictionary.class] || ![item[@"id"] isKindOfClass:NSString.class]) return;
        NSString *identifier = item[@"id"];
        if (backingUp) {
            NSMutableDictionary *profile = [NSMutableDictionary dictionary];
            for (NSString *key in keys) if (item[key]) profile[key] = item[key];
            profiles[identifier] = profile;
        } else {
            id profile = profiles[identifier];
            if (![profile isKindOfClass:NSDictionary.class]) continue;
            for (NSString *key in keys) if (profile[key]) item[key] = profile[key];
        }
    }
    NSError *error = nil;
    NSData *output = [NSJSONSerialization dataWithJSONObject:restoring ? library : profiles options:NSJSONWritingSortedKeys error:&error];
    if (!output || ![output writeToURL:restoring ? file : sidecar options:NSDataWritingAtomic error:&error])
        NSLog(@"[runtime] Could not preserve QoL profiles: %@", error);
}

static UIViewController *presenter(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isKeyWindow || window.hidden) continue;
            UIViewController *controller = window.rootViewController;
            while (controller.presentedViewController) controller = controller.presentedViewController;
            if (controller.view.window && !controller.isBeingDismissed && !controller.isBeingPresented) return controller;
        }
    }
    return nil;
}

static void showRuntimePicker(UIViewController *controller) {
    NSString *name = activeRuntime == MadeiraRuntimeQoL ? @"Madeira-QoL" : @"Original Madeira";
    NSString *message = startupFailure
        ? [NSString stringWithFormat:@"%@ could not load. Select the other runtime, then close Madeira from the app switcher and open it again.\n\n%@", name, startupFailure]
        : [NSString stringWithFormat:@"Active: %@. Turning QoL off uses the original app and runtime. Changing runtime takes effect after you close Madeira from the app switcher and open it again.", name];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Madeira runtime" message:message preferredStyle:UIAlertControllerStyleAlert];
    for (NSNumber *value in @[@(MadeiraRuntimeOriginal), @(MadeiraRuntimeQoL)]) {
        enum MadeiraRuntime choice = value.intValue;
        NSString *label = choice == MadeiraRuntimeQoL ? @"Use Madeira-QoL (On)" : @"Use Original Madeira (Off)";
        [alert addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            BOOL written = saveChoice(choice);
            if (written && choice == activeRuntime && !startupFailure) return;
            UIAlertController *notice = [UIAlertController alertControllerWithTitle:written ? @"Restart Madeira" : @"Could not save runtime"
                message:written ? @"Swipe Madeira away in the app switcher, then open it again. The selected runtime will load at startup." : @"The current runtime is unchanged. Check available storage and try again."
                preferredStyle:UIAlertControllerStyleAlert];
            [notice addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [controller presentViewController:notice animated:YES completion:nil];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleCancel handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

// A cold-start picker also exists in the unmodified original interface, so
// users can always switch back. Never interrupt a running Windows program.
static void schedulePicker(unsigned attempt) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        typedef int (*Running)(void);
        Running running = runtimeHandle ? (Running)dlsym(runtimeHandle, "wine_process_is_running") : NULL;
        if (running && running()) return;
        UIViewController *controller = presenter();
        if (controller && ![controller isKindOfClass:UIAlertController.class]) showRuntimePicker(controller);
        else if (attempt < 15) schedulePicker(attempt + 1);
    });
}

@interface MadeiraRuntimeRecoveryDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation MadeiraRuntimeRecoveryDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{ showRuntimePicker(controller); });
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *saved = [NSString stringWithContentsOfURL:documentsFile(@"madeira-runtime.txt") encoding:NSUTF8StringEncoding error:nil];
        saved = [saved stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        activeRuntime = madeira_runtime_choice(saved.UTF8String);
        setenv("MADEIRA_ACTIVE_RUNTIME", madeira_runtime_name(activeRuntime), 1);
        setenv("MADEIRA_RUNTIME_SELECTOR", "1", 1);
        NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@(madeira_runtime_library(activeRuntime))];
        char error[2048] = {0};
        MadeiraRuntimeMain entry = madeira_runtime_load(path.fileSystemRepresentation, &runtimeHandle, error, sizeof(error));
        if (!entry) {
            startupFailure = @(error);
            NSLog(@"[runtime] Selected library failed: %@", startupFailure);
            return UIApplicationMain(argc, argv, nil, NSStringFromClass(MadeiraRuntimeRecoveryDelegate.class));
        }
        preserveQoLProfiles();
        [NSUserDefaults.standardUserDefaults setObject:@(madeira_runtime_name(activeRuntime)) forKey:@"madeiraLastLoadedRuntime"];
        fprintf(stderr, "[runtime] active=%s library=%s; one runtime loaded\n", madeira_runtime_name(activeRuntime), madeira_runtime_library(activeRuntime));
        __block id observer;
        observer = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            [NSNotificationCenter.defaultCenter removeObserver:observer];
            observer = nil;
            schedulePicker(0);
        }];
        return entry(argc, argv);
    }
}
