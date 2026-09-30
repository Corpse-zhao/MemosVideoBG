#import <UIKit/UIKit.h>
#import "MVBCommon.h"

// ============================================================
// 备忘录视频背景 独立控制 App
// 作者: 板栗仁
//  - 总开关 / 全局效果(透明度/模糊度/音量) / 七类界面独立开关
//  - 每界面独立素材管理: 相册导入(PHPicker) / 选用 / 删除
//  - Filza 直接放文件同样生效 (素材文件夹路径在页脚展示)
// ============================================================

@interface MVBAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@interface MVBHomeViewController : UITableViewController
@end

@interface MVBAppMaterialController : UITableViewController
@property (nonatomic, copy) NSString *contextKey;
@property (nonatomic, copy) NSString *contextTitle;
- (instancetype)initWithContext:(NSString *)ctx title:(NSString *)title;
@end

@interface MVBDiagnosticsController : UIViewController
@end

@interface MVBAppIdentityController : UITableViewController
@end

// v10.3.0 授权页: 读本机 UDID 发给作者 -> 粘贴作者回的离线授权串导入 (全程不联网)
@interface MVBAuthController : UITableViewController
@end
