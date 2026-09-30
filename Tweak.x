#import "MVBCommon.h"
#import "MVBAuth.h"
#import <CoreFoundation/CFNotificationCenter.h>

// ============================================================
// 备忘录视频背景 (MemosVideoBG) - 主插件
// 作者: 板栗仁 | rootless / roothide / ElleKit / iOS 16.x
//
//  - 首页 / 文件夹 / 笔记 / 搜索一下 / 最近删除 / 多多创新 / 内部页
//    七类界面独立开关 + 共用同一个素材文件夹
//  - 全局: 总开关 / 透明度 / 模糊度 / 音量(默认关闭)
//  - 所有 Hook 均有异常保护, 不影响宿主 App 正常启动
//
//  架构完全沿用「信息视频背景」的成熟方案:
//   1. filter 只挂 com.apple.mobilenotes (备忘录App)。
//   2. 只在备忘录App 进程里做界面 Hook (MVBIsNotesProcess 守卫)，
//      其它进程只写心跳, 不干扰宿主。
//   3. 进 App 后窗口顶部会出现一条可点关闭的横幅, 显示注入状态与各素材根
//      的可见性 —— 这是判断「插件到底进没进备忘录App」最直接的证据。
// ============================================================

// 当前进程是不是苹果「备忘录」App (只有它是真正要挂背景的目标)
static BOOL MVBIsNotesProcess(void) {
    static int cached = -1;
    if (cached < 0) {
        NSString *bid = MVBHostBundleIdentifier();
        cached = [bid isEqualToString:MVB_NOTES_BUNDLE_ID] ? 1 : 0;
    }
    return cached == 1;
}

// v1.9.0 授权总闸: 未激活/过期时, 所有「给视频背景让路」的透明化处理 (清底、藏卡、
// 拆材质) 一律停手 —— 否则页面被清成透明却没有任何背景, 比不装插件还难看。
// 同时 MVBManager 的挂载入口也做了同样判断 (双保险)。
static BOOL MVBShouldProcess(void) {
    if (!MVBIsLicensed()) return NO;
    return [[MVBManager shared] masterEnabled];
}

// 类名 -> 界面语境 (备忘录私有框架 IC* 前缀)
//
// iOS 16 备忘录关键类 (真机/历史工程实证):
//   ICFolderListViewController        首页 —— 文件夹列表 (最外层)
//   ICFolderViewController            文件夹 —— 某文件夹内的笔记列表
//   ICNoteBodyViewController          笔记正文 (只读展示)
//   ICNoteEditViewController          笔记编辑 (可写)
//   ICSearchViewController / ICNoteSearchViewController  搜索一下
//   ICRecentlyDeletedNote... / 含 RecentlyDeleted  最近删除
//   ICFolderCreationController / ICFolderAndNoteCreation... 多多创新 (新建)
// v1.2.0: 系统类名判定 —— 这些一律不碰 (按「原始类名」判, 不受 Swift 前缀影响)
static BOOL MVBIsSystemClassName(NSString *name) {
    if (!name.length) return YES;
    return [name hasPrefix:@"UI"] || [name hasPrefix:@"_UI"] ||
           [name hasPrefix:@"NS"] || [name hasPrefix:@"WK"] ||
           [name hasPrefix:@"SF"] || [name hasPrefix:@"CA"] ||
           [name hasPrefix:@"MF"] || [name hasPrefix:@"MK"] ||
           [name hasPrefix:@"SK"] || [name hasPrefix:@"PK"];
}

// v1.2.0: Swift 类名规范化。
// 备忘录有些控制器是 Swift 类, 运行时类名是 mangled 形式, 形如
//   "_TtC8NotesUI24ICNoteEditorViewController"    (_TtC <模块名长度><模块名> <类名长度><类名>)
// 旧代码见到 "_TtC" 前缀直接丢弃 -> 这些页面认不出语境 -> 整页毫无反应。
// 这里把 mangled 前缀剥掉, 还原成 "ICNoteEditorViewController" 再参与关键词判别。
static NSString *MVBNormalizedClassName(NSString *name) {
    if (![name hasPrefix:@"_TtC"]) return name;
    NSUInteger i = 4;                       // 跳过 "_TtC"
    NSUInteger len = 0;
    while (i < name.length) {               // 模块名长度
        unichar c = [name characterAtIndex:i];
        if (c < '0' || c > '9') break;
        len = len * 10 + (NSUInteger)(c - '0');
        i++;
    }
    i += len;                               // 跳过模块名
    NSUInteger clsLen = 0;
    while (i < name.length) {               // 类名长度
        unichar c = [name characterAtIndex:i];
        if (c < '0' || c > '9') break;
        clsLen = clsLen * 10 + (NSUInteger)(c - '0');
        i++;
    }
    if (clsLen && i + clsLen <= name.length)
        return [name substringWithRange:NSMakeRange(i, clsLen)];
    return name;                            // 格式不符, 原样返回 (关键词匹配仍可命中)
}

