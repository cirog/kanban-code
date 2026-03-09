use std::collections::HashMap;
use std::time::{Duration, SystemTime};

/// Mirrors the macOS ActivityState enum exactly.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ActivityState {
    /// Claude is actively writing/running tools right now
    ActivelyWorking,
    /// Claude stopped and is waiting for the user to respond
    NeedsAttention,
    /// Claude is idle, session still open
    IdleWaiting,
    /// Session ended
    Ended,
    /// Very stale
    Stale,
}

use serde::Serialize;

impl ActivityState {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::ActivelyWorking => "activelyWorking",
            Self::NeedsAttention => "needsAttention",
            Self::IdleWaiting => "idleWaiting",
            Self::Ended => "ended",
            Self::Stale => "stale",
        }
    }
}

/// Tracks JSONL file mtimes across poll cycles to detect whether Claude
/// is actively writing (mtime changing) vs stopped (mtime stable).
#[derive(Debug, Default)]
pub struct ActivityTracker {
    /// Previous mtime per session JSONL path
    prev_mtimes: HashMap<String, SystemTime>,
}

impl ActivityTracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Detect activity for a session by comparing current mtime with previous.
    ///
    /// - mtime changed since last poll AND file is recent → ActivelyWorking
    /// - mtime stable but file modified < 5min ago → NeedsAttention (Claude stopped)
    /// - file modified > 5min ago → Ended
    /// - file modified > 24h ago → Stale
    pub fn detect(&mut self, jsonl_path: &str) -> ActivityState {
        let mtime = std::fs::metadata(jsonl_path)
            .and_then(|m| m.modified())
            .unwrap_or(SystemTime::UNIX_EPOCH);

        let elapsed = SystemTime::now()
            .duration_since(mtime)
            .unwrap_or(Duration::MAX);

        let prev = self.prev_mtimes.insert(jsonl_path.to_string(), mtime);

        // File is old — don't bother comparing mtimes
        if elapsed > Duration::from_secs(86400) {
            return ActivityState::Stale;
        }
        if elapsed > Duration::from_secs(5 * 60) {
            return ActivityState::Ended;
        }

        // File is recent (< 5 min). Did it change since last poll?
        match prev {
            Some(prev_mtime) if mtime != prev_mtime => {
                // mtime changed → Claude is actively writing
                ActivityState::ActivelyWorking
            }
            Some(_) => {
                // mtime stable → Claude stopped, waiting for user
                ActivityState::NeedsAttention
            }
            None => {
                // First time seeing this session — if very fresh, assume active
                if elapsed < Duration::from_secs(10) {
                    ActivityState::ActivelyWorking
                } else {
                    ActivityState::NeedsAttention
                }
            }
        }
    }
}

/// Stateless fallback for one-off checks (used where we don't have a tracker).
pub fn detect_activity(jsonl_path: &str) -> ActivityState {
    let mtime = std::fs::metadata(jsonl_path)
        .and_then(|m| m.modified())
        .unwrap_or(SystemTime::UNIX_EPOCH);

    let elapsed = SystemTime::now()
        .duration_since(mtime)
        .unwrap_or(Duration::MAX);

    if elapsed < Duration::from_secs(10) {
        ActivityState::ActivelyWorking
    } else if elapsed < Duration::from_secs(5 * 60) {
        ActivityState::NeedsAttention
    } else if elapsed < Duration::from_secs(86400) {
        ActivityState::Ended
    } else {
        ActivityState::Stale
    }
}
