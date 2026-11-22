# MyTool

将 MyScreen、MyClip、MyActive 聚合为一个原生 macOS 应用。只安装 `MyTool.app`；打开后展示子应用图标，点击图标打开各自窗口。MyScreen 保留控制面板，MyClip 保留底部浮动剪贴板面板，MyActive 提供保持唤醒控制窗口。所有功能编译进同一个可执行文件、运行在同一个进程中。

需要 macOS 14+、Xcode 16+ / Swift 6。当前构建默认针对本机架构，无第三方依赖。

## 构建与运行

```sh
./Scripts/build.sh
open dist/MyTool.app
```

也可使用 `make run`。构建不依赖相邻的 `myscreen`、`myclip` 目录，源码和图标已迁入本项目；原项目不做修改。

将 `dist/MyTool.app` 拖入「应用程序」文件夹即可安装。首次切换时先退出独立版 MyScreen / MyClip，并关闭它们各自的登录启动，再开启 MyTool 的登录启动。检测到独立版仍运行时，对应模块会显示原因，退出旧版后点击卡片重试即可。

MyTool 使用新的应用标识 `dev.daodao.MyTool`。请在「系统设置 → 隐私与安全性 → 辅助功能」中为 **MyTool** 开启权限一次，原来授予 MyScreen / MyClip 的权限不会自动继承。MyScreen 的窗口操作与 MyClip 的自动粘贴共用这份授权。

构建会复用 `.codesign-identity.local` 中的签名身份，否则尝试选择本机开发证书；也可通过 `CODE_SIGN_IDENTITY` 指定。无证书时使用 ad-hoc 签名，重建后可能需要重新授权。当前产物用于本机；对外分发需要 Developer ID 签名与公证。

## 使用

- MyTool 主页或菜单栏中打开任意子应用，重复打开会复用现有窗口。
- MyScreen 默认 `⌥R` 进入窗口模式；MyClip 默认 `⇧⌘V` 呼出面板，迁移后优先沿用原有快捷键。
- 关闭主页或子应用窗口后，窗口管理和剪贴板记录继续运行；通过「退出 MyTool」或 `⌘Q` 一起退出。
- 「MyTool → 设置」统一管理菜单栏、Dock 和登录启动。两个图标都隐藏后，可通过 Spotlight 或再次打开应用回到主页。
- 「窗口」菜单提供主页和子应用入口；默认 `⌘1` 打开主页，`⌘2` 打开 MyScreen，`⌘3` 打开 MyClip，`⌘4` 打开 MyActive。
- 从主页打开 MyClip 后，自动粘贴会尝试返回最近使用的外部应用；目标已退出或未激活成功时只复制，不发送粘贴按键。

## 数据迁移

每个模块首次成功启动前，复制对应独立版的数据到专属目录：

| 独立版 | MyTool 中的位置 |
| --- | --- |
| `~/Library/Application Support/MyScreen/` | `~/Library/Application Support/MyTool/MyScreen/` |
| `~/Library/Application Support/MyClip/` | `~/Library/Application Support/MyTool/MyClip/` |

包含剪贴板历史、图片、窗口布局及备份。复制使用临时目录，全部完成后才将目录放到正式位置；复制失败可重试。原目录保留，后续启动不覆盖 MyTool 已有数据，也不会持续同步独立版的数据。

原有 UserDefaults 复制一次到 `dev.daodao.MyTool.MyScreen`、`dev.daodao.MyTool.MyClip`，模块间相互隔离。宿主的 Dock、菜单栏和登录启动设置由 MyTool 自己管理。

数据全部保存在本机，不联网。MyScreen 会保存窗口标题、应用标识、文档标识和坐标；MyClip 会保存记录的剪贴板内容。剪贴板历史读取失败时暂停模块启动，保留文件和图片并在主页显示错误。

## JSON 剪贴板

复制 JSON 对象或数组后，卡片自动展示字段摘要。点击卡片上的 `{}` 按钮，或选中卡片按 `⌃空格`，进入 JSON 预览：

- 树形展示区分字符串、数字、布尔值、null、对象和数组，可逐层折叠，或全部展开 / 折叠。
- 在「键 / 值」中查找内容；「模糊」按字符顺序匹配，例如 `alw` 可找到 `Alice Wang`。
- 「Node Path」按路径定位节点，自动展开上级并突出匹配项；上下按钮或搜索框中的回车切换匹配项，`⌘F` 聚焦节点搜索。
- 选中或右键节点，可复制节点值、节点 JSON、Node Path、JSON Pointer 或键名。字符串的「节点值」不带引号，「节点 JSON」包含 JSON 引号和转义。
- 可切换树形 / 格式化 / 原文，并复制完整原文、格式化或压缩 JSON。复制预览内容不会关闭面板或改变当前历史顺序。

路径示例：

| 写法 | 含义 |
| --- | --- |
| `$.users[0].name` 或 `users.0.name` | 数组第一个元素的 name |
| `$.users[*].name` | 每个元素的 name |
| `$..name` | 任意层级的 name 字段 |
| `$["a.b"][""]` | 带点号的键及空键名 |
| `/users/0/name` | JSON Pointer；键中的 `/`、`~` 分别转义为 `~1`、`~0` |

