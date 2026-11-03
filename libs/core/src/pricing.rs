//! API-equivalent cost of a model call: what the call would cost at
//! Anthropic's API prices. A subscription is not billed per token; ccop uses
//! this only to weight tokens (a cache read is far cheaper than an output
//! token), so usage can be compared with a weekly limit.
//!
//! Prices from the Claude API reference bundled with Claude Code (cached
//! 2026-10-06), in dollars per million tokens. Cache writes are 1.25x input
//! (5-minute TTL) or 2x (1-hour TTL) and cache reads 0.1x input, except
//! where a model has its own cache read price.

use crate::usage::Usage;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Price {
    pub input: f64,
    pub output: f64,
    pub cache_write_5m: f64,
    pub cache_write_1h: f64,
    pub cache_read: f64,
}

impl Price {
    /// A price with the usual cache rates: writes 1.25x / 2x, reads 0.1x.
    const fn standard(input: f64, output: f64) -> Price {
        Price { input, output, cache_write_5m: input * 1.25, cache_write_1h: input * 2.0, cache_read: input * 0.1 }
    }

    const fn with_cache_read(self, cache_read: f64) -> Price {
        Price { cache_read, ..self }
    }
}

/// Claude Haiku 5.5 bills a call by a second rate card when its prompt is
/// longer than this.
pub const HAIKU_5_5_LONG_PROMPT: u64 = 100_000;

/// The price of a model, by its id. A model this table does not know gets
/// the price of the newest model of its family (fable, opus, sonnet, haiku),
/// and any other model the price of Claude Opus 5.5.
pub fn price(model: &str, prompt_tokens: u64) -> Price {
    let m = model.trim().to_ascii_lowercase();
    let m = m.strip_prefix("anthropic.").unwrap_or(&m);
    let is = |prefix: &str| m == prefix || m.starts_with(&format!("{prefix}-")) || m.starts_with(&format!("{prefix}@"));
    if is("claude-fable-5-1") || is("claude-mythos-5-1") {
        Price::standard(10.0, 50.0).with_cache_read(0.25)
    } else if is("claude-fable-5") || is("claude-mythos-5") {
        Price::standard(10.0, 50.0)
    } else if is("claude-opus-5-5") {
        Price::standard(4.0, 20.0).with_cache_read(0.20)
    } else if is("claude-opus-5") || is("claude-opus-4-8") || is("claude-opus-4-7") || is("claude-opus-4-6") {
        Price::standard(5.0, 25.0)
    } else if is("claude-sonnet-5-5") || is("claude-sonnet-5") {
        Price::standard(2.0, 10.0).with_cache_read(0.20)
    } else if is("claude-sonnet-4-6") {
        Price::standard(3.0, 15.0)
    } else if is("claude-haiku-5-5") {
        if prompt_tokens > HAIKU_5_5_LONG_PROMPT { Price::standard(0.50, 2.50) } else { Price::standard(0.10, 0.50) }
    } else if is("claude-haiku-4-5") {
        Price::standard(1.0, 5.0)
    } else if m.contains("fable") || m.contains("mythos") {
        price("claude-fable-5-1", prompt_tokens)
    } else if m.contains("sonnet") {
        price("claude-sonnet-5-5", prompt_tokens)
    } else if m.contains("haiku") {
        price("claude-haiku-5-5", prompt_tokens)
    } else {
        price("claude-opus-5-5", prompt_tokens)
    }
}

/// The API-equivalent cost of one call, in millionths of a dollar.
pub fn cost_micros(model: &str, u: &Usage) -> u64 {
    let p = price(model, u.input_total());
    let write_1h = u.cache_write_1h_tokens.min(u.cache_write_tokens);
    let write_5m = u.cache_write_tokens - write_1h;
    // Tokens × dollars per million tokens = millionths of a dollar.
    let micros = u.input_tokens as f64 * p.input
        + u.output_tokens as f64 * p.output
        + write_5m as f64 * p.cache_write_5m
        + write_1h as f64 * p.cache_write_1h
        + u.cache_read_tokens as f64 * p.cache_read;
    micros.round() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn usage(input: u64, write: u64, write_1h: u64, read: u64, output: u64) -> Usage {
        Usage { input_tokens: input, cache_write_tokens: write, cache_write_1h_tokens: write_1h, cache_read_tokens: read, output_tokens: output, requests: 1 }
    }

    #[test]
    fn an_opus_5_5_call() {
        // 2 input, 40,823 written with the 1-hour TTL, 29,199 read, 198 output:
        // 2×4 + 40,823×8 + 29,199×0.20 + 198×20 = 8 + 326,584 + 5,839.8 + 3,960.
        assert_eq!(cost_micros("claude-opus-5-5", &usage(2, 40_823, 40_823, 29_199, 198)), 336_392);
    }

    #[test]
    fn five_minute_writes_cost_less_than_one_hour_writes() {
        assert_eq!(cost_micros("claude-sonnet-5-5", &usage(0, 1_000_000, 0, 0, 0)), 2_500_000);
        assert_eq!(cost_micros("claude-sonnet-5-5", &usage(0, 1_000_000, 1_000_000, 0, 0)), 4_000_000);
        assert_eq!(cost_micros("claude-sonnet-5-5", &usage(0, 1_000_000, 400_000, 0, 0)), 3_100_000);
    }

    #[test]
    fn haiku_5_5_has_a_second_rate_card_for_long_prompts() {
        assert_eq!(cost_micros("claude-haiku-5-5", &usage(100_000, 0, 0, 0, 1_000)), 10_000 + 500);
        assert_eq!(cost_micros("claude-haiku-5-5", &usage(100_001, 0, 0, 0, 1_000)), 50_001 + 2_500);
        // The prompt counts its cached part too.
        assert_eq!(price("claude-haiku-5-5", 150_000).input, 0.50);
    }

    #[test]
    fn models_by_id_family_and_default() {
        assert_eq!(price("claude-fable-5-1", 0).cache_read, 0.25);
        assert_eq!(price("claude-fable-5", 0).cache_read, 1.0);
        assert_eq!(price("claude-opus-5", 0).input, 5.0);
        assert_eq!(price("claude-opus-4-5@20251101", 0).input, 4.0, "an unknown opus gets Opus 5.5");
        assert_eq!(price("anthropic.claude-sonnet-4-6", 0).input, 3.0);
        assert_eq!(price("claude-sonnet-5", 0), price("claude-sonnet-5-5", 0));
        assert_eq!(price("claude-haiku-4-5", 0).cache_write_1h, 2.0);
        assert_eq!(price("claude-sonnet-9", 0), price("claude-sonnet-5-5", 0));
        assert_eq!(price("something-else", 0), price("claude-opus-5-5", 0));
    }
}
