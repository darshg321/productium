import Foundation

public enum Wellbeing {

    public static func correlation(_ pairs: [(Double, Double)]) -> Double? {
        guard pairs.count >= 7 else { return nil }
        let n = Double(pairs.count)
        let mx = pairs.map(\.0).reduce(0, +) / n, my = pairs.map(\.1).reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (x, y) in pairs { sxy += (x - mx) * (y - my); sxx += (x - mx) * (x - mx); syy += (y - my) * (y - my) }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx.squareRoot() * syy.squareRoot())
    }

}
