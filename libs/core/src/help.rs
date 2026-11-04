//! The texts for people and agents. `ccop guide` prints the guide. The app
//! bundle has the help as `help.html` (the CLI's hidden `help-page` command
//! makes it at build time); the page's Copy for Agent copies only the guide,
//! because every token of it costs the session it is pasted into.

const GUIDE: &str = include_str!("guide.md");
const HELP: &str = include_str!("help.md");

/// The workspace version: the app and the CLI share it.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// The guide must stay small: it goes into an agent's context.
pub const GUIDE_MAX_BYTES: usize = 3_000;

pub fn guide() -> &'static str {
    GUIDE
}

/// The help page's Markdown, with the guide as its last section.
pub fn help() -> String {
    HELP.replace("{{VERSION}}", VERSION).replace("{{GUIDE}}", demote(GUIDE).trim_end()) + "\n"
}

/// The guide without its title, every heading one level lower.
fn demote(text: &str) -> String {
    let mut out = String::new();
    let mut in_code = false;
    for (i, line) in text.lines().enumerate() {
        if i == 0 && line.starts_with("# ") {
            continue;
        }
        if line.trim_start().starts_with("```") {
            in_code = !in_code;
        }
        if !in_code && line.starts_with('#') {
            out.push('#');
        }
        out.push_str(line);
        out.push('\n');
    }
    out.trim_start().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_guide_stays_small() {
        assert!(guide().len() <= GUIDE_MAX_BYTES, "the guide has {} bytes", guide().len());
    }

    #[test]
    fn the_help_has_the_version_and_the_guide_one_level_down() {
        let text = help();
        assert!(text.starts_with("# ccop help\n"), "{}", &text[..20]);
        assert!(text.contains(VERSION));
        assert!(!text.contains("{{"), "a placeholder is left");
        assert!(text.contains("### Rules"));
        assert!(!text.contains("\n## Rules"));
        assert!(!text.contains(guide().lines().next().unwrap()), "the guide's title is left out");
    }

    #[test]
    fn a_heading_in_a_code_block_stays_as_it_is() {
        assert_eq!(demote("# Title\n\n## A\n```\n# comment\n```\n"), "### A\n```\n# comment\n```\n");
    }
}
