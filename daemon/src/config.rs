use serde::Serialize;
use serde_json::{Map, Value};
use std::{fs, path::Path};

#[derive(Clone, Serialize)]
pub struct Config {
    // Keep original keys for diagnostics; never rewrite the user's configuration.
    pub raw: Map<String, Value>,
    pub effective: Map<String, Value>,
}

impl Config {
    pub fn load(path: &Path) -> Result<Self, String> {
        let text = fs::read_to_string(path).map_err(|e| format!("config read: {e}"))?;
        Self::parse(&text)
    }

    pub fn parse(text: &str) -> Result<Self, String> {
        let value: Value = serde_json::from_str(text).map_err(|e| format!("config JSON: {e}"))?;
        let raw = value.as_object().ok_or("config must be a JSON object")?.clone();
        let defaults: Value = serde_json::from_str(include_str!("../../config.example.json"))
            .map_err(|e| format!("embedded defaults: {e}"))?;
        let mut effective = defaults.as_object().ok_or("embedded defaults must be an object")?.clone();
        for (key, fallback) in &mut effective {
            if let Some(value) = raw.get(key) {
                let valid = match &*fallback {
                    Value::Bool(_) => value.is_boolean(),
                    Value::Number(_) => value.as_i64().is_some(),
                    Value::String(_) => value.as_str().map(|s| !s.is_empty()).unwrap_or(false),
                    _ => false,
                };
                if valid { *fallback = value.clone(); }
            }
        }
        for (key, default, min, max) in [
            ("poll_interval", 10, 5, 600),
            ("auto_lock_count", 1, 1, 4),
            ("temperature_threshold", 40, 35, 60),
        ] {
            let mut n = effective.get(key).and_then(Value::as_i64).unwrap_or(default);
            // The shell treats negative intervals/thresholds as invalid input.
            if key != "auto_lock_count" && n < 0 { n = default; }
            effective.insert(key.into(), Value::from(n.clamp(min, max)));
        }
        if effective.get("temperature_mode").and_then(Value::as_str) != Some("unlock") {
            effective.insert("temperature_mode".into(), Value::from("lock"));
        }
        for (key, fallback) in [("cap_little_mhz", 2266), ("cap_big_mhz", 1651), ("cap_gpu_mhz", 500)] {
            if effective.get(key).and_then(Value::as_i64).unwrap_or(0) <= 0 {
                effective.insert(key.into(), Value::from(fallback));
            }
        }
        let level = effective.get("cap_gpu_pwrlevel").and_then(Value::as_i64).unwrap_or(-1);
        if level < 0 { effective.insert("cap_gpu_pwrlevel".into(), Value::from(13)); }
        Ok(Self { raw, effective })
    }

    pub fn interval(&self) -> u64 {
        self.effective.get("poll_interval").and_then(Value::as_u64).unwrap_or(10)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compact_json_and_unknown_fields_survive() {
        let c = Config::parse(r#"{"enabled":false,"poll_interval":601,"future":"keep"}"#).unwrap();
        assert_eq!(c.effective["enabled"], false);
        assert_eq!(c.interval(), 600);
        assert_eq!(c.raw["future"], "keep");
        assert_eq!(c.effective["auto_lock_count"], 1);
    }

    #[test]
    fn malformed_document_is_not_silently_defaulted() {
        assert!(Config::parse("{\"enabled\":").is_err());
        assert!(Config::parse("[]").is_err());
        let c = Config::parse(r#"{"poll_interval":-1,"temperature_threshold":80,"limit_freq":"true"}"#).unwrap();
        assert_eq!(c.interval(), 10);
        assert_eq!(c.effective["temperature_threshold"], 60);
        assert_eq!(c.effective["limit_freq"], false);
    }
}