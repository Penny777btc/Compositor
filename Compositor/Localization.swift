import Foundation

/// Runtime localization for dynamic labels such as enum-backed pickers and AppKit alerts.
/// English source strings are stable keys and the fallback value, matching String Catalog extraction.
nonisolated enum L10n {
    static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        format(source: key, translation: text(key), arguments: arguments)
    }

    /// Kept separate from bundle lookup so unsafe translations can be tested without passing them to Foundation.
    static func format(source: String, translation: String, arguments: [CVarArg], locale: Locale = .current) -> String {
        let signature = LocalizationFormatSignature.parse(source)
        guard signature.isValid, !signature.mixesPositionalAndImplicit, !signature.hasLiteralPercent,
              (signature.arguments.map(\.position).max() ?? 0) == arguments.count else {
            // A malformed source or call site cannot safely be passed to a variadic formatter either.
            return source
        }
        let format = LocalizationFormatSignature.isCompatible(source: source, translation: translation)
            && !LocalizationFormatSignature.parse(translation).hasLiteralPercent ? translation : source
        return String(format: format, locale: locale, arguments: arguments)
    }
}

nonisolated struct LocalizationFormatSignature: Equatable {
    struct Argument: Equatable {
        let position: Int
        let conversion: String
    }
    let arguments: [Argument]
    let mixesPositionalAndImplicit: Bool
    let isValid: Bool
    let hasLiteralPercent: Bool

    static func parse(_ value: String) -> Self {
        let characters = Array(value)
        var index = 0
        var implicitPosition = 0, sawExplicit = false, sawImplicit = false
        var arguments: [Argument] = []
        var isValid = true, hasLiteralPercent = false
        func isDigit(_ character: Character) -> Bool { character >= "0" && character <= "9" }

        while index < characters.count {
            guard characters[index] == "%" else { index += 1; continue }
            let percentIndex = index
            index += 1
            if index < characters.count, characters[index] == "%" {
                index += 1 // Consume both characters: the second percent cannot begin another directive.
                continue
            }
            // Catalogs also contain ordinary labels such as "800% and above" and "120% of".
            // Such percentages are valid text, but L10n.format never hands them to printf unescaped.
            if index == characters.count || (percentIndex > 0 && isDigit(characters[percentIndex - 1])
                && (characters[index].isWhitespace || ",;:!?)]}".contains(characters[index])
                    || (characters[index] == "." && (index + 1 == characters.count || !isDigit(characters[index + 1])))
                    || characters[index].unicodeScalars.contains(where: { !$0.isASCII }))) {
                hasLiteralPercent = true
                continue
            }

            let numberStart = index
            while index < characters.count && isDigit(characters[index]) { index += 1 }
            let position: Int
            if index < characters.count, characters[index] == "$" {
                guard index > numberStart, let explicit = Int(String(characters[numberStart..<index])), explicit > 0 else {
                    isValid = false; break
                }
                position = explicit; sawExplicit = true
                index += 1
            } else {
                implicitPosition += 1; position = implicitPosition; sawImplicit = true
                index = numberStart // Those digits belong to a fixed field width, not an argument position.
            }

            while index < characters.count && "-+0#".contains(characters[index]) { index += 1 }
            while index < characters.count && isDigit(characters[index]) { index += 1 }
            if index < characters.count, characters[index] == "." {
                index += 1
                while index < characters.count && isDigit(characters[index]) { index += 1 }
            }
            // Dynamic widths/precisions consume extra arguments; reject them instead of miscounting them.
            guard index < characters.count, characters[index] != "*" else { isValid = false; break }
            let conversionStart = index
            var length = ""
            if "hlqLztj".contains(characters[index]) {
                length.append(characters[index]); index += 1
                if index < characters.count, (length == "h" || length == "l"), String(characters[index]) == length {
                    length.append(characters[index]); index += 1
                }
            }
            guard index < characters.count else { isValid = false; break }
            let conversion = characters[index]
            let supported: Bool
            switch conversion {
            case "d", "i", "u", "o", "x", "X":
                supported = ["", "hh", "h", "ll", "l", "q", "z", "t", "j"].contains(length)
            case "f", "F", "e", "E", "g", "G", "a", "A":
                supported = ["", "l", "L"].contains(length)
            case "c", "s": supported = length.isEmpty || length == "l"
            case "@", "C", "S", "p": supported = length.isEmpty
            default: supported = false // Includes %n, unknown conversions, and incomplete directives.
            }
            guard supported else { isValid = false; break }
            index += 1
            arguments.append(Argument(position: position, conversion: String(characters[conversionStart..<index])))
        }
        arguments.sort { $0.position == $1.position ? $0.conversion < $1.conversion : $0.position < $1.position }
        let positions = Set(arguments.map(\.position))
        if sawExplicit, positions.count != (positions.max() ?? 0) { isValid = false }
        return Self(arguments: arguments, mixesPositionalAndImplicit: sawExplicit && sawImplicit,
                    isValid: isValid, hasLiteralPercent: hasLiteralPercent)
    }

    static func isCompatible(source: String, translation: String) -> Bool {
        let source = parse(source), translation = parse(translation)
        let containsArguments = !source.arguments.isEmpty || !translation.arguments.isEmpty
        return source.isValid && translation.isValid
            && !source.mixesPositionalAndImplicit && !translation.mixesPositionalAndImplicit
            && (!containsArguments || (!source.hasLiteralPercent && !translation.hasLiteralPercent))
            && source.arguments == translation.arguments
    }
}