static NSString *MVBContextForClassName(NSString *rawName) {
    if (!rawName || rawName.length < 2) return nil;
    NSString *name = MVBNormalizedClassName(rawName);
    // 排除系统基类与前缀噪声
    if (MVBIsSystemClassName(rawName)) return nil;
    // Swift 类按剥壳后的名字再判一次系统前缀 (避免 _TtC 后面跟着 UI 系类)
    if (MVBIsSystemClassName(name)) return nil;

    // 排除键盘 / 选择器 / 输入 / 附件相关 (避免污染)
    if ([name containsString:@"Keyboard"] || [name containsString:@"Picker"] ||
        [name containsString:@"Input"]    || [name containsString:@"Compose"] ||
        [name containsString:@"Contact"]  || [name containsString:@"Activity"] ||
        [name containsString:@"Attachment"] ||
        [name containsString:@"Alert"]    || [name containsString:@"Popover"] ||
        [name containsString:@"Sheet"]) return nil;

    // 只处理备忘录自家类 (IC* / Notes*)，其它一律不碰
    // v1.2.0: 补上 Swift mangled 名 (模块名可能是 NotesUI / NotesEditor / NotesShared)
    BOOL notesish = [name hasPrefix:@"IC"] || [name hasPrefix:@"Notes"] ||
                    [rawName containsString:@"NotesUI"] || [rawName containsString:@"NotesEditor"] ||
                    [rawName containsString:@"NotesShared"] || [rawName containsString:@"MobileNotes"];
    if (!notesish) return nil;

    // ① 最近删除 (优先级最高 —— 类名里含 RecentlyDeleted 的都在这里)
    // v1.3.7: 兼容新写法 (iOS 16 备忘录某些版本上把 RecentlyDeleted 拆成
    // ICRecentlyDeletedViewController / ICTrashFolderViewController 这类, 类名
    // 不再含 "RecentlyDeleted"); 增补 "Trash"/"Deleted"/"Recycle" 关键词。
    if ([name containsString:@"RecentlyDeleted"] || [name containsString:@"RecentlyDeletedNote"] ||
        [name containsString:@"Trash"]          || [name containsString:@"Deleted"] ||
        [name containsString:@"Recycle"])
        return MVBContextRecent;

    // ② 搜索 (搜索页与其结果列表)
    if ([name containsString:@"Search"]) return MVBContextSearch;

    // ③ 新建文件夹 / 新建笔记等操作面板 = 多多创新
    if ([name containsString:@"Creation"]  || [name containsString:@"Create"] ||
        ([name containsString:@"Folder"] && [name containsString:@"And"]))
        return MVBContextInnovate;

    // ③b v1.3.1: 内部页 (设置/账户/更多/关于/标签样式...) —— **必须排在「笔记」前面**。
    // 备忘录不少内部页的类名里也带 "Editor" (xxEditorSettingsController 之类),
    // 而旧顺序先判 "Editor" 再判 "Settings" -> 这些页面全被判成「笔记」以外的语境,
    // 用户看到的就是「内部页跟笔记显示的不是同一支素材」。
    // v1.3.2: 内部页已并入「笔记」(用户要求合并删项) —— 直接返回 n_note,
    // 设置/账户/更多这类子页面与笔记共用同一套素材与效果。
    // 内部页天然带「设置/账户/更多/关于」这类词, 先判它们最稳。
    if ([name containsString:@"Settings"]   || [name containsString:@"Setting"] ||
        [name containsString:@"Preference"] || [name containsString:@"Account"] ||
        [name containsString:@"Debug"]      || [name containsString:@"About"] ||
        [name containsString:@"License"]    || [name containsString:@"Advanced"] ||
        [name containsString:@"Style"]      || [name containsString:@"More"])
        return MVBContextNote;

    // ④ 笔记正文 (Body = 只读正文, Edit = 编辑) —— 必须放在 Folder 前面判,
    //    因为 ICNoteBodyViewController 不含 Folder, 但有些类名同时含 Note 与 Folder
    if ([name containsString:@"NoteBody"] || [name containsString:@"NoteEdit"] ||
        [name containsString:@"NoteEditor"] || [name containsString:@"Editor"])
        return MVBContextNote;

    // ⑤ 文件夹列表 (首页) —— 必须放在「文件夹」前面判
    if ([name containsString:@"FolderList"]) return MVBContextHome;

    // ⑤b v1.3.7: iOS 16 备忘录用了 split-view 容器 (iPhone 上有时也用),
    // 真实根 VC 是 ICTrailingSidebarSplitViewController / ICSplitViewController 这类,
    // 上面再挂一个 ICFolderListViewController (子 VC), 但父 VC 没认出来 → 整页
    // 落到 n_all 兜底, 没有 n_all 素材 → 卡片盖住视频 → 用户看到纯黑/闪白。
    // 把任何「带 Sidebar / Split / Outline 字段」的容器都按首页认, 让子 VC 自己细化。
    if ([name containsString:@"Sidebar"]   || [name containsString:@"SplitView"] ||
        [name containsString:@"Outline"]   || [name containsString:@"Trailing"])
        return MVBContextHome;

    // ⑥ 单个文件夹内的笔记列表
    if ([name containsString:@"Folder"] ||
        [name containsString:@"NoteList"] ||
        [name containsString:@"NotesList"]) return MVBContextFolder;

    // ⑥b v1.2.0: 笔记列表在部分系统版本上叫 *Browse* (ICNoteBrowseViewController 之类)
    if ([name containsString:@"Browse"]) return MVBContextFolder;

    return nil;
}

// v1.3.1: 这个控制器是不是「被模态/覆盖式呈现出来的操作面板」。
// 用途: 「新建文件夹」这类面板往往用私有类名 (不在我们的关键词表里), 认不出就一直落到
// 兜底语境 n_all —— 而 n_all 会解析到「根目录排序第一个」那支素材, 于是用户看到
// 「多多创新显示的也是首页的视频素材」。
// 备忘录里被 present 出来的东西基本都是操作面板 = 多多创新, 所以这个判据很划算,
// 而且完全不依赖类名 (系统换类名也不影响)。
static BOOL MVBIsPresentedPanel(UIViewController *vc) {
    if (!vc) return NO;
    @try {
        if (vc.isBeingDismissed) return NO;
        if (vc.presentingViewController) return YES;
        UIViewController *nav = vc.navigationController;
        if (nav && nav.presentingViewController) return YES;
    } @catch (NSException *e) {}
    return NO;
}

// 只对「确认返回对象类型(@)的方法」做消息发送 —— 返回结构体/原始类型的选择器
// 若直接 objc_msgSend 会崩 (实测: 备忘录App「过滤条件」页闪退即此因)
// 备忘录没有「过滤器选择页」概念, 但主界面是 split 容器 —— 导航根判别不可靠。
// 这里只保留一个轻量的「标题扫描」工具: 判断视图里是否存在某个标题文本,
// 用于「最近删除 / 搜索」等标题明确的页面兜底确认。
static void MVBScanForTitles(UIView *v, NSInteger depth, NSUInteger *hits, NSArray<NSString *> *rows) {
    if (!v || depth > 8) return;
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)v).text ?: @"";
        for (NSString *row in rows) {
            if ([t isEqualToString:row]) { (*hits)++; break; }
        }
    }
    for (UIView *s in v.subviews) MVBScanForTitles(s, depth + 1, hits, rows);
}

static BOOL MVBViewHasAnyTitle(UIViewController *vc, NSArray<NSString *> *titles) {
    if (!vc.view) return NO;
    NSUInteger hits = 0;
    MVBScanForTitles(vc.view, 0, &hits, titles);
    return hits >= 1;
}

// v1.2.0: 视图子树里是否含有「列表/滚动容器」。
// 备忘录真正的内容页 (文件夹内笔记列表 / 最近删除 / 搜索) 里, vc.view 往往是
// 普通容器, 真正的 UICollectionView 是子视图 —— 用它来判断「这页值不值得挂背景」。
static BOOL MVBViewHostsScrollable(UIView *v, NSInteger depth) {
    if (!v || depth > 5) return NO;
    if ([v isKindOfClass:[UITableView class]] ||
        [v isKindOfClass:[UICollectionView class]]) return YES;
    for (UIView *s in v.subviews)
        if (MVBViewHostsScrollable(s, depth + 1)) return YES;
    return NO;
}

