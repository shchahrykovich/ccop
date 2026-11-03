//! One tool call in full: its input and the result it gave back. The anatomy
//! JSON keeps only short forms of each call; `ccop call` reads one call in
//! full when the app shows it.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The longest output kept, in characters: a bigger result is cut here.
pub const OUTPUT_CHARS: usize = 200_000;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolCall {
    pub tool_use_id: String,
    /// The tool's name; None when only the result was found.
    pub tool: Option<String>,
    /// The call's input as the model wrote it (`command`, `description`, ...).
    pub input: Value,
    /// The result's text, parts on their own lines; an image as `[image]`.
    /// None while the call has no result.
    pub output: Option<String>,
    /// The size of the whole result, as the anatomy counts it.
    pub output_bytes: u64,
    /// The output was longer than `OUTPUT_CHARS` and is cut.
    pub output_truncated: bool,
    pub is_error: bool,
}

/// Finds one call in the lines of a transcript file. A line is parsed only
/// when it contains the id, so a 16 MB file is read in a few milliseconds.
pub struct CallFinder {
    call: ToolCall,
    found_use: bool,
    found_result: bool,
}

impl CallFinder {
    pub fn new(tool_use_id: &str) -> CallFinder {
        CallFinder {
            call: ToolCall {
                tool_use_id: tool_use_id.to_string(),
                tool: None,
                input: Value::Null,
                output: None,
                output_bytes: 0,
                output_truncated: false,
                is_error: false,
            },
            found_use: false,
            found_result: false,
        }
    }

    pub fn feed(&mut self, line: &str) {
        let id = self.call.tool_use_id.as_str();
        if id.is_empty() || !line.contains(id) {
            return;
        }
        let Ok(r) = serde_json::from_str::<Value>(line) else { return };
        let Some(blocks) = r["message"]["content"].as_array() else { return };
        for b in blocks {
            match b.get("type").and_then(Value::as_str) {
                Some("tool_use") if b.get("id").and_then(Value::as_str) == Some(id) => {
                    self.call.tool = b.get("name").and_then(Value::as_str).map(str::to_string);
                    self.call.input = b.get("input").cloned().unwrap_or(Value::Null);
                    self.found_use = true;
                }
                Some("tool_result") if b.get("tool_use_id").and_then(Value::as_str) == Some(id) => {
                    let content = b.get("content").unwrap_or(&Value::Null);
                    let text = output_text(content);
                    self.call.output_bytes = crate::anatomy::result_bytes(content);
                    self.call.output_truncated = text.chars().count() > OUTPUT_CHARS;
                    self.call.output = Some(if self.call.output_truncated { text.chars().take(OUTPUT_CHARS).collect() } else { text });
                    self.call.is_error = b.get("is_error").and_then(Value::as_bool).unwrap_or(false);
                    self.found_result = true;
                }
                _ => {}
            }
        }
    }

    /// Both the call and its result were found: no need to read further.
    pub fn done(&self) -> bool {
        self.found_use && self.found_result
    }

    /// The call, or None when neither the call nor a result was found.
    pub fn finish(self) -> Option<ToolCall> {
        (self.found_use || self.found_result).then_some(self.call)
    }
}

pub(crate) fn output_text(content: &Value) -> String {
    match content {
        Value::String(s) => s.clone(),
        Value::Array(parts) => parts
            .iter()
            .map(|p| match p.get("type").and_then(Value::as_str) {
                Some("image") => "[image]".to_string(),
                _ => p.get("text").and_then(Value::as_str).unwrap_or_default().to_string(),
            })
            .collect::<Vec<_>>()
            .join("\n"),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn find(id: &str, lines: &[Value]) -> (Option<ToolCall>, bool) {
        let mut f = CallFinder::new(id);
        for l in lines {
            f.feed(&l.to_string());
        }
        let done = f.done();
        (f.finish(), done)
    }

    fn use_line(id: &str, command: &str) -> Value {
        json!({"type": "assistant", "message": {"content": [
            {"type": "text", "text": "Reading."},
            {"type": "tool_use", "id": id, "name": "Bash", "input": {"command": command, "description": "Read notes"}}]}})
    }

    #[test]
    fn a_call_and_its_result_are_found() {
        let lines = [
            use_line("t1", "sed -n 1,9p notes/a.md"),
            use_line("t2", "ls"),
            json!({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t2", "content": "a.md"}]}}),
            json!({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "is_error": true,
                   "content": [{"type": "text", "text": "line 1"}, {"type": "text", "text": "line 2"}]}]}}),
        ];
        let (call, done) = find("t1", &lines);
        assert!(done);
        let call = call.unwrap();
        assert_eq!(call.tool.as_deref(), Some("Bash"));
        assert_eq!(call.input["command"], "sed -n 1,9p notes/a.md");
        assert_eq!(call.output.as_deref(), Some("line 1\nline 2"));
        assert_eq!(call.output_bytes, 12);
        assert!(call.is_error);
        assert!(!call.output_truncated);
    }

    #[test]
    fn a_call_without_a_result_and_an_unknown_id() {
        let (call, done) = find("t1", &[use_line("t1", "ls")]);
        assert!(!done);
        let call = call.unwrap();
        assert_eq!(call.output, None);
        assert!(!call.is_error);
        // `t` is in every line, but no block has that id.
        assert_eq!(find("t", &[use_line("t1", "ls")]).0, None);
        assert_eq!(find("", &[use_line("t1", "ls")]).0, None);
    }

    #[test]
    fn a_long_output_is_cut_and_an_image_is_named() {
        let long = "x".repeat(OUTPUT_CHARS + 5);
        let lines = [json!({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "content": long}]}})];
        let call = find("t1", &lines).0.unwrap();
        assert!(call.output_truncated);
        assert_eq!(call.output.unwrap().len(), OUTPUT_CHARS);
        assert_eq!(call.output_bytes, (OUTPUT_CHARS + 5) as u64);
        assert_eq!(call.tool, None);

        let image = [json!({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1",
                     "content": [{"type": "text", "text": "a chart"}, {"type": "image", "source": {"data": "AAAA"}}]}]}})];
        assert_eq!(find("t1", &image).0.unwrap().output.as_deref(), Some("a chart\n[image]"));
    }
}
