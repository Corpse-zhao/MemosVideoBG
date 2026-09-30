#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

@class MVBVideoBackgroundView;   // 前向声明

// ============================================================
// 备忘录视频背景 (MemosVideoBG) - 共享核心
// 作者: 板栗仁 | rootless / roothide / ElleKit / iOS 16.x
//
// 完全按「信息视频背景」的成熟架构移植, 宿主换成苹果「备忘录」App。
// 关键设计: 素材根「宿主容器优先」
//   roothide 把越狱根藏在 .jbroot-XXXX 随机路径下, 备忘录是系统沙盒
//   App, 其进程内既可能看不到 /var/jb, 也可能读不到 /var/mobile/Documents。
//   唯一必然可读写的只有「备忘录自己的数据容器」:
//       <备忘录容器>/Library/MemosVideoBG/
//   因此:
//     - tweak 侧 以自身容器为主根 (100% 可读写 -> 心跳/日志/素材必达)
//     - 控制App 侧 自动定位 MobileNotes 数据容器, 导入时把素材「多根齐写」
//   同时保留 jbroot / Documents 等共享根作为兜底, 用户放哪都能被扫到。
// ============================================================

#define MVB_VERSION @"1.0.0"
#define MVB_SUITE @"com.nvb.memosvideobg"
#define MVB_DARWIN_NOTE "com.nvb.memosvideobg/prefs.changed"
#define MVB_MEDIA_DIR_NAME @"MemosVideoBG"

// ------------------------------------------------------------
// 统一素材路径
//   用户只认这一个文件夹: /var/mobile/备忘录视频背景/板栗仁/
//   所有界面 (首页/笔记/文件夹/内部页/搜索一下/最近删除/多多创新)
//   共用这一个文件夹里的同一批视频, 每个界面单独记住自己选了哪个文件和效果。
//   它是「软链」—— 真实文件仍然躺在备忘录 App 数据容器里
//   (<备忘录容器>/Library/MemosVideoBG/), 因为沙盒宿主进程只能读容器,
//   读不到 /var/mobile 下的普通目录。软链让 Filza 里看到的路径就是这一条,
//   两边指向同一份物理文件, 放哪都生效 (改的都是同一批文件)。
// ------------------------------------------------------------
#define MVB_AUTHOR_NAME @"板栗仁"
#define MVB_MEDIA_FRIENDLY_PARENT @"/var/mobile/备忘录视频背景"
#define MVB_APP_BUNDLE_ID @"com.nvb.memosvideobg.app"
#define MVB_URL_SCHEME @"memosvideobg"

// 目标进程 = 苹果「备忘录」
#define MVB_NOTES_BUNDLE_ID @"com.apple.mobilenotes"

// 插件侧最可靠的根目录 (jbroot: 越狱进程必可访问)
NSString *MVBJBMediaDirectory(void);

// ---- 统一素材路径: 用户只看/只用这一条 ----
NSString *MVBMediaFriendlyRoot(void);
NSString *MVBMediaFriendlyPathForContext(NSString *ctx);
BOOL MVBEnsureFriendlyMediaPath(NSString **detail);
BOOL MVBOpenPathInFilza(NSString *path, NSString **message);

// 运维文件治理 (插件 %ctor 与控制App 启动时各跑一次)
void MVBCleanupHousekeeping(void);

// 全部候选素材根, 顺序 = 优先级 (容器根在前)
NSArray<NSString *> *MVBRootCandidates(void);
void MVBRefreshMediaRoots(void);

NSString *MVBAppContainerMediaDirectory(void);
NSString *MVBFindAppDataContainer(NSString *bundleId);
NSString *MVBHostBundleIdentifier(void);
NSString *MVBRootLabel(NSString *root);
BOOL MVBDirWritablePath(NSString *dir);

// 注入可视化横幅: 挂在宿主 App 窗口顶部, 点按隐藏
void MVBShowDebugBanner(NSString *text);
void MVBShowDebugBannerForce(NSString *text);

// ---- 7 类备忘录界面语境 ----
extern NSString * const MVBContextHome;      // 首页 (文件夹列表 / 主界面)
extern NSString * const MVBContextNote;      // 笔记 (单个笔记阅读/编辑正文)
extern NSString * const MVBContextFolder;    // 文件夹 (某个文件夹里的笔记列表)
extern NSString * const MVBContextInner;     // 内部页 (更多设置/子页面)
extern NSString * const MVBContextSearch;    // 搜索一下
extern NSString * const MVBContextRecent;    // 最近删除
extern NSString * const MVBContextInnovate;  // 多多创新 (新建文件夹等操作面板)
extern NSString * const MVBContextAll;       // 兜底: 全部

