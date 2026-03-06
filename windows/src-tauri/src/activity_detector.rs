use std::time::{Duration, SystemTime};

/// Mirrors the macOS ActivityState enum exactly.
/// Without hook events we approximate from JSONL mtime — good enough for WSL.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ActivityState {
    /// Claude is actively writing/running tools right now (mtime < 30s)
    ActivelyWorking,
    /// Claude stopped and is waiting for the user to respond (30s–5min)
    NeedsAttention,
    /// Claude is idle, session still open (5min–24h)
    IdleWaiting,
    /// Session ended cleanly (24h–7d)
    Ended,
    /// Very stale — no hook data, file old (> 7d)
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

/// Detect session activity from JSONL mtime.
///
/// Without hook events we can only approximate from file modification time.
/// Critically, mtime alone CANNOT confirm "actively working" — a file touched
/// 10 seconds ago might just be a session sitting at a prompt. Only hooks
/// (UserPromptSubmit → Stop) can confirm Claude is processing.
///
/// Thresholds match the macOS poll-only path (no hooks):
///   < 5min  → idle/waiting (session recently active, possibly at prompt)
///   < 1hr   → needs attention (Claude likely finished, waiting for user)
///   < 24h   → ended
///   else    → stale
pub fn detect_activity(jsonl_path: &str) -> ActivityState {
    let mtime = std::fs::metadata(jsonl_path)
        .and_then(|m| m.modified())
        .unwrap_or(SystemTime::UNIX_EPOCH);

    let elapsed = SystemTime::now()
        .duration_since(mtime)
        .unwrap_or(Duration::MAX);

    if elapsed < Duration::from_secs(5 * 60) {
        // Recently active — but without hooks we can't confirm Claude is working.
        // Show as idle/waiting (no spinner), matching macOS poll behaviour.
        ActivityState::IdleWaiting
    } else if elapsed < Duration::from_secs(3600) {
        ActivityState::NeedsAttention
    } else if elapsed < Duration::from_secs(86400) {
        ActivityState::Ended
    } else {
        ActivityState::Stale
    }
}