// 备忘录页面语境判别: 先看导航标题 (最可靠), 再看类名兜底。
// 标题取自系统语言, 中英文都覆盖。
static NSString *MVBDetectNotesContext(UIViewController *vc, NSString *fallback) {
    @try {
        Class cls = [vc class];
        NSString *title = vc.title ?: vc.navigationItem.title;
        if (title.length) {
            [[MVBManager shared] logClassOnce:
                [NSString stringWithFormat:@"title「%@」on %@", title, cls] context:@"(标题探测)"];

            if ([title containsString:@"最近删除"] ||
                [title localizedCaseInsensitiveContainsString:@"Recently Deleted"])
                return MVBContextRecent;
            if ([title containsString:@"搜索"] ||
                [title localizedCaseInsensitiveContainsString:@"Search"])
                return MVBContextSearch;
            if ([title containsString:@"新建"] || [title containsString:@"创建"] ||
                [title localizedCaseInsensitiveContainsString:@"New"])
                return MVBContextInnovate;
            // v1.3.2: 内部页并入「笔记」
            if ([title containsString:@"设置"] || [title containsString:@"更多"] ||
                [title localizedCaseInsensitiveContainsString:@"Settings"])
                return MVBContextNote;
        }

        // 类名判别 (备注: 标题很多页面是空的, 类名才是主判据)
        NSString *cn = MVBContextForClassName(NSStringFromClass(cls));
        if (cn.length) return cn;
    } @catch (NSException *e) {}
    return fallback;
}

// 横幅刷新 (注入探针进程也能用, 内容会标明是哪个 App)
// v1.3.0: 加 0.6s 节流 —— 横幅文案要列目录 (IO) + 建窗口, 而一次页面出现会被
// 兜底 hook 与显式 hook 各触发一次; 启动瞬间重复拼两遍会拖慢首帧。
static CFAbsoluteTime sMVBLastBannerAt = 0;
static void MVBRefreshBanner(NSString *ctx) {
    @try {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (sMVBLastBannerAt > 0 && now - sMVBLastBannerAt < 0.6) return;
        sMVBLastBannerAt = now;
        // v1.9.0: 未授权提示不受「诊断横幅」开关影响, 必须让用户看到原因
        if (!MVBIsLicensed()) MVBShowDebugBannerForce([[MVBManager shared] bannerTextForContext:ctx]);
        else                 MVBShowDebugBanner([[MVBManager shared] bannerTextForContext:ctx]);
    } @catch (NSException *e) {}
}

// v1.7.20: 主页面容器清扫升级。v1.7.18 只清 UIView.backgroundColor, 实测白卡依旧
// (用户截图实锤), 白色来源还有三类:
//   a) 直接设在 CALayer 上的底色 (圆角卡片常这么画, UIView 层是 nil);
//   b) UIVisualEffectView 模糊卡 / UIImageView 背景图 (此前豁免不敢动);
//   c) 滚动复用后系统重新铺白 (定时补扫覆盖不到)。
// 对策:
//   a) layer 层底色一并清;
//   b) 「大面积 + 无文字/控件」的视图判为卡片底, 整体藏掉 (alpha 记录可恢复);
//      cell 的 backgroundView/selectedBackgroundView 子树整体跳过 (v1.7.20 实锤:
//      任何改动都会和 backgroundConfiguration 重应用撞车, 点选时 SIGABRT);
//   c) 白色改在「赋色源头」拦: UICollectionViewListCell 背景配置 setter + 默认外观
//      重铺 (_updateDefaultBackgroundAppearance) + 分区背景装饰视图的
//      setBackgroundColor: (系统每赋一次色就被改回透明)。
// v1.3.2: 被藏的卡片**按页面归档** (挂在页面根视图上), 不再放全局数组。
// 旧做法是全局一个数组 —— 「多多创新」面板自己的清扫若判定为不活跃, 会把
// **首页**藏起来的白卡一并恢复, 用户看到的就是「打开创新一下再退出, 主页变白」。
// 现在恢复只作用于「发起这次清扫的那个页面」, 页与页之间不再串。
static char MVBOrigAlphaKey;
static char MVBOrigHiddenKey;
static char MVBHostHiddenCardsKey;

// 子树里有没有「必须可见」的内容 (文字/控件/输入框) —— 有就不能整体藏
static BOOL MVBSubtreeHasContent(UIView *v, NSInteger depth) {
    if (!v || depth > 8) return NO;
    if ([v isKindOfClass:[UILabel class]] || [v isKindOfClass:[UIControl class]] ||
        [v isKindOfClass:[UITextField class]]) return YES;
    for (UIView *s in v.subviews)
        if (MVBSubtreeHasContent(s, depth + 1)) return YES;
    return NO;
}

// 子树里有没有视频背景视图 (绝不能藏到它的祖先)
static BOOL MVBSubtreeHasVideoBg(UIView *v, NSInteger depth) {
    if (!v || depth > 10) return NO;
    if ([v isKindOfClass:[MVBVideoBackgroundView class]]) return YES;
    for (UIView *s in v.subviews)
        if (MVBSubtreeHasVideoBg(s, depth + 1)) return YES;
    return NO;
}

// 大面积卡片判定: 横贯版面 (>=55% 父宽) 且有一定高度, 里面没有文字/控件
static BOOL MVBIsBigCard(UIView *v) {
    CGSize sz = v.bounds.size;
    if (sz.width < 120 || sz.height < 36) return NO;
    CGFloat supW = v.superview ? v.superview.bounds.size.width : 0;
    if (supW > 0 && sz.width < supW * 0.55) return NO;
    if (MVBSubtreeHasContent(v, 0)) return NO;
    if (MVBSubtreeHasVideoBg(v, 0)) return NO;
    return YES;
}

