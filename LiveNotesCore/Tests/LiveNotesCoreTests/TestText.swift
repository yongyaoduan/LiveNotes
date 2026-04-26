import Foundation

enum TestText {
    static let activationFunctionTranslation = text([
        0x6FC0, 0x6D3B, 0x51FD, 0x6570, 0x5E2E, 0x52A9, 0x6A21, 0x578B,
        0x5B66, 0x4E60, 0x975E, 0x7EBF, 0x6027, 0x6A21, 0x5F0F, 0x3002
    ])

    private static func text(_ scalars: [UInt32]) -> String {
        String(String.UnicodeScalarView(scalars.compactMap(UnicodeScalar.init)))
    }
}
