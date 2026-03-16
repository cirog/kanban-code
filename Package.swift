// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClaudeBoard",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "ClaudeBoard", targets: ["ClaudeBoard"]),
        .executable(name: "kanban-code-active-session", targets: ["KanbanCodeActiveSession"]),
        .library(name: "ClaudeBoardCore", targets: ["ClaudeBoardCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.0.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeBoard",
            dependencies: ["ClaudeBoardCore", "SwiftTerm", .product(name: "MarkdownUI", package: "swift-markdown-ui")],
            path: "Sources/ClaudeBoard",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "KanbanCodeActiveSession",
            path: "Sources/KanbanCodeActiveSession"
        ),
        .target(
            name: "ClaudeBoardCore",
            path: "Sources/ClaudeBoardCore"
        ),
        .testTarget(
            name: "ClaudeBoardCoreTests",
            dependencies: ["ClaudeBoardCore"],
            path: "Tests/ClaudeBoardCoreTests"
        ),
        .testTarget(
            name: "ClaudeBoardTests",
            dependencies: ["ClaudeBoard", "ClaudeBoardCore"],
            path: "Tests/ClaudeBoardTests"
        ),
    ]
)
