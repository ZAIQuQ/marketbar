/// A strategy boundary with caller-owned bar, state, and decision types.
/// Inputs must contain only information known by `decisionMinute` (UTC Unix epoch minutes).
public protocol QuantStrategyProvider {
    associatedtype Bar
    associatedtype ModelState
    associatedtype Decision

    func predict(model: ModelState, bars: [Bar], decisionMinute: Int64) -> Decision
}
