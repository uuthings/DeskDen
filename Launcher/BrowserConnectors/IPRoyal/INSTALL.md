# DeskDen IPRoyal Connector

Optional Chrome connector for DeskDen on macOS. Requires DeskDen 0.3.0 or later and Google Chrome. This package is not a Chrome Web Store installation.

## 安装

1. 先安装 DeskDen（方寸）。将本连接包解压到准备长期保留的目录，例如「文稿 / DeskDen Connectors」；不要直接从 ZIP 或临时目录使用。
2. 双击 `install.command`，选择已安装的方寸 App，阅读说明后输入 `INSTALL`。本机连接配置此时才会生成，不需要管理员权限。若系统要求确认脚本来源，请核对本包来自 DeskDen 官方 Release。
3. 在 Chrome 打开 `chrome://extensions`，启用「开发者模式」，点击「加载已解压的扩展程序」，选择本包的 `Extension` 文件夹。
4. 在 Chrome 自行登录 IPRoyal，然后在扩展弹窗点击「启用连接」。账号、密码、验证码和登录会话均留在浏览器。
5. 在方寸「用量与额度」添加 IPRoyal 来源、填写订单编号并刷新。查询的是服务商额度，可能存在统计延迟，不是实时网速。

移动 App 后重新运行安装程序；移动本连接包后，在 Chrome 重新加载新位置的 `Extension` 文件夹。正在使用时请保留扩展文件。

## 包含与权限

本包仅包含通用扩展、安装脚本和说明，没有订单号、账户配置、登录会话、机器路径或本机宿主注册文件。安装脚本只在当前用户的应用支持目录建立本机连接，不修改 VPN、代理规则或 IPRoyal 账户。

扩展仅请求 IPRoyal 控制台访问权限和本机通信等运行所需权限；不请求读取 Cookie、浏览器登录数据库、密码或认证 Token。订单号由方寸本机配置在查询时提供。

## 移除

在 Chrome 移除扩展后，可删除当前用户 `Library/Application Support/Google/Chrome/NativeMessagingHosts/com.uuthings.deskden.iproyal.json` 和 `Library/Application Support/DeskDen/Connectors/IPRoyal` 下的本机组件，再删除本连接包。不会删除方寸资料或影响 IPRoyal 账户。

Source and details: https://github.com/uuthings/DeskDen/tree/main/Launcher/BrowserConnectors/IPRoyal
