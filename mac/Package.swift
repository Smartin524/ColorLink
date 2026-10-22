// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ColorLink",
    platforms: [.macOS(.v15)],
    targets: [
        // 与界面无关的部分：协议客户端、发现、缓存、配对存储
        .target(name: "ColorLinkCore"),
        // 菜单栏 App
        .executableTarget(name: "ColorLink", dependencies: ["ColorLinkCore"]),
        // 命令行联调工具：没有手机时配合 mock/mock_phone.py 走一遍完整流程
        .executableTarget(name: "clcheck", dependencies: ["ColorLinkCore"]),
    ],
    swiftLanguageModes: [.v5]
)
