// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CIMCKVM",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CIMCKVM"),
        .testTarget(name: "CIMCKVMTests", dependencies: ["CIMCKVM"]),
    ]
)
