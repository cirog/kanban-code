import Foundation

/// Builds the final prompt to send to Claude, applying templates from settings and project config.
public enum PromptBuilder {

    /// Build the full prompt for a card, applying appropriate templates.
    ///
    /// For manual tasks: wraps `promptBody` with `promptTemplate`.
    /// For session cards: uses card name as-is (no template needed).
    public static func buildPrompt(
        card link: Link,
        project: Project? = nil,
        settings: Settings? = nil
    ) -> String {
        var prompt: String

        if let promptBody = link.promptBody {
            prompt = promptBody
        } else {
            prompt = link.name ?? ""
        }

        // Wrap with prompt template (prefix/suffix)
        let template = settings?.promptTemplate ?? ""
        if !template.isEmpty {
            if template.contains("${prompt}") {
                prompt = applyTemplate(template, variables: ["prompt": prompt])
            } else {
                // Template has no placeholder — prepend it
                prompt = template + "\n" + prompt
            }
        }

        return prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replace `${key}` placeholders with values from the variables dictionary.
    public static func applyTemplate(_ template: String, variables: [String: String]) -> String {
        var result = template
        for (key, value) in variables {
            result = result.replacingOccurrences(of: "${\(key)}", with: value)
        }
        return result
    }
}
