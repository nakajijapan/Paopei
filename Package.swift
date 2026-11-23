// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NKJBlogPoster",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "NKJBlogPoster", targets: ["NKJBlogPoster"])
    ],
    targets: [
        .executableTarget(
            name: "NKJBlogPoster",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(
            name: "NKJBlogPosterTests",
            dependencies: ["NKJBlogPoster"]
        )
    ]
)
