mod config;
mod probe;

use config::Config;
use serde_json::json;
use std::{env, io::{self, Write}, path::PathBuf, process, thread, time::{Duration, SystemTime, UNIX_EPOCH}};

struct Options {
    watch: bool,
    config: PathBuf,
    sys: PathBuf,
    module: PathBuf,
}
fn options() -> Result<Options, String> {
    let mut opts = Options {
        watch: false,
        config: "/data/adb/modules/CoreGate/data/config.json".into(),
        sys: "/sys".into(),
        module: "/data/adb/modules/CoreGate".into(),
    };
    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--once" => opts.watch = false,
            "--watch" => opts.watch = true,
            "--config" | "--sys-root" | "--module-dir" => {
                let value = PathBuf::from(args.next().ok_or_else(|| format!("missing value: {arg}"))?);
                match arg.as_str() {
                    "--config" => opts.config = value,
                    "--sys-root" => opts.sys = value,
                    _ => opts.module = value,
                }
            }
            "--help" => {
                println!("coregated [--once|--watch] [--config PATH] [--sys-root PATH] [--module-dir PATH]\nRead-only JSON observer; no device writes or policy execution.");
                process::exit(0);
            }
            _ => return Err(format!("unknown argument: {arg}")),
        }
    }
    Ok(opts)
}
fn module_active(opts: &Options) -> bool {
    let sibling_disabled = opts.module.file_name().and_then(|n| n.to_str())
        .map(|n| opts.module.with_file_name(format!("{n}.disable")).exists()).unwrap_or(false);
    opts.module.join("module.prop").is_file()
        && !opts.module.join("disable").exists()
        && !opts.module.join("remove").exists()
        && !sibling_disabled
}
fn run(opts: Options) -> Result<(), String> {
    let stdout = io::stdout();
    let mut out = stdout.lock();
    loop {
        if opts.watch && !module_active(&opts) { return Ok(()); }
        // Read and parse one complete document per sample. Invalid JSON is
        // reported explicitly and is never substituted with an enabled policy.
        let (config, error) = match Config::load(&opts.config) {
            Ok(c) => (Some(c), None),
            Err(e) => (None, Some(e)),
        };
        let interval = config.as_ref().map(Config::interval).unwrap_or(10);
        let snapshot = probe::collect(&opts.sys);
        // Resolve the GPU preset against this device's available levels.
        let mut config = config;
        if let (Some(c), Some(levels)) = (&mut config, snapshot.gpu_num_pwrlevels) {
            let level = c.effective.get("cap_gpu_pwrlevel").and_then(|v| v.as_i64()).unwrap_or(13);
            if level >= levels { c.effective.insert("cap_gpu_pwrlevel".into(), 13.into()); }
        }
        let record = json!({
            "schema_version": 1,
            "read_only": true,
            "timestamp_ms": SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis(),
            "config_valid": error.is_none(),
            "config_error": error,
            "config": config,
            "hardware": snapshot,
        });
        serde_json::to_writer(&mut out, &record).map_err(|e| e.to_string())?;
        out.write_all(b"\n").and_then(|_| out.flush()).map_err(|e| e.to_string())?;
        if !opts.watch { return if config_is_valid(&record) { Ok(()) } else { Err("configuration unavailable or invalid".into()) }; }
        // Check module removal at most one second later, independently of the
        // configured sampling interval. No shared shell PID/state files exist.
        for _ in 0..interval {
            thread::sleep(Duration::from_secs(1));
            if !module_active(&opts) { return Ok(()); }
        }
    }
}
fn config_is_valid(record: &serde_json::Value) -> bool {
    record.get("config_valid").and_then(|v| v.as_bool()).unwrap_or(false)
}
fn main() {
    if let Err(error) = options().and_then(run) {
        eprintln!("coregated: {error}");
        process::exit(1);
    }
}