static NSMutableArray<UIView *> *MVBHiddenCardsForHost(UIView *host, BOOL create) {
    if (!host) return nil;
    NSMutableArray<UIView *> *arr = objc_getAssociatedObject(host, &MVBHostHiddenCardsKey);
    if (!arr && create) {
        arr = [NSMutableArray new];
        objc_setAssociatedObject(host, &MVBHostHiddenCardsKey, arr,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return arr;
}

static void MVBRecordHideCard(UIView *host, UIView *v) {
    if (!host || !v || v.hidden) return;
    NSMutableArray<UIView *> *arr = MVBHiddenCardsForHost(host, YES);
    // 清理已脱离视图树的旧记录, 防数组随滚动膨胀
    NSIndexSet *dead = [arr indexesOfObjectsPassingTest:
        ^BOOL(UIView *h, NSUInteger i, BOOL *stop) { return h.superview == nil; }];
    if (dead.count) [arr removeObjectsAtIndexes:dead];
    if (objc_getAssociatedObject(v, &MVBOrigAlphaKey)) { v.hidden = YES; return; }
    objc_setAssociatedObject(v, &MVBOrigAlphaKey, @(v.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(v, &MVBOrigHiddenKey, @(v.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [arr addObject:v];
    v.hidden = YES;
}

// 恢复「host 这一页」自己藏掉的卡片 (v1.3.2: 不再跨页面恢复)
static void MVBRestoreHiddenCards(UIView *host) {
    NSMutableArray<UIView *> *arr = MVBHiddenCardsForHost(host, NO);
    if (!arr.count) return;
    for (UIView *v in [arr copy]) {
        NSNumber *a = objc_getAssociatedObject(v, &MVBOrigAlphaKey);
        NSNumber *h = objc_getAssociatedObject(v, &MVBOrigHiddenKey);
        if (a) v.alpha = a.doubleValue;
        if (h) v.hidden = h.boolValue;
    }
    [arr removeAllObjects];
    objc_setAssociatedObject(host, &MVBHostHiddenCardsKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// v1.2.0: 清扫按「当前界面自己的开关」判定。
// 此前绑死在首页开关上 (m.masterEnabled && isEnabledForContext:Home), 而
// MVBClearContainerBGs 又只在首页路径被调用 —— 于是文件夹/笔记/最近删除等界面
// 虽然挂上了视频, 却被页面自身的白底整片盖住, 用户看到的就是「只有首页生效」。
static BOOL MVBSweepActiveForContext(NSString *ctx) {
    if (!MVBIsLicensed()) return NO;   // v1.9.0: 未授权不做任何清扫
    if (!ctx.length) return NO;
    MVBManager *m = [MVBManager shared];
    if (!m.masterEnabled || ![m isEnabledForContext:ctx]) return NO;
    // v1.3.0: 本界面**真的配了素材**才允许清底。
    // 此前只看开关 —— 某个界面没配素材时它的页面照样被刷成透明, 于是「透过去」看到的
    // 就是后面那一页还在播的视频 (用户: 「视频图层会透到上一层」「首页跟多多创新的
    // 视频是一样的」), 或者是系统窗口的白底 (「刚点进备忘录卡一下白一下」)。
    // 没有背景可显示时就该原样保留 —— 不该在页面上开一个洞。
    return [m activeVideoPathForContext:ctx].length > 0;
}

// 供「拿不到 VC 上下文」的 chrome 钩子使用: 取最近一次应用的界面
static BOOL MVBMainSweepActive(void) {
    return MVBSweepActiveForContext([[MVBManager shared] currentContext]);
}

static void MVBClearContainerBGs(UIView *host, UIView *v, NSInteger depth,
                                 NSString *ctx, BOOL hideCards) {
    if (!host || !v || depth > 14) return;
    if ([v isKindOfClass:[MVBVideoBackgroundView class]]) return;
    // v1.3.0: 「本界面该不该清」只在最外层判一次。原来每层都判, 而每次判定要读配置 +
    // 列素材目录 (同步 IO) —— 一页几百个节点就是几百次 IO, 是「卡一下」的主要来源。
    // ctx 在整棵树里是常量, 结果必然相同。
    // v1.3.2: host = 发起清扫的页面根视图 —— 被藏卡片的恢复只作用于它自己这一页。
    if (depth == 0 && !MVBSweepActiveForContext(ctx)) { MVBRestoreHiddenCards(host); return; }
    // v1.7.21: cell 的系统托管背景子树整体跳过 (不藏不清)。v1.7.20 曾藏
    // backgroundView/selectedBackgroundView + layoutSubviews 持续重扫, 与系统的
    // backgroundConfiguration 重应用撞车 —— 点选单元格时 SIGABRT (崩溃日志实锤:
    // _applyBackgroundViewConfiguration -> invalidateLayout 期间再被我们改动)。
    // 白色改为在「赋色源头」拦 (见下面 UICollectionViewListCell / 分区装饰视图钩子)。
    UIView *cellBg = nil, *cellSelBg = nil;
    if ([v isKindOfClass:[UICollectionViewCell class]]) {
        UICollectionViewCell *c = (UICollectionViewCell *)v;
        cellBg = c.backgroundView;
        cellSelBg = c.selectedBackgroundView;
    }
    BOOL isProtected = [v isKindOfClass:[UILabel class]] ||
                       [v isKindOfClass:[UIImageView class]] ||
                       [v isKindOfClass:[UIControl class]] ||
                       [v isKindOfClass:[UITextField class]] ||
                       [v isKindOfClass:[UIVisualEffectView class]];
    if (!isProtected) {
        if (v.backgroundColor && ![v.backgroundColor isEqual:[UIColor clearColor]])
            v.backgroundColor = [UIColor clearColor];
        // v1.7.20: layer 层底色 (圆角白卡常直接设在 CALayer 上, UIView 层是 nil)
        if (v.layer.backgroundColor && !CGColorEqualToColor(v.layer.backgroundColor, [UIColor clearColor].CGColor))
            v.layer.backgroundColor = NULL;
    }
    // v1.7.20: 大面积无内容的白卡/模糊卡/背景图 -> 整体藏掉 (文字图标小控件不动)
    // v1.2.0: 「藏大白卡」只在首页启用 —— 那是首页分组卡片的专用对策,
    //         在笔记正文/文件夹等页面误伤风险高, 这些页面只做底色透明化。
    if (hideCards && MVBIsBigCard(v)) MVBRecordHideCard(host, v);
    for (UIView *s in v.subviews) {
        if (s == cellBg || s == cellSelBg) continue;   // 托管背景子树不碰
        MVBClearContainerBGs(host, s, depth + 1, ctx, hideCards);
    }
}

// v1.2.0: 清扫入口 (带节流)。
// 同一页面出现时, 兜底 hook 与显式 hook 会各调一次 MVBApplyPage, 再加上多段延迟补扫
// —— 整树遍历好几遍没必要。这里 0.12s 内只真正扫一次, 剩下的交给后面的补扫兜住。
static CFAbsoluteTime sMVBLastSweepAt = 0;
static void MVBSweepPage(UIView *v, NSString *ctx, BOOL hideCards) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (sMVBLastSweepAt > 0 && now - sMVBLastSweepAt < 0.12) return;
    sMVBLastSweepAt = now;
    MVBClearContainerBGs(v, v, 0, ctx, hideCards);
}

// v1.3.0: 「当前页的视频出画面了没有」。
// 为什么需要它: 清底 (把页面刷透明) 必须在视频首帧**已解码**之后才能做。
// 先把页面清成透明、视频却还在准备 -> 中间露出的就是系统窗口的白底,
// 用户看到的就是「刚点进备忘录卡一下白一下」。
// 没有背景视图 (该界面没开 / 没素材) 时返回 YES —— 那种情况不需要等。
static BOOL MVBPageVideoReady(UIViewController *vc) {
    MVBVideoBackgroundView *bg = [[MVBManager shared] backgroundForViewController:vc];
    if (!bg || !bg.videoLayer) return YES;   // 没有背景/还没建层 -> 无需等
    return bg.videoLayer.isReadyForDisplay;
}

// v1.3.0: 清扫前的统一闸门 —— 页面里的白底/白卡只在「本页视频已出画面」后才清。
static void MVBSweepIfReady(UIViewController *vc, NSString *ctx, BOOL hideCards) {
    if (!vc || !vc.isViewLoaded || !vc.view.window) return;
    if (!MVBPageVideoReady(vc)) return;
    MVBSweepPage(vc.view, ctx, hideCards);
}

// v1.2.0: 任意界面都挂背景 + 清扫 + 延迟补扫。
// 此前只有首页做清扫 (MVBApplyMainPage), 其它界面只挂背景 -> 被白底盖住 = 「不生效」。
// hideCards (藏大面积白卡) 仍只在首页开启。
static char MVBLastApplyAtKey;
static char MVBLastApplyCtxKey;
static void MVBApplyPage(UIViewController *vc, NSString *ctx) {
    if (!vc || !ctx.length) return;
    // v1.3.0: 同一页面 + 同一语境 250ms 内只真正做一次
    // (兜底 hook 与显式 hook 会各调一次, 重复跑一遍 apply 很贵: 要扫全部窗口的 chrome)
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSNumber *lastAt = objc_getAssociatedObject(vc, &MVBLastApplyAtKey);
    NSString *lastCtx = objc_getAssociatedObject(vc, &MVBLastApplyCtxKey);
    if (lastAt && lastCtx && [lastCtx isEqualToString:ctx] &&
        now - lastAt.doubleValue < 0.25) return;
    objc_setAssociatedObject(vc, &MVBLastApplyAtKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, &MVBLastApplyCtxKey, [ctx copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [[MVBManager shared] applyToViewController:vc context:ctx];
    BOOL hideCards = [ctx isEqualToString:MVBContextHome];
    MVBRefreshBanner(ctx);
    __weak UIViewController *wvc = vc;
    NSString *ctxCopy = [ctx copy];
    // 首帧前密集试探 (一到位立刻清底), 之后按原来的节奏补扫兜住延迟铺上来的白卡。
    // 0.8s 之后不再等 —— 万一某个素材的 layer 一直不上报 ready, 也不能让页面一直不清底
    // (宁可接受一次轻微的闪, 也不能变成「完全没背景」)。
    NSTimeInterval delays[8] = {0.08, 0.16, 0.28, 0.45, 0.8, 1.4, 2.5, 5.0};
    for (int i = 0; i < 8; i++) {
        NSTimeInterval t = delays[i];
        BOOL force = (i >= 4);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                UIViewController *s = wvc;
                if (!s || !s.isViewLoaded || !s.view.window) return;
                // v1.3.0: 视图确实回到窗口了 -> 重算一次「谁被盖住」。
                // 从下一层返回时, viewWillAppear 那一刻视图可能还没挂回窗口,
                // 那一拍算出来的「被盖住」是假阳性; 这里补一次保证背景必定回来。
                [[MVBManager shared] refreshCoveredBackgrounds];
                // v1.3.1: 系统 chrome (导航栏/导航项/底部工具栏/材质背板) 常常晚于
                // viewWillAppear 才建好或才铺上材质, 只在 apply 里做一次会「看运气」。
                // v1.3.2: 拆成两层 ——
                //   · refreshChromeAppearancesForViewController: 只改外观/Transparency,
                //     不拆材质不藏视图, 首帧没到也**不会闪白**, 所以**每一拍都刷**。
                //     原来只在 0.8s 之后刷 -> 用户看到的「底部白条要等一会才透明」
                //     就是这里等出来的。
                //   · refreshChromeForViewController:context: 会 strip 整页材质 + 深扫,
                //     早做会闪白, 仍留在偏后的节拍。
                [[MVBManager shared] refreshChromeAppearancesForViewController:s];
                if (i == 4 || i == 5 || i == 7)
                    [[MVBManager shared] refreshChromeForViewController:s context:ctxCopy];
                if (force) {
                    // 兜底: 视频一直没出画面也不再拖, 照常清底
                    MVBSweepPage(s.view, ctxCopy, hideCards);
                    return;
                }
                MVBSweepIfReady(s, ctxCopy, hideCards);
            } @catch (NSException *e) {}
        });
    }
}

// Darwin 通知回调: 控制App 改了配置 -> 实时让所有视频背景视图重新 configure。
// (CFNotificationCenterAddObserver 要求一个 C 函数指针, 不能直接传消息表达式)
static void MVBPrefsChanged(CFNotificationCenterRef center, void *observer,
                            CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    // v1.3.0: 控制App 改了配置 -> 先作废配置快照, 再让所有背景视图重新 configure
    [[MVBManager shared] invalidateConfigCache];
    [[MVBManager shared] refreshVisibleBackgrounds];
}


#pragma mark - 备忘录 App Hook

// 备忘录 iOS 16 关键控制器 (私有框架, 只有前向声明; 全部按 UIViewController 处理)
@interface ICFolderListViewController : UIViewController @end        // 首页
@interface ICFolderViewController : UIViewController @end            // 文件夹内笔记列表
@interface ICNoteListViewController : UIViewController @end          // 笔记列表 (部分版本)
@interface ICNoteBodyViewController : UIViewController @end          // 笔记正文 (只读)
@interface ICNoteEditViewController : UIViewController @end          // 笔记编辑
@interface ICSearchViewController : UIViewController @end            // 搜索
@interface ICFolderCreationController : UIViewController @end        // 新建文件夹 (多多创新)

#define MVB_NOTES_GUARD() if (!MVBIsNotesProcess()) return;
// v1.2.0: 所有界面统一走 MVBApplyPage (挂背景 + 清扫 + 延迟补扫)。
// 此前只有首页走清扫路径, 其它界面只挂背景 -> 被页面白底盖住 = 「只有首页生效」。
// (宏展开发生在使用处, 所以这里引用下面定义的 MVB_APPLY_CTX 是安全的)
#define MVB_SAFE_APPLY(ctx) MVB_APPLY_CTX(self, ctx)

#define MVB_APPLY_CTX(vc, c) @try { \
    MVBApplyPage((vc), (c)); \
} @catch (NSException *e) {}

// v1.7.21: 白色一律在「赋色源头」拦, 不做任何 layout 中途改动 (v1.7.20 的
// layoutSubviews 持续重扫已撤 —— 与 backgroundConfiguration 重应用撞车崩溃)。

// 1) 选中态白卡: 见下方 _updateDefaultBackgroundAppearance 钩子说明。
%hook UICollectionViewListCell
- (void)setBackgroundConfiguration:(UIBackgroundConfiguration *)cfg {
    @try {
        if (cfg && MVBIsNotesProcess() && MVBShouldProcess())
            cfg.backgroundColor = [UIColor clearColor];
    } @catch (NSException *e) {}
    %orig(cfg);
}
// v1.7.21: 选中/高亮白卡 —— 点一下单元格出现的白, 来自系统的默认选中外观重铺
// (崩溃日志实锤路径: _setLayoutAttributes -> _updateDefaultBackgroundAppearance ->
// _applyBackgroundViewConfiguration, 不经过公开的 setBackgroundConfiguration:
// setter, 所以之前拦不到)。对策: 系统铺完默认外观后, 异步 (避开 layout 重入)
// 给 cell 补一个全透明 backgroundConfiguration —— 走公共 API, 是 UIKit 设计内的
// 合法赋值路径, 之后选中/高亮状态都基于这份透明配置, 白卡不再回来。
- (void)_updateDefaultBackgroundAppearance {
    %orig;
    @try {
        if (!MVBIsNotesProcess()) return;
        if (!MVBShouldProcess()) return;
        if (self.backgroundConfiguration) return;
        __weak UICollectionViewListCell *wcell = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                if (!wcell.backgroundConfiguration)
                    wcell.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];
            } @catch (NSException *e) {}
        });
    } @catch (NSException *e) {}
}
- (void)layoutSubviews {
    %orig;
    @try {
        if (!MVBIsNotesProcess()) return;
        if (!MVBShouldProcess()) return;
        // 只清 UIView 层底色 (UIView.backgroundColor 不触发集合布局失效, 安全)
        if (self.backgroundColor && ![self.backgroundColor isEqual:[UIColor clearColor]])
            self.backgroundColor = [UIColor clearColor];
        UIView *cv = self.contentView;
        if (cv.backgroundColor && ![cv.backgroundColor isEqual:[UIColor clearColor]])
            cv.backgroundColor = [UIColor clearColor];
    } @catch (NSException *e) {}
}
%end

// 列表头/脚 (大标题 + 搜索框区域) 滚动复用时同样会重设白色底色
%hook UICollectionReusableView
- (void)layoutSubviews {
    %orig;
    @try {
        if (!MVBIsNotesProcess()) return;
        if (!MVBShouldProcess()) return;
        if (self.backgroundColor && ![self.backgroundColor isEqual:[UIColor clearColor]])
            self.backgroundColor = [UIColor clearColor];
    } @catch (NSException *e) {}
}
%end

%hook UITableViewCell
- (void)layoutSubviews {
    %orig;
    @try {
        if (!MVBIsNotesProcess()) return;
        if (!MVBShouldProcess()) return;
        if (self.backgroundView) self.backgroundView = nil;
        if (self.backgroundColor && ![self.backgroundColor isEqual:[UIColor clearColor]])
            self.backgroundColor = [UIColor clearColor];
        UIView *cv = self.contentView;
        if (cv.backgroundColor && ![cv.backgroundColor isEqual:[UIColor clearColor]])
            cv.backgroundColor = [UIColor clearColor];
    } @catch (NSException *e) {}
}
%end

// ------------------------------------------------------------
// 备忘录页面 Hook
//
// 判定策略 (沿用信息版的经验, 但换成本宿主的私有类):
//   viewWillAppear  -> 探测语境, 挂背景, 标记该 VC 的语境
//   viewDidAppear   -> 再探测一次 (标题/层级此时才稳定) + 延迟复检
//   viewDidDisappear-> 暂停该语境播放器 (防多界面声音互串)
//
// 「首页」是全套白卡对抗的主战场: 备忘录首页同样是 compositional list,
// 分组白卡会反复铺白盖住背景, 所以首页走 MVBApplyMainPage (挂背景 + 清扫 + 补扫)。
// ------------------------------------------------------------

static char MVBDetectedCtxKey;

// ---------- ① 首页: 文件夹列表 (I C F o l d e r L i s t) ----------
%hook ICFolderListViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    MVB_NOTES_GUARD()
    objc_setAssociatedObject(self, &MVBDetectedCtxKey, MVBContextHome,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [[MVBManager shared] logClassOnce:NSStringFromClass([self class]) context:MVBContextHome];
    MVB_APPLY_CTX(self, MVBContextHome)
    [[MVBManager shared] setContextActive:YES context:MVBContextHome];
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    MVB_NOTES_GUARD()
    MVB_APPLY_CTX(self, MVBContextHome)
    // 首页白卡会延迟铺上来, 补扫一轮
    __weak typeof(self) wself = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            __strong typeof(wself) sself = wself;
            if (!sself || !sself.isViewLoaded || !sself.view.window) return;
            MVBSweepPage(sself.view, MVBContextHome, YES);
        } @catch (NSException *e) {}
    });
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    MVB_NOTES_GUARD()
    NSString *ctx = [[MVBManager shared] appliedContextForViewController:self]
        ?: objc_getAssociatedObject(self, &MVBDetectedCtxKey) ?: MVBContextHome;
    @try { [[MVBManager shared] setContextActive:NO context:ctx]; } @catch (NSException *e) {}
}
%end

