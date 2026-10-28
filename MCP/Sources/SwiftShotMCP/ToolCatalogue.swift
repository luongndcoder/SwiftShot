import Foundation

/// The MCP tool catalogue exposed to the agent.
enum ToolCatalogue {
    static let version = "1.2.0"

    /// JSON schema of a tool.
    struct Tool {
        let name: String
        let description: String
        let inputSchema: [String: Any]

        var payload: [String: Any] {
            [
                "name": name,
                "description": description,
                "inputSchema": inputSchema,
            ]
        }
    }

    static let all: [Tool] = [
        Tool(
            name: "swiftshot_capture",
            description: """
            Take a screenshot with SwiftShot and return the image.

            Captures a whole display by default, or only a region when
            `region` is given. The region uses global screen coordinates in
            points with the origin in the bottom-left corner of the main
            display (the same coordinates as `NSScreen.frame`), e.g.
            {"x": 0, "y": 0, "width": 800, "height": 600}.

            The screenshot is taken by the running SwiftShot app, so no extra
            screen recording permission is required.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "region": [
                        "type": "object",
                        "description": "Optional region in global screen points.",
                        "properties": [
                            "x": ["type": "number"],
                            "y": ["type": "number"],
                            "width": ["type": "number"],
                            "height": ["type": "number"],
                        ],
                        "required": ["x", "y", "width", "height"],
                    ],
                    "display_id": [
                        "type": "integer",
                        "description": "Optional display id (see swiftshot_displays).",
                    ],
                    "format": [
                        "type": "string",
                        "enum": ["png", "jpeg"],
                        "description": "Image format of the result. Defaults to png.",
                    ],
                    "quality": [
                        "type": "number",
                        "description": "JPEG quality between 0.4 and 1.0. Defaults to 0.9.",
                    ],
                ],
            ]
        ),
        Tool(
            name: "swiftshot_displays",
            description: """
            List the connected displays with their id, name, frame, backing scale
            factor and whether they are the main display. Use the id with
            `swiftshot_capture` to capture a specific display.
            """,
            inputSchema: [
                "type": "object",
                "properties": [:],
            ]
        ),
        Tool(
            name: "swiftshot_status",
            description: """
            Report the state of the SwiftShot app: version, bundle identifier,
            whether the Screen Recording permission is granted and the path of
            the bridge socket.
            """,
            inputSchema: [
                "type": "object",
                "properties": [:],
            ]
        ),
        Tool(
            name: "swiftshot_settings",
            description: """
            Read or update the SwiftShot preferences.

            Without arguments the current settings are returned. Pass any of
            `auto_save`, `copy_to_clipboard`, `ask_where_to_save`,
            `copy_on_double_click`, `use_last_region`, `show_magnifier`,
            `jpeg_quality`, `stroke_width`, `save_format` and `save_directory`
            to change them.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "auto_save": ["type": "boolean"],
                    "copy_to_clipboard": ["type": "boolean"],
                    "ask_where_to_save": ["type": "boolean"],
                    "copy_on_double_click": ["type": "boolean"],
                    "use_last_region": ["type": "boolean"],
                    "show_magnifier": ["type": "boolean"],
                    "jpeg_quality": ["type": "number"],
                    "stroke_width": ["type": "number"],
                    "save_format": ["type": "string", "enum": ["png", "jpeg"]],
                    "save_directory": ["type": "string"],
                ],
            ]
        ),
        Tool(
            name: "swiftshot_open_settings",
            description: """
            Open the SwiftShot preferences window so the user can review or
            change the settings.
            """,
            inputSchema: [
                "type": "object",
                "properties": [:],
            ]
        ),
    ]

    static func tool(named name: String) -> Tool? {
        all.first { $0.name == name }
    }
}
