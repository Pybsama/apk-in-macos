import Foundation

public enum AndroidKey {
    public static let home: Int32 = 3
    public static let back: Int32 = 4
    public static let up: Int32 = 19
    public static let down: Int32 = 20
    public static let left: Int32 = 21
    public static let right: Int32 = 22
    public static let tab: Int32 = 61
    public static let enter: Int32 = 66
    public static let backspace: Int32 = 67
    public static let pageUp: Int32 = 92
    public static let pageDown: Int32 = 93
    public static let forwardDelete: Int32 = 112
    public static let moveHome: Int32 = 122
    public static let moveEnd: Int32 = 123
    public static let recents: Int32 = 187
    public static let cut: Int32 = 277
    public static let copy: Int32 = 278
    public static let paste: Int32 = 279
    public static let keyA: Int32 = 29

    public static let metaCtrl: Int32 = 0x1000
    public static let metaShift: Int32 = 0x1
}

public enum KeyMap {
    public static func specialKey(forMacCode code: UInt16) -> Int32? {
        switch code {
        case 36, 76: return AndroidKey.enter
        case 48: return AndroidKey.tab
        case 51: return AndroidKey.backspace
        case 53: return AndroidKey.back
        case 115: return AndroidKey.moveHome
        case 116: return AndroidKey.pageUp
        case 117: return AndroidKey.forwardDelete
        case 119: return AndroidKey.moveEnd
        case 121: return AndroidKey.pageDown
        case 123: return AndroidKey.left
        case 124: return AndroidKey.right
        case 125: return AndroidKey.down
        case 126: return AndroidKey.up
        default: return nil
        }
    }
}