// ---------- ② 文件夹: 某文件夹内的笔记列表 ----------
%hook ICFolderViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    MVB_NOTES_GUARD()
    NSString *ctx = MVBDetectNotesContext(self, MVBContextFolder);
    objc_setAssociatedObject(self, &MVBDetectedCtxKey, ctx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [[MVBManager shared] logClassOnce:NSStringFromClass([self class]) context:ctx];
    MVB_APPLY_CTX(self, ctx)
    [[MVBManager shared] setContextActive:YES context:ctx];
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    MVB_NOTES_GUARD()
    NSString *ctx = MVBDetectNotesContext(self,
        objc_getAssociatedObject(self, &MVBDetectedCtxKey) ?: MVBContextFolder);
    objc_setAssociatedObject(self, &MVBDetectedCtxKey, ctx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    MVB_APPLY_CTX(self, ctx)
    // 延迟复检: 归类可能被标题改写 (如「最近删除」)
    __weak typeof(self) wself = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            __strong typeof(wself) sself = wself;
            if (!sself || !sself.isViewLoaded || !sself.view.window) return;
            NSString *ctx2 = MVBDetectNotesContext(sself,
                objc_getAssociatedObject(sself, &MVBDetectedCtxKey) ?: MVBContextFolder);
            if (![ctx2 isEqualToString:ctx]) {
                objc_setAssociatedObject(sself, &MVBDetectedCtxKey, ctx2, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                MVB_APPLY_CTX(sself, ctx2)
            }
        } @catch (NSException *e) {}
    });
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    MVB_NOTES_GUARD()
    NSString *ctx = [[MVBManager shared] appliedContextForViewController:self]
        ?: objc_getAssociatedObject(self, &MVBDetectedCtxKey) ?: MVBContextFolder;
    @try { [[MVBManager shared] setContextActive:NO context:ctx]; } @catch (NSException *e) {}
}
%end

