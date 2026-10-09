#import <Foundation/Foundation.h>

// This fork is used in Chinese. Set before Foundation reads the preferred language,
// so menus and panels are Chinese even when the Mac is not.
__attribute__((constructor))
static void CompositorPreferChinese(void) {
    [[NSUserDefaults standardUserDefaults] setObject:@[@"zh-Hans"] forKey:@"AppleLanguages"];
}
