import CoreGraphics
import Foundation

/// ZMK outputs, not a second physical layout. Locations always come from the loaded .keymap.
enum KeyCodes {
    struct Chord: Equatable {
        var code: Int64
        var modifiers: CGEventFlags = []
    }

    static let aliases: [String: String] = [
        "LEFT_BRACE": "LBRC", "RIGHT_BRACE": "RBRC", "LEFT_BRACKET": "LBKT", "RIGHT_BRACKET": "RBKT",
        "LEFT_PARENTHESIS": "LPAR", "RIGHT_PARENTHESIS": "RPAR", "ASTERISK": "ASTRK",
        "EXCLAMATION": "EXCL", "DOLLAR": "DLLR", "PERCENT": "PRCNT", "AMPERSAND": "AMPS",
        "SINGLE_QUOTE": "SQT", "APOSTROPHE": "SQT", "DOUBLE_QUOTES": "DQT", "DOUBLE_QUOTE": "DQT",
        "SEMICOLON": "SEMI", "QUESTION": "QMARK", "BACKSLASH": "BSLH", "BACKSLASH_PIPE": "BSLH",
        "UNDERSCORE": "UNDER", "LESS_THAN": "LT", "GREATER_THAN": "GT", "EQUALS": "EQUAL",
        "BACKSPACE": "BSPC", "DELETE": "DEL", "RETURN": "ENTER", "ESCAPE": "ESC",
        "PAGE_UP": "PG_UP", "PAGE_DOWN": "PG_DN", "CAPSLOCK": "CAPS", "CAPS_LOCK": "CAPS",
        "LEFT_SHIFT": "LSHFT", "RIGHT_SHIFT": "RSHFT", "LEFT_CONTROL": "LCTRL", "RIGHT_CONTROL": "RCTRL",
        "LEFT_ALT": "LALT", "RIGHT_ALT": "RALT", "LEFT_GUI": "LGUI", "RIGHT_GUI": "RGUI",
        "C_VOLUME_UP": "C_VOL_UP", "C_VOLUME_DOWN": "C_VOL_DN", "C_PLAY_PAUSE": "C_PP",
    ]

    static func canonical(_ token: String) -> String { aliases[token] ?? token }

    static let wrappers: [String: CGEventFlags] = [
        "LS": .maskShift, "RS": .maskShift, "LC": .maskControl, "RC": .maskControl,
        "LA": .maskAlternate, "RA": .maskAlternate, "LG": .maskCommand, "RG": .maskCommand,
    ]

    static func chord(_ expression: String) -> Chord? {
        let token = canonical(expression)
        if let open = token.firstIndex(of: "("), token.hasSuffix(")"),
           let modifier = wrappers[String(token[..<open])],
           var inner = chord(String(token[token.index(after: open)..<token.index(before: token.endIndex)])) {
            inner.modifiers.formUnion(modifier)
            return inner
        }
        if let plain = shifted[token], var result = chord(plain) {
            result.modifiers.insert(.maskShift)
            return result
        }
        return codes[token].map { Chord(code: $0) }
    }

    static let shifted: [String: String] = [
        "EXCL": "N1", "AT": "N2", "HASH": "N3", "DLLR": "N4", "PRCNT": "N5", "CARET": "N6",
        "AMPS": "N7", "ASTRK": "N8", "LPAR": "N9", "RPAR": "N0", "UNDER": "MINUS", "PLUS": "EQUAL",
        "LBRC": "LBKT", "RBRC": "RBKT", "PIPE": "BSLH", "COLON": "SEMI", "DQT": "SQT",
        "LT": "COMMA", "GT": "DOT", "QMARK": "SLASH", "TILDE": "GRAVE",
    ]

    static let codes: [String: Int64] = [
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9,
        "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17,
        "N1": 18, "N2": 19, "N3": 20, "N4": 21, "N6": 22, "N5": 23, "EQUAL": 24,
        "N9": 25, "N7": 26, "MINUS": 27, "N8": 28, "N0": 29, "RBKT": 30, "O": 31, "U": 32,
        "LBKT": 33, "I": 34, "P": 35, "ENTER": 36, "L": 37, "J": 38, "SQT": 39,
        "K": 40, "SEMI": 41, "BSLH": 42, "COMMA": 43, "SLASH": 44, "N": 45, "M": 46,
        "DOT": 47, "TAB": 48, "SPACE": 49, "GRAVE": 50, "BSPC": 51, "ESC": 53,
        "RGUI": 54, "LGUI": 55, "LSHFT": 56, "CAPS": 57, "LALT": 58, "LCTRL": 59,
        "RSHFT": 60, "RALT": 61, "RCTRL": 62,
        "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97, "F7": 98,
        "F8": 100, "F9": 101, "F10": 109, "F11": 103, "F12": 111,
        "F13": 105, "F14": 107, "F15": 113, "F16": 106, "F17": 64, "F18": 79, "F19": 80, "F20": 90,
        "LANG2": 102, "LANG1": 104, "INS": 114, "HOME": 115, "PG_UP": 116, "DEL": 117, "END": 119, "PG_DN": 121,
        "LEFT": 123, "RIGHT": 124, "DOWN": 125, "UP": 126,
        "KP_N0": 82, "KP_N1": 83, "KP_N2": 84, "KP_N3": 85, "KP_N4": 86, "KP_N5": 87,
        "KP_N6": 88, "KP_N7": 89, "KP_N8": 91, "KP_N9": 92, "KP_DOT": 65, "KP_ENTER": 76,
        "KP_PLUS": 69, "KP_MINUS": 78, "KP_MULTIPLY": 67, "KP_DIVIDE": 75, "KP_EQUAL": 81,
    ]

    static func modifier(for code: Int64) -> CGEventFlags? {
        switch code {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        default: return nil
        }
    }
}
