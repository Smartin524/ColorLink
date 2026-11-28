# ColorLink Windows 端

和 Mac 端功能对等的 Windows 托盘程序，协议与 [PROTOCOL.md](../PROTOCOL.md) 完全一致，**手机端不用改**（可以同时连 Mac 和 Windows，手机按电脑名区分）。

- C# / .NET 10 + WinUI 3（Windows App SDK 2.7），不打 MSIX 包，exe 直接运行；运行库随程序带上，不用另装
- 界面：托盘面板用 Acrylic（毛玻璃），相册、配对、播放窗口用 Mica
- 支持 Windows 10 2004（19041）及以上，Windows 11 效果最好

```
windows/
├── src/ColorLink.Core      与界面无关：协议客户端、证书固定、敲门、mDNS、相册同步、连接状态机（对应 Mac 的 ColorLinkCore + LinkController）
├── src/ColorLink.App       WinUI 3 托盘程序
├── tools/clcheck           命令行联调工具（对应 Mac 的 clcheck）
├── tools/make-icons.py     生成应用图标和托盘单色图标
└── tests/                  单元测试（验证码识别、敲门签名、事件解析、文件名清理）
```

## 和 Mac 端的对应

| Mac | Windows |
|---|---|
| 状态栏图标 + 液态玻璃面板 | 托盘图标（左键面板、右键菜单）+ Acrylic 面板，任务栏深浅色自动换图标 |
| 拖文件时面板自动弹出 | 拖到面板或相册窗口；资源管理器右键 **「发送到 → ColorLink 手机」**；菜单里「发送文件到手机…」 |
| Bonjour（NWBrowser） | Zeroconf 定时查询（没找到 4 秒一次，找到后 20 秒一次；网络变化时立刻查） |
| URLSession + 证书指纹 | HttpClient（SocketsHttpHandler）+ 同样的 SHA-256 指纹固定 |
| AVPlayer + 本机转发 | MediaPlayerElement + 同样的 127.0.0.1 转发（随机路径） |
| 令牌存 UserDefaults | 令牌用 DPAPI 加密后存 `%LOCALAPPDATA%\ColorLink\paired.json` |
| CoreBluetooth 广播 | GATT 服务广播同一个 UUID（电脑蓝牙不支持外围设备角色时跳过） |
| 锁屏 / 睡眠断开 | SessionSwitch / PowerModeChanged，同样的暂停逻辑 |
| 登录项 | `HKCU\...\Run`（首次运行默认打开，菜单里可关） |
| 通知 | Windows 通知中心（AppNotification），点通知在资源管理器里显示文件 |

文件位置：

- 保存的照片、截图、手机分享的文件：`文档\Colorlink`
- 相册列表和缩略图：`%LOCALAPPDATA%\ColorLink\Phones\<手机 ID>`
- 日志：`%LOCALAPPDATA%\ColorLink\Logs\colorlink.log`（「导出诊断日志」会一起导出手机日志）

## 编译和运行

需要 .NET 10 SDK。

```powershell
cd windows
dotnet build src/ColorLink.App
.\src\ColorLink.App\bin\Debug\net10.0-windows10.0.22621.0\win-x64\ColorLink.exe
```

第一次运行时 Windows 防火墙会问是否允许 ColorLink 访问网络，要点「允许」：手机醒来时会往电脑的 UDP 8766 发“敲门”包，被挡住的话只能靠 mDNS 和定时重试，重连会慢。

发布成单个文件夹（可以拷到别的电脑）：

```powershell
dotnet publish src/ColorLink.App -c Release -r win-x64 -o publish
```

启动参数：`--background`（开机自启用，不弹窗）、`--send 文件…`（「发送到」用）。程序只运行一份，再次启动会把参数交给正在运行的那份。

## 没有手机时：Windows + 模拟手机

模拟手机在 Windows 上需要几个 pip 包（Mac 上不用）：

```powershell
pip install pillow zeroconf cryptography
python mock/mock_phone.py --code 123456
```

命令行一键联调（发现 → 401 → 配对 → 证书固定 → 列表 → 缩略图 → Range → 本机转发 → 发图到手机 → 验证码 → 端口探测 → 事件流 → 截图 / 短信 / 文字 / 充电 / 免打扰 → 敲门）：

```powershell
dotnet run --project windows/tools/clcheck -- --code 123456 --trigger
```

调试 App 又不想动正式数据时，设置 `COLORLINK_DATA` 指向一个临时目录：配对、缓存、下载都放在那里，也不会写开机自启和「发送到」菜单。

```powershell
$env:COLORLINK_DATA = "$env:TEMP\colorlink-dev"; .\src\ColorLink.App\bin\Debug\net10.0-windows10.0.22621.0\win-x64\ColorLink.exe
```

单元测试：

```powershell
dotnet test windows/tests/ColorLink.Core.Tests
```

## 已验证 / 未验证

| 项目 | 状态 |
|---|---|
| Core、App、clcheck、测试编译（无警告） | ✅ |
| 单元测试 28 项 | ✅ |
| clcheck 对着模拟手机全流程（含 --trigger、mDNS 发现） | ✅ |
| App：mDNS 发现 → 配对窗口 → 配对 → 连接 → 相册列表同步 | ✅（模拟手机，UI Automation 驱动） |
| App：托盘面板（Acrylic、电量、最近三张）、相册窗口（Mica、按天分组、缩略图） | ✅ 截图核对过 |
| App：截图事件 → 图片进剪贴板；验证码短信 → 验证码进剪贴板 | ✅（模拟手机） |
| App：第二个实例 `--send` 转给第一个，文件发到手机 | ✅（模拟手机） |
| 面板拖放发送、相册拖出到资源管理器、右键菜单、删除确认 | ⚠️ 已编译，没有实际拖拽 / 点击测试 |
| 视频 / 录音播放窗口 | ⚠️ 转发已由 clcheck 验证，播放窗口没有实际打开看过 |
| 系统通知（含点按在资源管理器中显示） | ⚠️ 已编译，没有截图核对 |
| 锁屏 / 睡眠断开、解锁重连 | ⚠️ 已编译，需要实测 |
| 蓝牙广播 | ⚠️ 开发机蓝牙不支持外围设备角色（RadioNotAvailable），没测到 |
| 连真手机 | ❌ 待测 |

## 已知限制 / 下一步

- 拖文件到托盘图标时面板不会自动弹出（Windows 不给通知区域图标发拖拽消息），改用「发送到」菜单和拖到面板 / 相册窗口。
- 相册里没有恢复 EXIF 拍摄日期（Mac 端的 `ImageCaptureDate`），旧照片没有拍摄时间时按修改时间分组。
- 按住空格快速预览（Mac 的 Quick Look）还没做，双击用系统「照片」打开原图。
- 手机端的文案还写着「Mac」（例如分享菜单「发送到 Mac」），功能不受影响，以后可以改成「电脑」。
