use serde::Serialize;
use std::{fs, path::Path};

#[derive(Serialize)]
pub struct Cpu {
    pub id: u32,
    pub online: Option<bool>,
}
#[derive(Serialize)]
pub struct Policy {
    pub id: u32,
    pub related_cpus: Option<String>,
    pub hardware_max_khz: Option<i64>,
    pub current_khz: Option<i64>,
    pub limit_khz: Option<i64>,
}
#[derive(Serialize)]
pub struct Snapshot {
    pub cpus: Vec<Cpu>,
    pub policies: Vec<Policy>,
    pub battery_temperature_mc: Option<i64>,
    pub battery_status: Option<String>,
    pub gpu_max_hz: Option<i64>,
    pub gpu_max_pwrlevel: Option<i64>,
    pub gpu_num_pwrlevels: Option<i64>,
    // Missing or unreadable nodes remain null; no guessed readings.
    pub unavailable: Vec<&'static str>,
}
fn text(path: &Path) -> Option<String> {
    fs::read_to_string(path).ok().map(|s| s.trim().to_owned()).filter(|s| !s.is_empty())
}
fn number(path: &Path) -> Option<i64> { text(path)?.parse().ok() }
fn entries(path: &Path, prefix: &str) -> Vec<(u32, std::path::PathBuf)> {
    let mut out = Vec::new();
    if let Ok(dir) = fs::read_dir(path) {
        for entry in dir.flatten() {
            let name = entry.file_name();
            if let Some(id) = name.to_str().and_then(|n| n.strip_prefix(prefix)).and_then(|s| s.parse().ok()) {
                out.push((id, entry.path()));
            }
        }
    }
    out.sort_by_key(|item| item.0);
    out
}
pub fn collect(sys: &Path) -> Snapshot {
    let cpu_root = sys.join("devices/system/cpu");
    let global_online = text(&cpu_root.join("online"));
    let cpus: Vec<_> = entries(&cpu_root, "cpu").into_iter().map(|(id, path)| {
        let online = match number(&path.join("online")) {
            Some(0) => Some(false), Some(1) => Some(true), _ => None,
        }.or_else(|| global_online.as_deref().and_then(|s| in_cpu_list(s, id)));
        Cpu { id, online }
    }).collect();
    let policies: Vec<_> = entries(&cpu_root.join("cpufreq"), "policy").into_iter().map(|(id, path)| Policy {
        id, related_cpus: text(&path.join("related_cpus")),
        hardware_max_khz: number(&path.join("cpuinfo_max_freq")),
        current_khz: number(&path.join("scaling_cur_freq")),
        limit_khz: number(&path.join("scaling_max_freq")),
    }).collect();
    let battery = sys.join("class/power_supply/battery");
    let battery_temperature_mc = number(&battery.join("temp")).filter(|t| (-200..=1000).contains(t)).map(|t| t * 100);
    let battery_status = text(&battery.join("status"));
    let gpu = sys.join("class/kgsl/kgsl-3d0");
    let gpu_max_hz = number(&gpu.join("max_gpuclk"));
    let gpu_max_pwrlevel = number(&gpu.join("max_pwrlevel"));
    let gpu_num_pwrlevels = number(&gpu.join("num_pwrlevels"));
    let mut unavailable = Vec::new();
    if cpus.is_empty() { unavailable.push("cpus"); }
    if policies.is_empty() { unavailable.push("policies"); }
    if battery_temperature_mc.is_none() { unavailable.push("battery_temperature"); }
    if battery_status.is_none() { unavailable.push("battery_status"); }
    if gpu_max_hz.is_none() { unavailable.push("gpu_max_hz"); }
    Snapshot { cpus, policies, battery_temperature_mc, battery_status, gpu_max_hz, gpu_max_pwrlevel, gpu_num_pwrlevels, unavailable }
}
fn in_cpu_list(list: &str, id: u32) -> Option<bool> {
    let mut found = false;
    for item in list.split(',') {
        let mut bounds = item.trim().split('-');
        let start: u32 = bounds.next()?.parse().ok()?;
        let end: u32 = match bounds.next() { Some(v) => v.parse().ok()?, None => start };
        if bounds.next().is_some() || start > end { return None; }
        found |= (start..=end).contains(&id);
    }
    Some(found)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn global_online_list_is_strict() {
        assert_eq!(in_cpu_list("0-3,6", 0), Some(true));
        assert_eq!(in_cpu_list("0-3,6", 5), Some(false));
        assert_eq!(in_cpu_list("0-x", 0), None);
        assert_eq!(in_cpu_list("3-1", 2), None);
    }
}