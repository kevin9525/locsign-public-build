import Foundation

enum ProvisioningRedaction {
    static func redact(_ text: String) -> String {
        let patterns = [#"(?i)password|passwd|private[ _-]?key|hostprivatekey|rootprivatekey|adi[_-]?pb|anisette\s*[=:]|anisette[ _-]?(data|payload|headers|blob)\s*[=:]|x-apple-|authorization|\btoken\b|\badsid\b"#,
                        #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
                        #"(?i)0000[0-9a-f]{4}-[0-9a-f]{16}"#]
        if patterns.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) {
            return "[敏感内容已隐藏]"
        }
        return text
    }
}
