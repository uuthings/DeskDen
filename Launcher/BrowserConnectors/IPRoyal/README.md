# 方寸 IPRoyal 网页助手

此连接器将 IPRoyal **静态 ISP 订单**的总额度、已用量、余额和原始重置日期同步到本机方寸。只支持 Google Chrome。方寸控制查询周期和流量触发阈值，助手不自行轮询服务商额度。

## 安装与连接

1. 将方寸 App 放在准备长期使用的位置，在用量统计中导出连接包。将连接包保存在持久目录，不要放入临时目录。
2. 双击连接包的 `install.command`，阅读说明，输入 `INSTALL` 注册当前用户的本机连接文件。此操作由用户本人执行。
3. 打开 Chrome 的扩展管理页，启用开发者模式，选择“加载已解压的扩展程序”，选择连接包的 `Extension` 文件夹。确认只请求 IPRoyal 控制台网站的访问权限。
4. 在 Chrome 中自行登录 IPRoyal。已有 Google 登录可以继续使用；方寸和助手不会处理 Google 页面。
5. 打开助手弹窗，选择“启用连接”。在方寸添加 IPRoyal 来源，填写订单编号，点击刷新。

只有用户执行安装步骤后才会建立连接。导出连接包不会注册本机宿主、安装扩展或自动授予权限。移动连接包后，在新位置重新运行 `install.command`，并在 Chrome 扩展管理页重新加载新位置的 `Extension` 文件夹。移动 App 后须重新导出连接包并注册。不要删除仍在使用的连接包或配套 App。

## 数据范围

- 扩展的网站权限仅为 `https://dashboard.iproyal.com/*`，内容脚本仅匹配订单页、仅顶层文档。
- 不请求 cookies、debugger、webRequest、全部网站或 Google 访问权限，不读取浏览器数据库、本地存储中的登录数据、请求头、密码或认证 Token。HTTP 429 时仅额外读取响应的 `Retry-After`，转换为最多 7 天的等待秒数；不传递原始响应头。
- MAIN 世界脚本仅观察页面原有的 `GET https://apid.iproyal.com/v1/orders/{订单编号}` 和对应 `/data-usage` 响应，不主动构造认证请求。
- 只输出 `remaining.gb_limit`、`remaining.gb_used`、`remaining.gb_balance`、`bandwidth_limit_reset_at` 白名单字段及请求关联标识。原始响应不进入本机通信或日志。
- 文本/Fetch 响应最多读取 64 KiB；XHR 已解析的 JSON 仅访问上述有界字段，不遍历或重新序列化其余响应。跨进程消息最多 16 KiB；检查来源、顶层 frame、文档 ID、文档代次、订单编号、数据类型、数值范围和额度一致性。
- 请求期间仅创建一个不激活的助手自有订单标签页，正常完成或 45 秒超时后关闭。用户切到该标签页时停止本次查询并交还标签页，不关闭用户已有标签页。
- 页面脚本提供的读数不是服务商签名证明。网页本身或同站脚本遭修改时，读数可能不可信；它不能用于执行付款、变更服务或授权操作。

网页请求正常加载时自动获取该订单。退出登录、页面没有返回额度、用户关闭页面、宿主断线都保留方寸旧读数并提示重连，不以零替代未知值。余额为服务商值，本机流量仅用于触发刷新，不能从余额中直接扣除。历史用量可能延迟；“查询时间”不代表服务商统计已覆盖该时刻。

重置字段暂按原始日期保存。日期没有经过时区确认时，不转换为 UTC 午夜或倒计时，避免日期偏移一天。

## 本机通信与移除

稳定扩展 ID：`dbgielekmbgphidnnfidmlobjmdblagf`。manifest 的 key 是公开的扩展身份公钥，不是服务商密钥。

Native Messaging 宿主为 `com.uuthings.fangcun.iproyal`，只接受该扩展来源；由导出包内包装程序启动方寸的独立宿主模式。只有字段白名单消息通过本机标准输入/输出。App 与宿主使用用户私有目录（0700）和原子消息文件（0600），拒绝符号链接、跨用户文件、超大消息及过期响应。

关闭助手弹窗中的连接可停止工作；也可在 Chrome 移除扩展。需要移除本机注册时，用户可删除 `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.uuthings.fangcun.iproyal.json`，随后删除不再使用的连接包。不会影响 IPRoyal 账户。

## 开发验证与限制

`node --test tests/*.test.cjs` 验证白名单解析、来源/文档关联、过大响应、错误方法、错误订单和后台标签页生命周期。Swift 核心测试验证消息校验与受限邮箱协议。测试仅使用构造数据，不安装扩展、不注册 Native Messaging、不读取真实登录状态。

真实 Chrome 扩展安装、权限确认、已有登录会话、Google 登录跳转及服务商页面联调须由用户完成安装后验收。自动化模拟通过不等于这些项目已验证。控制台内部接口可能变化，当前实现不会退化为读取认证信息或任意请求。

Chrome 官方机制：[内容脚本](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts)、[Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)。
