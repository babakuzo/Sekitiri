// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Sekitiri",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "SekitiriApp",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources",
            exclude: ["Info.plist"],
            resources: [.process("Assets")],
            linkerSettings: [
                // Embed Info.plist so TCC attributes mic/system-audio permissions
                // to Sekitiri itself (like quill does).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "SekitiriAppTests",
            dependencies: ["SekitiriApp"],
            path: "Tests/SekitiriAppTests",
            resources: [.process("Fixtures")]
        )
    ]
)
