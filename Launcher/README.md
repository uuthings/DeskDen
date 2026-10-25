# 方寸 · 开发指南

方寸使用 AppKit、SwiftUI 和本地 `LauncherCore` Swift Package，最低运行版本为 macOS 14。当前源码构建与 CI 使用 Xcode 27.0（Swift 6.4）；Package 的 Swift 6.0 语言模式不表示旧 SDK 能编译全部原生界面。Xcode 工程负责生成 macOS App，Swift Package 支持核心测试与本地开发构建。

## 构建

在项目根目录打开 `Fangcun.xcodeproj`，选择 `Fangcun` scheme。也可以执行：

```sh
xcodebuild -project Fangcun.xcodeproj -scheme Fangcun \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/XcodeDerived build CODE_SIGN_IDENTITY=-
```

在 `Launcher/` 内运行 `./scripts/build-local.sh`，生成位于 `build/` 的本地开发 App。脚本拒绝覆盖已有输出或证据目录；可传入新的绝对输出路径与 `debug`／`release` 配置。它使用 ad-hoc 签名，检查源码和资源指纹并保存证据，不上传、不公证。首次构建会解析固定版本的 Sparkle，脚本将框架及必要辅助程序一并放入 App。正式分发见 [发布流程](../docs/releasing.md)，更新通道说明见 [软件更新](../docs/updating.md)。

不要同时运行同 Bundle ID 的多个构建：后启动的实例会唤起已有实例。

## 验证

先正常退出正在运行的方寸，再在 `Launcher/` 运行：

```sh
./scripts/verify-local.sh
```

验证包含核心测试、分别记录的 Debug／Release 原生检查、设备与表单专项，以及设备监测、日历、私密空间和 AI 模型检查。每轮在 `build/verification/` 创建独立证据目录，要求正数检查计数、零失败、零跳过，并核对整轮源码输入保持一致。

原生界面检查需要活动的 macOS 图形会话及测试宿主已有的辅助功能访问。检查模式使用公开 API 只读查询自身窗口，让 SwiftUI 生成可测量的动态界面信息；系统拒绝时会明确失败，不申请权限或跳过断言。正常使用 App 沿用系统的辅助功能状态。

历史设计稿保留在维护者本机。需要一并核对原始指纹时，显式运行 `./scripts/verify-local.sh --verify-preserved-designs`，该选项要求本机历史存档完整。公开源码构建与功能验证不依赖私人设计记录。

自动检查使用临时数据与夹具，不代表已经验证个人账号、系统授权或所有硬件场景；视觉与系统窗口行为还需要启动真实 App 检查。正式版本的签名、公证和完整归档遵循 [发布流程](../docs/releasing.md)，实际结果以对应 Release 与归档证据为准。

## 空间清理

独立的「空间清理」导航提供全局／自定义扫描、默认勾选的可重建建议、直接清理、测试用途确认、废纸篓／永久删除与历史恢复。规则、事务边界和专项验证入口见 [空间清理](../docs/space-cleaning.md)。

大文件模式支持大小上下限，默认零勾选；开发依赖与版本资料在两种模式中均受保护。纯后台清理模型回归可运行开发可执行文件的 `--space-cleaning-model-check`，使用临时夹具与注入的废纸篓，不创建窗口、不扫描个人目录。它不替代原生界面验收。

顶部 Mini 复用日期天气、日程待办、本机状态与 AI 额度，右上配置与通用设置共用显隐偏好。`--mini-data-check` 使用注入来源验证时区、缺失值与有界读取；`--mini-appearance-check` 仅在隐藏原生窗口验证紧凑排版、刘海避让与配置入口，可通过 `FANGCUN_MINI_OUTPUT` 指定夹具图片目录。两者均不代替真实悬停与前台窗口验收。

城市、天气单位、时区与时间格式共用设置；`--context-model-check` 使用独立存储与注入的天气来源做后台回归，`--appearance-check` 只在隐藏窗口渲染材质和界面夹具，不替代前台交互验收。

网络与 AI 的近期明细、月度汇总、缓存和保存策略见 [历史记录与长期运行](../docs/history-storage.md)。

## 图标与窗口

「设置 → 外观与材质」提供青碧晨雾、月白云海、暖霞悬山三款图标；默认青碧晨雾。已采用的源 PNG 位于 `Artwork/AppIcons/`，通过 `scripts/prepare-app-icons.swift` 生成生产 ICNS，转换来源和校验值保存在同目录元数据中。

工作台显示时提供程序坞与应用切换入口，最小化保留恢复方式，关闭后收起界面并继续后台运行。全屏侧栏随宽度适量增长并设置上限；窗口模式、关闭／重开和系统 Space 行为需要结合真实 App 验证。

## 提交前检查

在根目录执行：

```sh
./tools/install-hooks.sh
python3 tools/check-public-scope.py --staged
python3 tools/test-public-scope.py
```

检查读取 Git 索引中的实际 blob，验证公开范围、资源类型、机器私有路径与固定版本 Gitleaks。提交标题使用英文 Conventional Commits，保留既有 Git 身份并将提交元数据纳入历史隐私检查，不自动修改身份。推送前 hook 检查拟推送引用及全部祖先，CI 额外检查所有可达历史。

公开范围与发布证据要求见 [公开范围说明](../docs/public-source.md)。

## 按钮指针

按钮、导航与可点击选项默认使用小手指针，可在「设置 → 通用 → 操作反馈 → 按钮悬停指针」切换为箭头。偏好即时应用并保存；禁用控件、文本输入、拖动与缩放保留各自的指针行为。
