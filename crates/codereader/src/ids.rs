//! Identifiers and timestamps.

use std::sync::atomic::{AtomicU64, Ordering};

use chrono::{Local, SecondsFormat};

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// A sortable, human-readable id: `YYYYMMDD-HHMMSS-xxxx`. The suffix mixes the
/// sub-second clock, the pid and a process counter; callers still check for a
/// collision with an existing file before using it.
pub fn new_id() -> String {
    let now = Local::now();
    let mut mix = u64::from(now.timestamp_subsec_nanos())
        ^ u64::from(std::process::id()).wrapping_mul(0x9E37_79B9_7F4A_7C15)
        ^ COUNTER.fetch_add(1, Ordering::Relaxed).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    mix ^= mix >> 31;
    mix = mix.wrapping_mul(0x94D0_49BB_1331_11EB);
    mix ^= mix >> 29;
    format!("{}-{:04x}", now.format("%Y%m%d-%H%M%S"), mix & 0xffff)
}

/// Current local time as RFC 3339 with second precision.
pub fn now() -> String {
    Local::now().to_rfc3339_opts(SecondsFormat::Secs, false)
}

/// True if `id` is safe to use as a file stem (no path traversal).
pub fn is_valid(id: &str) -> bool {
    !id.is_empty() && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}
