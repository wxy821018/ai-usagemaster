// swift-tools-version:5.9
// Windows 版用 SwiftPM 编译（见 build.ps1）。macOS 版仍用 build.sh 直接调用 swiftc，不经过这个文件。
import PackageDescription

let package = Package(
    name: "AIUsageMaster",
    dependencies: [
        // CryptoKit 只有 Apple 平台有；Windows 上用 API 相同的 swift-crypto
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        .systemLibrary(name: "SQLite3", path: "windows/SQLite3"),
        .executableTarget(
            name: "AIUsageMaster",
            dependencies: [
                .target(name: "SQLite3", condition: .when(platforms: [.windows])),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.windows, .linux])),
            ],
            path: "Sources"
        ),
    ]
)
