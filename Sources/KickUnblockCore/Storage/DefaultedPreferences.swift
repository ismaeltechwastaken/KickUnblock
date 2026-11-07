import Foundation

extension UserDefaults {
    public func bool(_ key: String, default def: Bool) -> Bool { object(forKey: key) == nil ? def : bool(forKey: key) }
    public func double(_ key: String, default def: Double) -> Double { object(forKey: key) == nil ? def : double(forKey: key) }
    public func int(_ key: String, default def: Int) -> Int { object(forKey: key) == nil ? def : integer(forKey: key) }
    public func string(_ key: String, default def: String) -> String { string(forKey: key) ?? def }
}