// 7 类界面定义: @[key, 标题, 说明]
NSArray<NSArray<NSString *> *> *MVBContextDefinitions(void);

@interface MVBManager : NSObject
+ (instancetype)shared;
- (NSUserDefaults *)prefs;

#pragma mark 配置 (文件 + prefs 双写, 跨沙盒必达)
- (NSDictionary *)effectiveConfig;
- (id)configValueForKey:(NSString *)key;
- (void)setConfigValue:(id)value forKey:(NSString *)key;

- (BOOL)masterEnabled;
// 全局效果 (0~1)
- (CGFloat)globalAlpha;
- (CGFloat)globalBlur;
- (CGFloat)globalVolume;
// 每个界面独立的效果参数 (未单独设置时回退到全局值)
- (CGFloat)alphaForContext:(NSString *)ctx;
- (CGFloat)blurForContext:(NSString *)ctx;
- (CGFloat)volumeForContext:(NSString *)ctx;
- (CGFloat)bubbleAlphaForContext:(NSString *)ctx;
// 界面离开时暂停该界面的播放器, 回来时恢复 (防多界面视频声音互串)
- (void)setContextActive:(BOOL)active context:(NSString *)ctx;
// 界面开关
- (BOOL)isEnabledForContext:(NSString *)ctx;
- (void)setEnabled:(BOOL)on forContext:(NSString *)ctx;
// 调试横幅开关 (默认开)
- (BOOL)debugBannerEnabled;

#pragma mark 素材目录 (多根聚合 / 多根齐写)
- (NSArray<NSString *> *)mediaRoots;
- (NSArray<NSString *> *)writableRoots;
- (NSString *)mediaDirectory;
- (NSString *)contextDirectory:(NSString *)ctx;
- (NSArray<NSString *> *)videosForContext:(NSString *)ctx;
- (NSString *)activeVideoNameForContext:(NSString *)ctx;
- (NSString *)activeVideoPathForContext:(NSString *)ctx;
- (void)setActiveVideoName:(NSString *)name forContext:(NSString *)ctx;
- (NSString *)importVideoFromFile:(NSURL *)srcURL toContext:(NSString *)ctx error:(NSError **)error;
- (void)deleteVideoName:(NSString *)name forContext:(NSString *)ctx;
- (NSString *)renameVideoName:(NSString *)name to:(NSString *)newName forContext:(NSString *)ctx;
- (NSString *)appDisplayName;
- (void)migrateMediaIntoPrimaryRoot;

#pragma mark 背景应用
- (AVPlayer *)playerForContext:(NSString *)ctx forceRebuild:(BOOL)force;
- (void)applyToViewController:(UIViewController *)vc context:(NSString *)ctx;
- (NSString *)appliedContextForViewController:(UIViewController *)vc;
- (void)detachFromViewController:(UIViewController *)vc;
- (void)refreshVisibleBackgrounds;
- (void)postChangeNotification;
- (void)startMediaWatchdog;

#pragma mark 前后台自愈
- (void)handleAppEnterBackground;
- (void)handleAppWillEnterForeground;
- (void)handleAppDidBecomeActive;
- (void)handleAudioInterruption:(NSNotification *)n;
- (void)recoverVideoPlaybackForce:(BOOL)force;
- (NSArray<MVBVideoBackgroundView *> *)allVideoBackgroundViews;

#pragma mark 切后台自动清理
@property (nonatomic, assign) BOOL bgKillEnabled;
@property (nonatomic, assign) NSTimeInterval bgKillDelay;
- (void)cancelScheduledBackgroundKill;

#pragma mark 诊断
- (void)log:(NSString *)fmt, ... NS_FORMAT_FUNCTION(1, 2);
- (void)logClassOnce:(NSString *)name context:(NSString *)ctx;
- (void)writeHeartbeat:(NSString *)tag;
- (NSString *)readHeartbeat;
- (NSString *)readTweakLog;
- (NSString *)injectionReport;
- (NSString *)rootsSummaryForContext:(NSString *)ctx;
- (NSString *)bannerTextForContext:(NSString *)ctx;
@end

@interface MVBVideoBackgroundView : UIView
@property (nonatomic, copy) NSString *contextKey;
@property (nonatomic, strong) AVPlayerLayer *videoLayer;
- (instancetype)initWithFrame:(CGRect)frame contextKey:(NSString *)key;
- (void)configure;
- (void)reconnectPlayerForce:(BOOL)force;
- (BOOL)playbackLooksBroken;
@end
