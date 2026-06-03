import Foundation

public enum HexDump {
    public static func string(from data: Data, separator: String = " ") -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: separator)
    }

    public static func compactString(from data: Data) -> String {
        string(from: data, separator: "")
    }
}

public enum HexStringParserError: LocalizedError, Equatable {
    case empty
    case oddNibbleCount(Int)
    case invalidCharacter(Character)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "No hex bytes were provided."
        case .oddNibbleCount(let count):
            return "Hex input has an odd number of digits (\(count)). Bytes must be two hex digits each."
        case .invalidCharacter(let character):
            return "Invalid hex character '\(character)'. Use 0-9, A-F, spaces, dashes, colons, commas, or 0x prefixes."
        }
    }
}

public enum HexStringParser {
    public static func data(from input: String) throws -> Data {
        var digits: [Character] = []
        var iterator = input.trimmingCharacters(in: .whitespacesAndNewlines).makeIterator()

        while let character = iterator.next() {
            if character == "0" {
                if let next = iterator.next() {
                    if next == "x" || next == "X" {
                        continue
                    }
                    if isHexDigit(character) {
                        digits.append(character)
                    }
                    if isSeparator(next) {
                        continue
                    }
                    guard isHexDigit(next) else {
                        throw HexStringParserError.invalidCharacter(next)
                    }
                    digits.append(next)
                } else {
                    digits.append(character)
                }
                continue
            }

            if isSeparator(character) {
                continue
            }

            guard isHexDigit(character) else {
                throw HexStringParserError.invalidCharacter(character)
            }
            digits.append(character)
        }

        guard !digits.isEmpty else {
            throw HexStringParserError.empty
        }

        guard digits.count.isMultiple(of: 2) else {
            throw HexStringParserError.oddNibbleCount(digits.count)
        }

        var bytes = Data()
        bytes.reserveCapacity(digits.count / 2)

        var index = digits.startIndex
        while index < digits.endIndex {
            let nextIndex = digits.index(after: index)
            let byteString = String([digits[index], digits[nextIndex]])
            guard let byte = UInt8(byteString, radix: 16) else {
                throw HexStringParserError.invalidCharacter(digits[index])
            }
            bytes.append(byte)
            index = digits.index(after: nextIndex)
        }

        return bytes
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || character == "-" || character == ":" || character == "," || character == "_"
    }

    private static func isHexDigit(_ character: Character) -> Bool {
        character.isHexDigit
    }
}

private extension Character {
    var isWhitespace: Bool {
        unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    var isHexDigit: Bool {
        unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }
    }
}
