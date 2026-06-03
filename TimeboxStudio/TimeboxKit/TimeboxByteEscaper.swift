import Foundation

public enum TimeboxByteEscaper {
    /// Placeholder until packet framing/escaping from the Evo protocol is ported.
    public static func passThrough(_ data: Data) -> Data {
        data
    }
}