// ---------- ③ 笔记列表 (部分机型/版本) ----------
%hook ICNoteListViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    MVB_NOTES_GUARD()
    // 笔记列表可能是「文件夹 / 最近删除 / 搜索 / 新建」四种之一, 按标题细分
    NSString *ctx = MVBContextFolder;
    if (MVBViewHasAnyTitle(self, @[@"最近删除", @"Recently Deleted"]))       ctx = MVBContextRecent;
    else if (MVBViewHasAnyTitle(self, @[@"搜索", @"Search"]))               ctx = MVBContextSearch;
    else if (MVBViewHasAnyTitle(self, @[@"新建文件夹", @"New Folder"]))      ctx = MVBContextInnovate;
    objc_setAssociatedObject(self, &MVBDetectedCtxKey, ctx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [[MVBManager shared] logClassOnce:NSStringFromClass([self class]) context:ctx];
    MVB_APPLY_CTX(self, ctx)
    [[MVBManager shared] setContextActive:YES context:ctx];
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    MVB_NOTES_GUARD()
    NSString *ctx = [[MVBManager shared] appliedContextForViewController:self]
        ?: objc_getAssociatedObject(self, &MVBDetectedCtxKey) ?: MVBContextFolder;
    @try { [[MVBManager shared] setContextActive:NO context:ctx]; } @catch (NSException *e) {}
}
%end

