# 备忘录视频背景 (MemosVideoBG)

给苹果「备忘录」App 挂视频背景的越狱插件。作者：板栗仁。

架构完全沿用「信息视频背景 (SMSVideoBG)」的成熟方案，宿主换成 `com.apple.mobilenotes`。

## 支持的界面（7 类，各自独立开关）

| 界面 | 说明 |
|---|---|
| 首页 | 打开备忘录的第一屏（文件夹列表） |
| 文件夹 | 点进某个文件夹后的笔记列表 |
| 笔记 | 点进某条笔记后的正文界面 |
| 搜索一下 | 搜索框点进去后的搜索界面 |
| 最近删除 | 最近删除列表 |
| 多多创新 | 新建文件夹 / 新建笔记的操作面板 |
| 内部页 | 更多设置等内部子页面 |

全局可调：总开关 / 透明度 / 模糊度 / 音量（默认关闭，不抢音频焦点）。

## 素材

所有界面共用同一个文件夹：

```
/var/mobile/备忘录视频背景/板栗仁/
```

用 Filza 把视频直接丢进去即可，每个界面自己记住选了哪个文件和效果。
这个路径是软链，真实文件躺在备忘录 App 的数据容器里（沙盒进程只能读容器）。

## 构建

Windows 环境本地无法编译 Theos（arm64e 切片必须用 macOS 的 Apple 原生工具链），
因此走 GitHub Actions：

- Workflow: `.github/workflows/build.yml`
- 触发: push 到 main / 手动 workflow_dispatch
- 产物: `MemosVideoBG-deb` artifact（含 `.deb`）

### 授权密钥（可选但建议）

授权走纯离线授权串。签发密钥通过仓库 Secret 注入：

```
Settings -> Secrets and variables -> Actions -> New repository secret
名字: MVB_LICENSE_SECRET
```

未配置时用源码里的兜底密钥编译（仅供自测，无法防盗版）。

签发工具在 `keygen/`（独立 App「授权签发」）。

## 目录

```
MVBCommon.h/.m    共享核心（配置 / 素材 / 播放器 / 背景视图 / 诊断）
MVBAuth.h/.m      离线授权模块（UDID 绑定 + HMAC 验签）
Tweak.x           插件钩子（备忘录 IC* 私有类）
app/              控制 App「备忘录视频背景」
keygen/           授权签发 App（作者用）
layout/           deb 安装脚本
tools/            打包检查工具
```

## 版本

- v1.0.0 —— 首个独立版本：7 类界面、白卡对抗、防串音、前后台自愈、诊断报告
