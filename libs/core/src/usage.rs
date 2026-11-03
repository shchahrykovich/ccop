//! Token counts. Each answer of the model has `message.usage` in its
//! `assistant` record. Claude Code writes one answer as several lines (one
//! per content block: thinking, text, tool use), each with the same
//! `message.id`, `requestId` and full usage, so each answer counts once.

use std::ops::{AddAssign, SubAssign};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Usage {
    /// Input tokens the model read new, not from the cache.
    pub input_tokens: u64,
    /// Input tokens written to the prompt cache.
    pub cache_write_tokens: u64,
    /// The part of `cache_write_tokens` written with the 1-hour TTL, which
    /// costs more than the 5-minute one.
    #[serde(default)]
    pub cache_write_1h_tokens: u64,
    /// Input tokens read from the prompt cache: much cheaper than new input.
    pub cache_read_tokens: u64,
    pub output_tokens: u64,
    /// Calls to the model (answers).
    pub requests: u64,
}

impl Usage {
    pub fn total(&self) -> u64 {
        self.input_tokens + self.cache_write_tokens + self.cache_read_tokens + self.output_tokens
    }

    /// All input the model got: new, written to the cache, and read from it.
    pub fn input_total(&self) -> u64 {
        self.input_tokens + self.cache_write_tokens + self.cache_read_tokens
    }

    /// The part of the input that came from the cache, 0.0 to 1.0.
    pub fn cache_hit_ratio(&self) -> f64 {
        match self.input_total() {
            0 => 0.0,
            all => self.cache_read_tokens as f64 / all as f64,
        }
    }
}

impl AddAssign for Usage {
    fn add_assign(&mut self, o: Usage) {
        self.input_tokens += o.input_tokens;
        self.cache_write_tokens += o.cache_write_tokens;
        self.cache_write_1h_tokens += o.cache_write_1h_tokens;
        self.cache_read_tokens += o.cache_read_tokens;
        self.output_tokens += o.output_tokens;
        self.requests += o.requests;
    }
}

impl SubAssign for Usage {
    fn sub_assign(&mut self, o: Usage) {
        self.input_tokens = self.input_tokens.saturating_sub(o.input_tokens);
        self.cache_write_tokens = self.cache_write_tokens.saturating_sub(o.cache_write_tokens);
        self.cache_write_1h_tokens = self.cache_write_1h_tokens.saturating_sub(o.cache_write_1h_tokens);
        self.cache_read_tokens = self.cache_read_tokens.saturating_sub(o.cache_read_tokens);
        self.output_tokens = self.output_tokens.saturating_sub(o.output_tokens);
        self.requests = self.requests.saturating_sub(o.requests);
    }
}

/// A token count in a few characters: `812`, `46K`, `9.3M`, `1.2B`.
pub fn short(n: u64) -> String {
    match n {
        0..1_000 => n.to_string(),
        1_000..999_500 => format!("{}K", (n as f64 / 1e3).round()),
        999_500..9_950_000 => format!("{:.1}M", n as f64 / 1e6),
        9_950_000..999_500_000 => format!("{}M", (n as f64 / 1e6).round()),
        _ => format!("{:.1}B", n as f64 / 1e9),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_counts() {
        assert_eq!(
            [812, 46_355, 999_499, 999_600, 9_311_043, 9_960_000, 46_000_000, 1_234_000_000].map(short),
            ["812", "46K", "999K", "1.0M", "9.3M", "10M", "46M", "1.2B"]
        );
    }

    #[test]
    fn cache_hit_ratio_is_the_cached_part_of_all_input() {
        let u = Usage { input_tokens: 10, cache_write_tokens: 90, cache_read_tokens: 900, output_tokens: 5, requests: 1, ..Usage::default() };
        assert_eq!(u.total(), 1005);
        assert!((u.cache_hit_ratio() - 0.9).abs() < 1e-9);
        assert_eq!(Usage::default().cache_hit_ratio(), 0.0);
    }
}