// ---------- ④ 笔记正文 (只读) ----------
%hook ICNoteBodyViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    MVB_NOTES_GUARD()
    [[MVBManager shared] logClassOnce:NSStringFromClass([self class]) context:MVBContextNote];
    MVB_SAFE_APPLY(MVBContextNote)
    [[MVBManager shared] setContextActive:YES context:MVBContextNote];
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    MVB_NOTES_GUARD()
    MVB_SAFE_APPLY(MVBContextNote)
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    MVB_NOTES_GUARD()
    @try { [[MVBManager shared] setContextActive:NO context:MVBContextNote]; } @catch (NSException *e) {}
}
%end

// ---------- ⑤ 笔记编辑 ----------
%hook ICNoteEditViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    MVB_NOTES_GUARD()
    [[MVBManager shared] logClassOnce:NSStringFromClass([self class]) context:MVBContextNote];
    MVB_SAFE_APPLY(MVBContextNote)
    [[MVBManager shared] setContextActive:YES context:MVBContextNote];
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    MVB_NOTES_GUARD()
    MVB_SAFE_APPLY(MVBContextNote)
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    MVB_NOTES_GUARD()
    @try { [[MVBManager shared] setContextActive:NO context:MVBContextNote]; } @catch (NSException *e) {}
}
%end

// ---------- ⑥ 搜索一下 ----------
%hook ICSearchViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    MVB_NOTES_GUARD()
    [[MVBManager shared] logClassOnce:NSStringFromClass([self class]) context:MVBContextSearch];
    MVB_SAFE_APPLY(MVBContextSearch)
    [[MVBManager shared] setContextActive:YES context:MVBContextSearch];
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    MVB_NOTES_GUARD()
    @try { [[MVBManager shared] setContextActive:NO context:MVBContextSearch]; } @catch (NSException *e) {}
}
%end

// ---------- ⑦ 多多创新: 新建文件夹等操作面板 ----------
%hook ICFolderCreationController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    MVB_NOTES_GUARD()
    [[MVBManager shared] logClassOnce:NSStringFromClass([self class]) context:MVBContextInnovate];
    MVB_SAFE_APPLY(MVBContextInnovate)
    [[MVBManager shared] setContextActive:YES context:MVBContextInnovate];
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    MVB_NOTES_GUARD()
    @try { [[MVBManager shared] setContextActive:NO context:MVBContextInnovate]; } @catch (NSException *e) {}
}
%end

// 兜底: 类名关键词分发 —— 备忘录的类很多, 不可能逐个显式 hook。
// 这里对「类名命中 IC*/Notes* 关键词」的控制器统一兜底挂背景。
// 显式 hook 的那些类 (首页/文件夹/笔记/搜索) 会先跑, 这里是漏网之鱼的补充。
%hook UIViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    MVB_NOTES_GUARD()
    @try {
        NSString *name = NSStringFromClass([self class]);
        if (MVBIsSystemClassName(name)) return;
        // 排除键盘/选择器这类弹出的辅助控制器
        if ([name containsString:@"Keyboard"] || [name containsString:@"Picker"]) return;
        NSString *ctx = MVBContextForClassName(name);
        // v1.3.1: 类名认不出 -> 再用「页面标题」认一次 (新建文件夹/搜索/最近删除/设置
        // 这些页面的标题很明确), 仍认不出 -> 看它是不是「被 present 出来的操作面板」。
        // 三层判定叠加, 系统换私有类名也不会漏。
        if (!ctx) ctx = MVBDetectNotesContext(self, nil);
        [[MVBManager shared] logClassOnce:name context:ctx ?: @"(未识别)"];
        // v1.2.0: 认不出类名时不再「直接放弃」。以前 return 掉 -> 只要类名清单漏了
        // 某个系统版本, 那个界面就整页毫无反应 (用户反馈「其他界面全都不生效」)。
        // v1.3.1: 兜底顺序改成「模态操作面板 -> 多多创新」优先于「有列表 -> n_all」。
        // 「新建文件夹」这类面板本来就是被 present 出来的, 判成多多创新才对;
        // 判成 n_all 会拿「根目录排序第一」那支素材, 看起来就像「显示的是首页的视频」。
        if (!ctx) {
            if (MVBIsPresentedPanel(self)) ctx = MVBContextInnovate;
            else if (MVBViewHostsScrollable(self.view, 0)) ctx = MVBContextAll;
            else return;
        }
        // 只对「视图里真的承载着列表/滚动容器」的 VC 生效 —— 纯容器 VC 上插背景
        // 会被上层白底内容盖住, 白费功夫。
        // v1.2.0: 原来要求 self.view 本身必须是 UITableView/UICollectionView,
        // 但备忘录的文件夹页/笔记列表页, self.view 是普通容器 (真列表是子视图),
        // 于是被这条直接挡掉 -> 这些界面永远没背景。改为「子树里含有列表」即可,
        // 既能覆盖真实页面, 又不会给纯容器重复挂背景。
        // v1.3.1: 首页/笔记/多多创新三者豁免 (前两者本来就在白名单, 操作面板常常
        // 只是几个静态行, 没有滚动容器, 不能因此判它「不值得挂背景」)。
        if (![ctx isEqualToString:MVBContextHome] &&
            ![ctx isEqualToString:MVBContextNote] &&
            ![ctx isEqualToString:MVBContextInnovate] &&
            ![self.view isKindOfClass:[UITableView class]] &&
            ![self.view isKindOfClass:[UICollectionView class]] &&
            !MVBViewHostsScrollable(self.view, 0)) return;
        MVBApplyPage(self, ctx);
    } @catch (NSException *e) {
        // 保证不崩溃
    }
}
// v1.2.0: 兜底再补一道 viewDidAppear —— 只在 viewWillAppear 那条路没挂上时动手
// (有些页面是 push 后才建好视图 / 类名与显式 hook 不符, 只在 willAppear 里做会漏)。
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    MVB_NOTES_GUARD()
    @try {
        if ([[MVBManager shared] appliedContextForViewController:self].length) return;
        NSString *name = NSStringFromClass([self class]);
        if (MVBIsSystemClassName(name)) return;
        if ([name containsString:@"Keyboard"] || [name containsString:@"Picker"]) return;
        NSString *ctx = MVBContextForClassName(name);
        if (!ctx) ctx = MVBDetectNotesContext(self, nil);          // v1.3.1: 标题兜底
        if (!ctx) {
            if (MVBIsPresentedPanel(self)) ctx = MVBContextInnovate;  // v1.3.1: 模态面板
            else if (MVBViewHostsScrollable(self.view, 0)) ctx = MVBContextAll;
            else return;
        }
        if (![ctx isEqualToString:MVBContextHome] &&
            ![ctx isEqualToString:MVBContextNote] &&
            ![ctx isEqualToString:MVBContextInnovate] &&
            !MVBViewHostsScrollable(self.view, 0)) return;
        MVBApplyPage(self, ctx);
        // v1.3.4: 页面真正出现 (动画结束 + 视图稳态) 时再算一次「谁被盖住」并重连播放器。
        // setSuspended:NO 内部会 reconnectPlayerForce, 解决「退出面板后主页一片白 /
        // 视频不见」(setSuspended 之前算的 covered 可能还是 YES)。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                [[MVBManager shared] refreshCoveredBackgrounds];
                NSString *applied = [[MVBManager shared] appliedContextForViewController:self];
                if (applied.length) [[MVBManager shared] setContextActive:YES context:applied];
            } @catch (NSException *e) {}
        });
    } @catch (NSException *e) {}
}
// 只走兜底路径的页面离开时也要暂停自己的播放器, 防声音穿透到其它界面。
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    MVB_NOTES_GUARD()
    @try {
        NSString *applied = [[MVBManager shared] appliedContextForViewController:self];
        if (applied.length)
            [[MVBManager shared] setContextActive:NO context:applied];
    } @catch (NSException *e) {}
}
%end

