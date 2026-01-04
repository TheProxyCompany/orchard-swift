import Foundation
import Testing
@testable import Orchard

/// Chat formatter tests
@Suite
struct FormatterTests {
    @Test
    func testControlTokensParsing() throws {
        let json = """
        {
            "template_type": "llama",
            "begin_of_text": "<|begin_of_text|>",
            "end_of_message": "<|eom_id|>",
            "end_of_sequence": "<|eot_id|>",
            "roles": {
                "agent": {
                    "role_name": "assistant",
                    "role_start_tag": "<|start_header_id|>",
                    "role_end_tag": "<|end_header_id|>\\n\\n"
                },
                "system": {
                    "role_name": "system",
                    "role_start_tag": "<|start_header_id|>",
                    "role_end_tag": "<|end_header_id|>\\n\\n"
                },
                "user": {
                    "role_name": "user",
                    "role_start_tag": "<|start_header_id|>",
                    "role_end_tag": "<|end_header_id|>\\n\\n"
                }
            }
        }
        """.data(using: .utf8)!

        let tokens = try JSONDecoder().decode(ControlTokens.self, from: json)

        #expect(tokens.templateType == "llama")
        #expect(tokens.beginOfText == "<|begin_of_text|>")
        #expect(tokens.endOfSequence == "<|eot_id|>")
        #expect(tokens.roles.agent?.roleName == "assistant")
        #expect(tokens.roles.user?.roleName == "user")
        #expect(tokens.roles.system?.roleName == "system")
    }

    @Test
    func testRoleNormalization() {
        let availableRoles: Set<String> = ["system", "user", "agent", "tool"]

        #expect(normalizeRole(nil, availableRoles: availableRoles) == "user")
        #expect(normalizeRole("user", availableRoles: availableRoles) == "user")
        #expect(normalizeRole("USER", availableRoles: availableRoles) == "user")
        #expect(normalizeRole("assistant", availableRoles: availableRoles) == "agent")
        #expect(normalizeRole("model", availableRoles: availableRoles) == "agent")
        #expect(normalizeRole("developer", availableRoles: availableRoles) == "system")
    }

    @Test
    func testLayoutBuilding() throws {
        let promptText = "Hello <|image|> world"
        let imageData = Data([0x01, 0x02, 0x03])

        let layout = try buildMultimodalLayout(
            promptText: promptText,
            imageBuffers: [imageData],
            capabilities: [],
            contentOrder: [("image", 0)],
            placeholderToken: "<|image|>",
            excludeImagePlaceholder: true
        )

        #expect(layout.count == 3, "Should have text, image, text segments")

        let firstText = layout[0]
        #expect(firstText["type"] as? String == "text")

        let image = layout[1]
        #expect(image["type"] as? String == "image")
        #expect(image["length"] as? Int == 3)

        let lastText = layout[2]
        #expect(lastText["type"] as? String == "text")
    }

    @Test
    func testLayoutTextOnly() throws {
        let promptText = "Hello, world!"

        let layout = try buildMultimodalLayout(
            promptText: promptText,
            imageBuffers: [],
            capabilities: [],
            contentOrder: [],
            placeholderToken: "<|image|>",
            excludeImagePlaceholder: true
        )

        #expect(layout.count == 1)
        #expect(layout[0]["type"] as? String == "text")
        #expect(layout[0]["length"] as? Int == promptText.utf8.count)
    }

    @Test
    func testLayoutEmptyPromptThrows() {
        #expect(throws: MultimodalError.self) {
            _ = try buildMultimodalLayout(
                promptText: "",
                imageBuffers: [],
                capabilities: [],
                contentOrder: [],
                placeholderToken: "<|image|>",
                excludeImagePlaceholder: true
            )
        }
    }

    @Test
    func testLayoutPlaceholderMismatchThrows() {
        let promptText = "No image placeholders here"
        let imageData = Data([0x01])

        #expect(throws: MultimodalError.self) {
            _ = try buildMultimodalLayout(
                promptText: promptText,
                imageBuffers: [imageData],
                capabilities: [],
                contentOrder: [("image", 0)],
                placeholderToken: "<|image|>",
                excludeImagePlaceholder: true
            )
        }
    }
}
