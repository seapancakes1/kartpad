// Exercises the actual native settings implementation without game startup,
// Mii-manager code, user-defaults access, device input, or renderer creation.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include "runtime_config.h"
#include <cassert>
#include <cstdint>
static int reloadCalls=0;
static void KartPadRequestSettingsReload(){++reloadCalls;}
static void KartPadRequestControllerCompatibility(){}
static bool KPFullscreenAcrossNotch(){return false;}
// The shell's game window, pad navigation, controller shortcuts and background pause, without
// devices or user defaults.
static NSWindow *KPGameWindow(){return nil;}
static NSInteger KPAuxiliaryWindowLevel(){return NSFloatingWindowLevel;}
static int settingsRegistered=0;
static void KartPadMiiPadSetSettings(NSWindow *,NSTabView *,void (^)(void)){++settingsRegistered;}
static NSString *const kKartPadBackgroundPauseDefaultsKey=@"KartPadPauseInBackground";
static bool KPBackgroundPauseEnabled(){return true;}
enum KPPadShortcutKind { KPPadShortcutMiis, KPPadShortcutSettings, KPPadShortcutCount };
struct KPPadShortcut { __unsafe_unretained NSString *enabledKey,*buttonsKey,*holdKey,*opens; };
static KPPadShortcut KPPadShortcuts[KPPadShortcutCount]={{@"",@"",@"",@"Miis"},{@"",@"",@"",@"Settings"}};
static bool KPPadShortcutEnabled(int kind){return kind==KPPadShortcutSettings;}
static uint64_t KPPadShortcutButtons(int kind){return kind;}
static void KPPadShortcutSetButtons(int,uint64_t){}
static NSTimeInterval KPPadShortcutHold(int kind){return kind==KPPadShortcutSettings?2:1;}
static NSString *KPPadButtonNames(uint64_t buttons){return buttons?@"View + Menu":@"View";}
static NSString *KPPadButtonsWarning(uint64_t){return nil;}
static bool KPPadCapturing(){return false;}
static void KPPadBeginCapture(void (^)(uint64_t)){}
static void KPPadCancelCapture(){}
@interface TestControllers : NSObject <NSWindowDelegate>
@property(nonatomic,strong) NSView *content;
@end
@implementation TestControllers
- (void)cancelCapture{}
- (void)windowWillClose:(NSNotification *)note{(void)note;}
- (void)prepareInPanel:(NSPanel *)panel{(void)panel;self.content=[NSView new];}
- (void)activateInput{}
@end
static TestControllers *KPControllers(){static TestControllers *c=[TestControllers new];return c;}
@interface KartPadMacShellController : NSObject <NSTabViewDelegate>
@property(nonatomic,strong) NSPanel *settingsPanel;
@property(nonatomic,strong) NSTabView *settingsTabs;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSControl *> *settingControls;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSArray *> *settingChoices;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSTextField *> *settingValues;
@property(nonatomic,strong) NSTextField *settingsStatus;
@property(nonatomic,strong) NSArray<NSButton *> *padShortcutSwitches;
@property(nonatomic,strong) NSArray<NSTextField *> *padShortcutButtons;
@property(nonatomic,strong) NSArray<NSButton *> *padShortcutChoose;
@property(nonatomic,strong) NSArray<NSPopUpButton *> *padShortcutHolds;
@property(nonatomic) NSInteger capturingShortcut;
@property(nonatomic,strong) NSButton *backgroundPauseSwitch;
@property(nonatomic,strong) NSButton *settingsRestart;
@property(nonatomic) BOOL restartPending;
@property(nonatomic) int restarts;
@end
@implementation KartPadMacShellController
- (NSTextField *)label:(NSString *)text{return [NSTextField labelWithString:text];}
- (void)setRestartNeeded:(BOOL)needed for:(NSString *)reason{(void)reason;self.restartPending=needed;self.settingsRestart.hidden=!needed;}
- (void)restartKartPad:(id)sender{(void)sender;++self.restarts;}
#include "KartPadMacSettings.inc.mm"
@end
static void select(KartPadMacShellController *c,NSString *key,NSInteger index){
 NSPopUpButton *p=(NSPopUpButton *)c.settingControls[key];[p selectItemAtIndex:index];
 [p sendAction:p.action to:p.target];
}
int main(int argc,char **argv){@autoreleasepool {
 assert(argc==3);
 const auto expected=std::filesystem::canonical(argv[1]);
 assert(RuntimeConfigFile::PortableRootDirectory()==expected);
 assert(RuntimeConfigFile::ApplicationDataDirectory()==expected/"UserData");
 // Laid out and clicked without coming to the front or taking the focus.
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
 method_setImplementation(class_getInstanceMethod(NSApplication.class,@selector(activateIgnoringOtherApps:)),imp_implementationWithBlock(^(id,BOOL){}));
 method_setImplementation(class_getInstanceMethod(NSWindow.class,@selector(makeKeyAndOrderFront:)),imp_implementationWithBlock(^(id,id){}));
 KartPadMacShellController *c=[KartPadMacShellController new];[c showSettings:nil];
 assert(settingsRegistered==1);
 NSButton *vsync=(NSButton *)c.settingControls[@"video.vsync"];
 if(std::string(argv[2])=="reopen"){
  assert(vsync.state==NSControlStateValueOn);assert(c.settingsRestart.hidden);
  [vsync performClick:nil];assert(RuntimeConfigFile::LoadConfigFile().vsync==false);
  assert(reloadCalls==0);[c.settingsPanel close];puts("PASS: native checkbox persisted across process restart");return 0;
 }
 // Game & Data: a row for each controller shortcut, and the background pause.
 assert(c.padShortcutSwitches.count==2);
 assert(c.padShortcutSwitches[0].state==NSControlStateValueOff&&c.padShortcutSwitches[1].state==NSControlStateValueOn);
 assert([c.padShortcutSwitches[1].title containsString:@"Open Settings"]);
 assert([c.padShortcutButtons[1].stringValue isEqual:@"Buttons: View + Menu"]);
 assert(!c.padShortcutChoose[0].enabled&&c.padShortcutChoose[1].enabled);
 assert(c.padShortcutHolds[0].indexOfSelectedItem==1&&c.padShortcutHolds[1].indexOfSelectedItem==2);
 assert(c.backgroundPauseSwitch.state==NSControlStateValueOn);
 // VSync waits for a restart, which Settings then offers.
 assert(vsync.state==NSControlStateValueOff);assert(c.settingsRestart.hidden);
 [vsync performClick:nil];assert(RuntimeConfigFile::LoadConfigFile().vsync==true);
 assert(reloadCalls==0);assert([c.settingsStatus.stringValue containsString:@"when KartPad restarts"]);
 assert(!c.settingsRestart.hidden);[c.settingsRestart performClick:nil];assert(c.restarts==1);
 [c.settingsPanel close];[c showSettings:nil];assert(vsync.state==NSControlStateValueOn);
 select(c,@"video.display_mode",1);assert(RuntimeConfigFile::LoadConfigFile().displayMode=="borderless");
 select(c,@"video.frame_interpolation_fps",1);assert(RuntimeConfigFile::LoadConfigFile().frameInterpolationFps==120);
 NSSlider *volume=(NSSlider *)c.settingControls[@"audio.volume"];volume.doubleValue=35;[volume sendAction:volume.action to:volume.target];
 assert(std::abs(RuntimeConfigFile::LoadConfigFile().audioVolume.value_or(0)-0.35f)<0.001f);assert(reloadCalls==3);
 auto configPath=RuntimeConfigFile::ResolveConfigPath();
 const auto permissions=std::filesystem::status(configPath).permissions();
 std::filesystem::permissions(configPath,std::filesystem::perms::owner_read);
 [vsync performClick:nil];assert([c.settingsStatus.stringValue containsString:@"Could not save"]);assert(reloadCalls==3);
 std::filesystem::permissions(configPath,permissions);[c refreshSettings];
 [vsync performClick:nil];[vsync performClick:nil];assert(reloadCalls==3);
 [c.settingsPanel setContentSize:NSMakeSize(820,570)];[c.settingsTabs selectTabViewItemAtIndex:1];[c.settingsTabs selectTabViewItemAtIndex:0];
 NSScrollView *scroll=(NSScrollView *)c.settingsTabs.selectedTabViewItem.view;
 assert(std::abs(NSMaxY(scroll.contentView.bounds)-NSHeight(scroll.documentView.frame))<1);
 [vsync scrollRectToVisible:vsync.bounds];
 [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
 [c.settingsPanel displayIfNeeded];
 assert(NSContainsRect(scroll.documentVisibleRect,vsync.frame));
 assert(NSMinY(vsync.frame)>=0 && NSMaxY(vsync.frame)<=NSHeight(scroll.documentView.frame));
 for(NSView *view in scroll.documentView.subviews){if(view==vsync)continue;assert(!NSIntersectsRect(view.frame,vsync.frame));}
 if(std::getenv("KARTPAD_SETTINGS_UI_CAPTURE")) {
  NSTask *capture=[NSTask new];capture.executableURL=[NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
  capture.arguments=@[@"-x",@"-l",[@(c.settingsPanel.windowNumber) stringValue],
      [NSString stringWithUTF8String:(expected/"settings-vsync.png").c_str()]];
  NSError *error=nil;assert([capture launchAndReturnError:&error]);[capture waitUntilExit];assert(capture.terminationStatus==0);
 }
 [c.settingsPanel close];puts("PASS: actual native checkbox action/save/error/reopen, adjacent controls, small-window scroll and row layout");
}}