// v1.7.21: 分区背景装饰视图 —— 分组白卡其实是 compositional list layout 的
// section 背景装饰 (报告实锤: _UICollectionViewListLayoutSectionBackgroundColorDecorationView)。
// 系统在布局失效时会反复重新赋色 (点选单元格/滚动都会触发) —— 钩它的
// setBackgroundColor:, 系统每铺一次白我就地改回透明, 事件驱动、零布局干扰。
// (装饰视图不是 cell, 改它的颜色不走 cell 背景变更流程, 安全。)
@interface _UICollectionViewListLayoutSectionBackgroundColorDecorationView : UIView @end
%hook _UICollectionViewListLayoutSectionBackgroundColorDecorationView
- (void)setBackgroundColor:(UIColor *)color {
    %orig;
    @try {
        if (!MVBIsNotesProcess()) return;
        if (!MVBMainSweepActive()) return;
        if (color && ![color isEqual:[UIColor clearColor]])
            %orig([UIColor clearColor]);
    } @catch (NSException *e) {}
}
%end

// ------------------------------------------------------------------
// v1.8.5: App 名称自定义 —— installd/SpringBoard 会缓存 Info.plist 的显示名,
// 改 plist + 注销根本不刷新 (用户实测)。改从「显示层」钩:
// SpringBoard 里 SBApplication.displayName 就是桌面图标下的名字, 读我们的
// 配置 (app_display_name, 控制App 双通道写盘) 直接替换, 即存即显、注销也不丢。
// ------------------------------------------------------------------
@interface SBApplication : NSObject
- (NSString *)bundleIdentifier;
@end
%hook SBApplication
- (NSString *)displayName {
    NSString *orig = %orig;
    @try {
        if ([[self bundleIdentifier] isEqualToString:@"com.nvb.memosvideobg.app"]) {
            // v10.4.0g: 5 秒缓存 —— 桌面摆图标/切页会高频调 displayName,
            // 不缓存就是每次都开 NSUserDefaults 读盘, 桌面主线程被我们拖累
            static NSString *cached = nil;
            static CFAbsoluteTime last = 0;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (!cached || now - last > 5.0) {
                last = now;
                cached = [[MVBManager shared] appDisplayName] ?: @"";
            }
            if (cached.length) return cached;
        }
    } @catch (NSException *e) {}
    return orig;
}
%end

// ------------------------------------------------------------------
// 插件入口: 写心跳 + 挂横幅 + 注册 Darwin 通知
// 这段在「任何被注入的进程」里都会跑 (备忘录App / SpringBoard)
// ------------------------------------------------------------------
%ctor {
    @autoreleasepool {   // 早期加载时主线程还没有 autorelease pool
        @try {
            NSString *proc = NSProcessInfo.processInfo.processName ?: @"?";
            BOOL isSB = [proc isEqualToString:@"SpringBoard"];

            // SpringBoard (桌面) 崩溃 = 全机安全模式, 桌面侧零文件 IO ——
            // 心跳/日志只在宿主 App 里写, 桌面只保留 displayName 钩子
            // SpringBoard 只用 displayName 钩子, 不做素材迁移/诊断横幅 (防干扰桌面启动)
            if (!isSB) {
                [[MVBManager shared] writeHeartbeat:
                    [NSString stringWithFormat:@"tweak 已注入 %@", proc]];
                [[MVBManager shared] log:@"=== MemosVideoBG v%@ tweak loaded in %@ ===",
                    MVB_VERSION, proc];
                // 自愈迁移: 把 jbroot 等其它可读根里的旧素材搬进主根 (备忘录App 容器)
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    [[MVBManager shared] migrateMediaIntoPrimaryRoot];
                    // v10.4.0: 旧名杂项改名/过期诊断日志删除/界面子目录摊平
                    MVBCleanupHousekeeping();
                });

                CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                                NULL,
                                                MVBPrefsChanged,
                                                CFSTR(MVB_DARWIN_NOTE),
                                                NULL,
                                                CFNotificationSuspensionBehaviorDeliverImmediately);

                // v10.4.0f: 素材热刷新看门狗 —— Darwin 通知在宿主挂起/直接改文件时
                // 到不了, 换素材只能靠注销才生效; 这里 2 秒一检兜底
                [[MVBManager shared] startMediaWatchdog];

                // v9.9.11: 前后台自愈 —— 后台暂停、回前台重连显示管线并续播
                // (AVPlayerLayer 的内容会被系统回收, 光 play 不重绘 -> 卡在最后一帧)
                // 顺带监听音频中断结束 (来电/闹钟后自动续播)
                @try {
                    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
                    MVBManager *m = [MVBManager shared];
                    [nc addObserver:m selector:@selector(handleAppEnterBackground)
                               name:UIApplicationDidEnterBackgroundNotification object:nil];
                    [nc addObserver:m selector:@selector(handleAppWillEnterForeground)
                               name:UIApplicationWillEnterForegroundNotification object:nil];
                    [nc addObserver:m selector:@selector(handleAppDidBecomeActive)
                               name:UIApplicationDidBecomeActiveNotification object:nil];
                    [nc addObserver:m selector:@selector(handleAudioInterruption:)
                               name:AVAudioSessionInterruptionNotification object:nil];
                } @catch (NSException *e) {}

                // 等宿主 App 窗口就绪后挂一次「注入确认」横幅。
                // v1.2.0: 原来是每 2 秒重刷 10 次, 且固定用兜底语境 MVBContextAll ——
                // 结果用户刚进某个界面时横幅先显示真实界面名, 一两秒后被刷成 n_all,
                // 诊断时永远看到「界面[n_all] 开关=关」, 完全是误导 (用户实测反馈)。
                // 现在只补一次, 且不覆盖已经由页面 hook 写好的真实语境。
                @try {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(2.0 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        @try {
                            NSString *cur = [[MVBManager shared] currentContext];
                            if (!cur.length) MVBRefreshBanner(MVBContextAll);
                        } @catch (NSException *e) {}
                    });
                } @catch (NSException *e) {}
            }
        } @catch (NSException *e) {}
    }
}