路径区分大小写，支持字段、数组下标、通配符、递归字段与 JSON Pointer，不支持 JSONPath 筛选表达式和切片。剪贴板顶部主搜索中也可以输入 `path:$.users[*].name`，筛选包含该节点的历史记录。主搜索旁可直接切换精确、模糊、正则和混合搜索。

JSON 解析和路径搜索在后台执行，并复用有限大小的缓存。保留字段顺序、重复键和数字原文，长整数和高精度小数不会经过浮点转换。每次最多处理 4 MiB、50,000 个节点和 128 层；超限或无效内容保留原文预览。树形每批展示 500 行，可继续加载；文本视图最多展示前 100,000 个字符，复制始终包含完整内容。

## MyActive 保持唤醒

参考 [Amphetamine](https://apps.apple.com/us/app/amphetamine/id937984704) 的手动会话、定时会话和电源结束条件，MyActive 在 MyTool 内提供独立控制窗口；通过主页、统一菜单栏或 `⌘4` 打开。

- **屏幕常亮**：防止因用户无操作导致的自动熄屏和系统休眠，适合阅读、演示、会议。
- **仅保持系统运行**：允许屏幕按系统设置熄灭，后台任务继续运行。
- 支持不限时、15 / 30 分钟、1 / 2 / 4 小时、自定义 1–1440 分钟，以及指定结束日期和时间。
- 会话可暂停、继续、延长 15 分钟或立即结束。倒计时在暂停期间停止计时；指定结束时间在暂停期间仍然有效。
- 默认开启低电量保护（电池供电且电量不高于 20% 时结束），阈值可调；可选仅在连接电源时运行，拔电源后立即结束。
- 默认在锁屏或切换用户时结束，可在窗口中关闭此选项。手动睡眠和合盖继续遵循 macOS 行为，本次会话在收到系统睡眠通知时结束。
- 主页显示「未开启 / 屏幕常亮 / 仅保持系统运行 / 已暂停」状态。保持唤醒时，MyTool 菜单栏图标变为实心，悬停可查看状态，菜单内可快速开始、暂停、继续或结束。

MyActive 无需辅助功能权限。每次启动 MyTool 后，保持唤醒默认处于未开启状态，由用户手动开始；模式、电量和锁屏选项保存在 `dev.daodao.MyTool.MyActive`。关闭窗口后会话继续；结束会话、退出 MyTool 时释放本应用创建的电源断言，恢复系统原有休眠行为。

实现使用 Apple 的 [IOPMAssertionCreateWithProperties](https://developer.apple.com/documentation/iokit/1557082-iopmassertioncreatewithpropertie)。定时会话设置系统断言超时，并通过独立队列上的到期计时器释放断言。倒计时使用单调时钟，指定结束时间跟随系统时间调整；没有会话时不运行每秒计时器。电源状态通过系统通知更新。

## 接入更多子应用

1. 在 `Sources/` 下新增 Swift target，依赖 `MyToolKit`，并在 `Package.swift` 中让 `MyTool` 依赖该 target。
2. 实现 `ToolModule`，提供唯一的 `descriptor.id`、名称、简介和图标符号。
3. `start()` 启动后台能力；`open()` 显示或复用独立窗口；`willTerminate()` 清理监听。需要菜单操作时实现 `makeMenu()`。
4. 在 `Sources/MyTool/MyToolApp.swift` 的模块列表中注册实例，主页和菜单会自动增加入口。
5. 如需自定义图标，将 `<名称>.icns` 放入 `Resources/`；没有图标文件时使用描述中的 SF Symbol。

子应用通过 `HostContext` 返回主页、打开统一设置或获取最近使用的外部应用。模块内部不创建 `NSApplication`、不设置应用代理、不独立注册登录启动、不创建额外 Dock / 菜单栏入口，也不调用 `NSApp.terminate`。全应用生命周期由宿主管理。

当前采用编译期模块，增加工具后重新构建一个 MyTool 即可。

## 验证

```sh
./Scripts/swift.sh test
./Scripts/smoke-ui.sh
```

单元测试覆盖原 MyScreen 的布局、恢复、窗口匹配、拖动与缩放行为，以及模块注册、状态发布、单次启动、错误隔离、重试、数据迁移、JSON 解析、路径匹配和折叠上下文。MyActive 覆盖倒计时、固定结束时间、时钟调整、暂停继续、模式替换、失败回滚、电源与锁屏结束条件。

原生电源测试默认跳过，明确设置环境变量后会短暂创建真实断言，验证两种模式、到期释放与重复清理：

```sh
MYACTIVE_NATIVE_TESTS=1 ./Scripts/swift.sh test
```

`Scripts/swift.sh` 将缓存放在项目内，并选择当前 Xcode 对应 SDK，避免继承不匹配的 `SDKROOT`。

UI 冒烟检查使用 Debug 构建，将主页、设置、MyScreen 的三个页面、MyClip 设置、浮动面板、JSON 预览及 MyActive 的未开启 / 运行 / 暂停三种状态渲染到 `dist/qa/`。该模式使用临时数据目录，不启动窗口管理、全局快捷键或剪贴板轮询，不请求辅助功能权限；JSON 示例不写入真实剪贴板，MyActive 使用模拟断言。Release 不包含这些预览入口。

实际辅助功能授权、跨应用粘贴、物理显示器拔插恢复和登录启动仍需在安装位置人工验收。
