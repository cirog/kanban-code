use anyhow::{Context, Result};
use portable_pty::{CommandBuilder, NativePtySystem, PtySize, PtySystem};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::Arc;
use tokio::sync::Mutex;

/// Manages multiple PTY sessions, each identified by a string key.
pub struct PtyManager {
    sessions: Mutex<HashMap<String, PtySession>>,
}

struct PtySession {
    writer: Box<dyn Write + Send>,
    _child: Box<dyn portable_pty::Child + Send + Sync>,
    pair: portable_pty::PtyPair,
}

impl PtyManager {
    pub fn new() -> Self {
        Self {
            sessions: Mutex::new(HashMap::new()),
        }
    }

    /// Spawn a new PTY running the given command.
    /// Returns immediately; output is streamed via the callback.
    pub async fn spawn(
        self: &Arc<Self>,
        id: String,
        command: Vec<String>,
        cols: u16,
        rows: u16,
        on_output: impl Fn(String) + Send + 'static,
        on_exit: impl Fn() + Send + 'static,
    ) -> Result<()> {
        let pty_system = NativePtySystem::default();
        let pair = pty_system
            .openpty(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("open PTY")?;

        let mut cmd = CommandBuilder::new(&command[0]);
        for arg in &command[1..] {
            cmd.arg(arg);
        }

        let child = pair.slave.spawn_command(cmd).context("spawn PTY command")?;
        let writer = pair.master.take_writer().context("take PTY writer")?;
        let mut reader = pair.master.try_clone_reader().context("clone PTY reader")?;

        {
            let mut sessions = self.sessions.lock().await;
            sessions.insert(
                id.clone(),
                PtySession {
                    writer,
                    _child: child,
                    pair,
                },
            );
        }

        // Read output in a background thread (blocking I/O)
        let manager = Arc::clone(self);
        let id_clone = id.clone();
        // Capture the tokio handle before spawning the OS thread
        let rt_handle = tokio::runtime::Handle::current();
        std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        let text = String::from_utf8_lossy(&buf[..n]).to_string();
                        on_output(text);
                    }
                    Err(_) => break,
                }
            }
            on_exit();
            // Clean up using the captured handle
            rt_handle.block_on(async {
                let mut sessions = manager.sessions.lock().await;
                sessions.remove(&id_clone);
            });
        });

        Ok(())
    }

    /// Write data to a PTY session's stdin.
    pub async fn write(&self, id: &str, data: &[u8]) -> Result<()> {
        let mut sessions = self.sessions.lock().await;
        if let Some(session) = sessions.get_mut(id) {
            session.writer.write_all(data).context("write to PTY")?;
            session.writer.flush().context("flush PTY")?;
        }
        Ok(())
    }

    /// Resize a PTY session.
    pub async fn resize(&self, id: &str, cols: u16, rows: u16) -> Result<()> {
        let sessions = self.sessions.lock().await;
        if let Some(session) = sessions.get(id) {
            session
                .pair
                .master
                .resize(PtySize {
                    rows,
                    cols,
                    pixel_width: 0,
                    pixel_height: 0,
                })
                .context("resize PTY")?;
        }
        Ok(())
    }

    /// Kill and remove a PTY session.
    pub async fn kill(&self, id: &str) -> Result<()> {
        let mut sessions = self.sessions.lock().await;
        if let Some(mut session) = sessions.remove(id) {
            let _ = session._child.kill();
        }
        Ok(())
    }
}
