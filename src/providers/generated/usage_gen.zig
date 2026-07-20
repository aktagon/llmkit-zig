// Code generated — DO NOT EDIT.


/// Token consumption metrics for a generation call. Each dimension is
///
/// hand-written Response / Event structs reference it by name.
pub const Usage = struct {
    input: i64 = 0,
    output: i64 = 0,
    cache_write: i64 = 0,
    cache_read: i64 = 0,
    reasoning: i64 = 0,
    /// cost is the provider-reported request cost in USD (ADR-027). Not a TokenDimension — a distinct monetary field. Only OpenRouter (the request must opt in with usage: {include: true}) and xAI report it. 0 is ambiguous: unreported or genuinely free — providers whose usageCostPath is empty never report cost.
    cost: f64 = 0.0,
};
