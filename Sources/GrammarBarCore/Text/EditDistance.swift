import Foundation

public enum EditDistance {
    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1,
                             cur[j - 1] + 1,
                             prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[y.count]
    }

    /// Length-normalized distance in 0...1.
    ///
    /// NOTE: this measures *how much* changed, not whether the change was
    /// licensed. Recon proved the dominant failure is a small, confident, wrong
    /// edit (tense mutation at 0.167) which this metric scores as very safe.
    /// Never let it decide alone — see `TenseGuard`.
    public static func normalized(_ a: String, _ b: String) -> Double {
        let m = max(a.count, b.count)
        guard m > 0 else { return 0 }
        return Double(levenshtein(a, b)) / Double(m)
    }
}
