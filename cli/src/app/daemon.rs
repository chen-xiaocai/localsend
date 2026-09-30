//! The `receive` mode for running as a service (systemd): no terminal is
//! needed, incoming transfers are accepted automatically and every event is
//! printed as one plain log line.
//!
//! Besides receiving, the daemon keeps discovering (LAN announcements,
//! paired devices and Tailscale peers) and publishes what it found in
//! `peers.json` for the `devices` command.

use super::{AppEvent, Network, discovery, spawn_staged_discovery, start_network, stop_network};
use crate::peers_file::{self, PeerRecord, PeersFile};
use crate::sanitize;
use crate::storage::Repository;
use crate::tailscale;
use crate::util;
use localsend::discovery::{DiscoveryEvent, DiscoveryHandle, HttpChannel};
use localsend::http::server::common::save::FileUploadTarget;
use localsend::http::server::v2::{PrepareUploadDecisionV2, ServerEventV2, SessionEndReasonV2};
use localsend::model::transfer::FileDto;
use localsend::util::filename;
use std::collections::{HashMap, HashSet};
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::signal::unix::{SignalKind, signal};
use tokio::sync::{mpsc, oneshot};

/// How often the daemon announces itself and probes the known and Tailscale
/// addresses again, so that `peers.json` stays current.
const REDISCOVERY_INTERVAL: Duration = Duration::from_secs(30);

struct Session {
    session_id: String,
    alias: String,
    ip: String,
    fingerprint: String,
    files: HashMap<String, FileDto>,
    /// file id -> destination path, for the files still being received.
    in_flight: HashMap<String, PathBuf>,
    finished: usize,
    failed: usize,
    bytes: u64,
    started: Instant,
    ended: Option<SessionEndReasonV2>,
}

fn log(tag: &str, text: &str) {
    println!("[{tag}] {text}");
}

pub(super) async fn run(storage: Repository, only_paired: bool) -> anyhow::Result<()> {
    let identity = storage.identity.clone();
    let (events_tx, mut events_rx) = mpsc::channel::<AppEvent>(64);
    let Network {
        server,
        server_stop_tx,
        server_tx: _,
        mut server_rx,
        discovery,
        mut discovery_rx,
        discovery_stop_tx,
    } = start_network(&identity, super::TAILSCALE_DISCOVERY_TIMEOUT).await?;

    log(
        "I",
        &format!(
            "receive_started alias={:?} port={} fingerprint={} destination={} only_paired={only_paired} peers_file={}",
            identity.alias,
            identity.port,
            identity.fingerprint,
            storage.destination.display(),
            peers_file::path().display(),
        ),
    );

    let tailscale_channels = tailscale_channels(identity.port).await;
    let mut known_channels = storage.paired.known_http_channels();
    known_channels.extend(tailscale_channels);
    spawn_staged_discovery(
        discovery.clone(),
        events_tx.clone(),
        known_channels,
        identity.port,
    );

    let peers_path = peers_file::path();
    let mut write_tick = tokio::time::interval(peers_file::WRITE_INTERVAL);
    write_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut rediscovery_tick = tokio::time::interval_at(
        tokio::time::Instant::now() + REDISCOVERY_INTERVAL,
        REDISCOVERY_INTERVAL,
    );
    rediscovery_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut sigterm = signal(SignalKind::terminate())?;

    let mut session: Option<Session> = None;
    let result = loop {
        tokio::select! {
            Some(event) = server_rx.recv() => {
                if let Err(err) = handle_server_event(&storage, &discovery, &events_tx, &mut session, only_paired, event) {
                    // The server is gone; exit so that the service manager restarts the daemon.
                    break Err(err);
                }
            }
            Some(event) = discovery_rx.recv() => handle_discovery(event),
            Some(event) = events_rx.recv() => match event {
                AppEvent::ReceiveFileResult { session_id, file_id, result } => {
                    receive_file_result(&mut session, session_id, file_id, result);
                }
                AppEvent::Log { category, text } => log(category.tag(), &text),
                _ => {}
            },
            _ = write_tick.tick() => write_peers(&peers_path, &discovery),
            _ = rediscovery_tick.tick() => {
                let known = storage.paired.known_http_channels();
                spawn_rediscovery(discovery.clone(), known, identity.port);
            }
            _ = tokio::signal::ctrl_c() => break Ok(()),
            _ = sigterm.recv() => break Ok(()),
        }
    };

    log("I", &format!("receive_stopped result={result:?}"));
    stop_network(&server, Some(server_stop_tx), &discovery, discovery_stop_tx).await;
    let _ = std::fs::remove_file(&peers_path);
    result
}

async fn tailscale_channels(port: u16) -> Vec<HttpChannel> {
    match tailscale::peers().await {
        Ok(peers) => {
            log("D", &format!("tailscale_peers {peers:?}"));
            tailscale::channels(&peers, port)
        }
        Err(err) => {
            log("D", &format!("tailscale_unavailable error={err:#}"));
            Vec::new()
        }
    }
}

fn spawn_rediscovery(discovery: Arc<DiscoveryHandle>, mut known: Vec<HttpChannel>, port: u16) {
    tokio::spawn(async move {
        known.extend(tailscale_channels(port).await);
        let probe = discovery.discover_known_http_channels(known);
        let (_, probed) = tokio::join!(discovery.announce(), probe);
        if let Err(err) = probed {
            log("D", &format!("rediscovery_failed error={err}"));
        }
    });
}

fn write_peers(path: &Path, discovery: &DiscoveryHandle) {
    let file = PeersFile {
        updated_at: peers_file::unix_now(),
        peers: discovery
            .devices()
            .iter()
            .map(PeerRecord::from_device)
            .collect(),
    };
    if let Err(err) = peers_file::write(path, &file) {
        log(
            "D",
            &format!(
                "peers_file_write_failed path={} error={err:#}",
                path.display()
            ),
        );
    }
}

fn handle_discovery(event: DiscoveryEvent) {
    match event {
        DiscoveryEvent::Discovered { device } => {
            let address = device
                .http()
                .map(|http| format!("{}:{} {}", http.host, http.port, http.protocol.as_str()))
                .unwrap_or_default();
            log(
                "D",
                &format!(
                    "discovered alias={:?} fingerprint={} address={address} model={:?} type={:?} version={}",
                    sanitize::single_line(&device.alias),
                    device.fingerprint,
                    device.device_model,
                    device.device_type,
                    device.version,
                ),
            );
        }
        // Re-confirmations only refresh the store (and thereby peers.json).
        DiscoveryEvent::Updated { .. } => {}
        DiscoveryEvent::MulticastFailed => log("D", "multicast_failed"),
    }
}

fn handle_server_event(
    storage: &Repository,
    discovery: &Arc<DiscoveryHandle>,
    events_tx: &mpsc::Sender<AppEvent>,
    session: &mut Option<Session>,
    only_paired: bool,
    event: ServerEventV2,
) -> anyhow::Result<()> {
    match event {
        ServerEventV2::Register { ip, info } => {
            discovery::device_confirmed(
                discovery,
                &storage.identity.fingerprint,
                ip.to_string(),
                info,
            );
        }
        ServerEventV2::PrepareUpload {
            session_id,
            ip,
            info,
            cert_fingerprint,
            files,
            decision_tx,
        } => {
            discovery::device_confirmed(
                discovery,
                &storage.identity.fingerprint,
                ip.to_string(),
                info.clone(),
            );
            let alias = sanitize::single_line(&info.alias);
            let fingerprint = cert_fingerprint.unwrap_or_else(|| info.fingerprint.clone());

            if let Some(message) = message_of(&files) {
                // The text is the whole request; accepting no file ends the session.
                let _ = decision_tx.send(PrepareUploadDecisionV2::Accept(HashSet::new()));
                log(
                    "R",
                    &format!(
                        "message_received alias={alias:?} ip={ip} fingerprint={fingerprint} text={:?}",
                        sanitize::multi_line(message)
                    ),
                );
                return Ok(());
            }

            let mut listed: Vec<&FileDto> = files.values().collect();
            listed.sort_by(|a, b| a.id.cmp(&b.id));
            let listed: Vec<String> = listed
                .iter()
                .map(|file| {
                    format!(
                        "{}({} bytes)",
                        sanitize::single_line(&file.file_name),
                        file.size
                    )
                })
                .collect();

            if only_paired && !storage.paired.contains(&fingerprint) {
                let _ = decision_tx.send(PrepareUploadDecisionV2::Decline);
                log(
                    "R",
                    &format!(
                        "request_declined reason=not_paired alias={alias:?} ip={ip} fingerprint={fingerprint} files={listed:?}"
                    ),
                );
                return Ok(());
            }

            let ids: HashSet<String> = files.keys().cloned().collect();
            if decision_tx
                .send(PrepareUploadDecisionV2::Accept(ids))
                .is_err()
            {
                log(
                    "R",
                    &format!("request_already_ended alias={alias:?} session={session_id}"),
                );
                return Ok(());
            }
            log(
                "R",
                &format!(
                    "request_accepted alias={alias:?} ip={ip} fingerprint={fingerprint} session={session_id} files={listed:?}"
                ),
            );
            *session = Some(Session {
                session_id,
                alias,
                ip: ip.to_string(),
                fingerprint,
                files,
                in_flight: HashMap::new(),
                finished: 0,
                failed: 0,
                bytes: 0,
                started: Instant::now(),
                ended: None,
            });
        }
        ServerEventV2::FileUpload {
            session_id,
            file_id,
            file,
            target_tx,
        } => handle_file_upload(
            storage, events_tx, session, session_id, file_id, file, target_tx,
        ),
        ServerEventV2::SessionEnd { session_id, reason } => {
            if let Some(current) = session.as_mut().filter(|s| s.session_id == session_id) {
                current.ended = Some(reason);
                finish_if_done(session);
            }
        }
        ServerEventV2::PrepareUploadAborted { session_id } => {
            log(
                "R",
                &format!("request_aborted_by_sender session={session_id}"),
            );
        }
        ServerEventV2::CancelReceived { ip, session_id } => {
            log(
                "R",
                &format!("cancel_received ip={ip} session={session_id}"),
            );
        }
        ServerEventV2::ListenerFailed { error } => {
            log("R", &format!("server_stopped error={error}"));
            anyhow::bail!("HTTP server stopped: {error}");
        }
    }
    Ok(())
}

fn handle_file_upload(
    storage: &Repository,
    events_tx: &mpsc::Sender<AppEvent>,
    session: &mut Option<Session>,
    session_id: String,
    file_id: String,
    file: FileDto,
    target_tx: oneshot::Sender<FileUploadTarget>,
) {
    let Some(current) = session.as_mut().filter(|s| s.session_id == session_id) else {
        // Unknown session: dropping the responder fails the request.
        return;
    };

    let path = match save_path(&storage.destination, &file.file_name) {
        Ok(path) => path,
        Err(err) => {
            current.failed += 1;
            log(
                "R",
                &format!(
                    "file_rejected session={session_id} file_id={file_id} name={:?} error={err}",
                    file.file_name
                ),
            );
            return;
        }
    };
    current.in_flight.insert(file_id.clone(), path.clone());

    let (result_tx, result_rx) = oneshot::channel::<Result<(), String>>();
    let events_tx = events_tx.clone();
    tokio::spawn(async move {
        let result = result_rx
            .await
            .unwrap_or_else(|_| Err("Upload aborted".to_string()));
        let _ = events_tx
            .send(AppEvent::ReceiveFileResult {
                session_id,
                file_id,
                result,
            })
            .await;
    });
    let _ = target_tx.send(FileUploadTarget::Path {
        path,
        result_tx,
        progress_tx: None,
    });
}

fn receive_file_result(
    session: &mut Option<Session>,
    session_id: String,
    file_id: String,
    result: Result<(), String>,
) {
    let Some(current) = session.as_mut().filter(|s| s.session_id == session_id) else {
        return;
    };
    let path = current.in_flight.remove(&file_id);
    let size = current
        .files
        .get(&file_id)
        .map(|file| file.size)
        .unwrap_or(0);
    match result {
        Ok(()) => {
            current.finished += 1;
            current.bytes += size;
            log(
                "R",
                &format!(
                    "file_saved session={session_id} file_id={file_id} size={size} path={}",
                    path.map(|p| p.display().to_string()).unwrap_or_default()
                ),
            );
        }
        Err(err) => {
            current.failed += 1;
            log(
                "R",
                &format!(
                    "file_failed session={session_id} file_id={file_id} size={size} path={} error={err}",
                    path.map(|p| p.display().to_string()).unwrap_or_default()
                ),
            );
        }
    }
    finish_if_done(session);
}

/// Logs the summary once the server reported the end of the session and no
/// per-file result is outstanding.
fn finish_if_done(session: &mut Option<Session>) {
    let done = session
        .as_ref()
        .is_some_and(|s| s.ended.is_some() && s.in_flight.is_empty());
    if !done {
        return;
    }
    let s = session.take().unwrap();
    log(
        "R",
        &format!(
            "session_ended reason={:?} alias={:?} ip={} fingerprint={} session={} files={} received={} failed={} bytes={} ({}) took={}",
            s.ended.unwrap(),
            s.alias,
            s.ip,
            s.fingerprint,
            s.session_id,
            s.files.len(),
            s.finished,
            s.failed,
            s.bytes,
            util::format_bytes(s.bytes),
            util::format_duration(s.started.elapsed()),
        ),
    );
}

/// The text of a "message request": a single text file whose content is
/// already included as a preview.
fn message_of(files: &HashMap<String, FileDto>) -> Option<&str> {
    if files.len() != 1 {
        return None;
    }
    let file = files.values().next()?;
    if file.file_type != "text" && !file.file_type.starts_with("text/") {
        return None;
    }
    file.preview.as_deref()
}

/// Where to save a received file.
///
/// Unlike the interactive mode, directory components are kept, so a sent
/// folder arrives as a folder. `file_name` comes from the sender and is
/// untrusted: `..` and absolute names are refused, every component is
/// sanitized, and the directory must still be inside `destination` after
/// resolving symlinks. Existing files are never overwritten (` (1)` suffix).
fn save_path(destination: &Path, file_name: &str) -> Result<PathBuf, String> {
    let normalized = file_name.replace('\\', "/");
    let mut components = Vec::new();
    for part in Path::new(&normalized).components() {
        match part {
            Component::Normal(part) => {
                let sanitized =
                    filename::sanitize(&part.to_string_lossy(), filename::Rules::current());
                if sanitized.is_empty() {
                    return Err(format!("invalid path component in {file_name:?}"));
                }
                components.push(sanitized);
            }
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                return Err(format!("path traversal in {file_name:?}"));
            }
        }
    }
    let Some(name) = components.pop() else {
        return Err(format!("empty file name {file_name:?}"));
    };

    let dir = components
        .iter()
        .fold(destination.to_path_buf(), |dir, part| dir.join(part));
    std::fs::create_dir_all(&dir)
        .map_err(|err| format!("cannot create {}: {err}", dir.display()))?;
    let real_destination = destination
        .canonicalize()
        .map_err(|err| format!("cannot resolve {}: {err}", destination.display()))?;
    let real_dir = dir
        .canonicalize()
        .map_err(|err| format!("cannot resolve {}: {err}", dir.display()))?;
    if !real_dir.starts_with(&real_destination) {
        return Err(format!(
            "{} escapes {} via a symlink",
            dir.display(),
            destination.display()
        ));
    }

    Ok(util::unique_path(&dir, &name))
}

#[cfg(test)]
mod tests {
    use super::save_path;
    use std::path::PathBuf;

    fn temp_dir() -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("localsend-cli-save-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn keeps_folders() {
        let dest = temp_dir();
        let path = save_path(&dest, "photos/2026/a.jpg").unwrap();
        assert_eq!(path, dest.join("photos").join("2026").join("a.jpg"));
        assert!(dest.join("photos").join("2026").is_dir());
        std::fs::remove_dir_all(dest).unwrap();
    }

    #[test]
    fn refuses_traversal_and_absolute_names() {
        let dest = temp_dir();
        assert!(save_path(&dest, "../etc/passwd").is_err());
        assert!(save_path(&dest, "a/../../b").is_err());
        assert!(save_path(&dest, "/etc/passwd").is_err());
        assert!(save_path(&dest, "..\\..\\x").is_err());
        std::fs::remove_dir_all(dest).unwrap();
    }

    #[test]
    fn does_not_overwrite() {
        let dest = temp_dir();
        std::fs::write(dest.join("a.txt"), "x").unwrap();
        assert_eq!(save_path(&dest, "a.txt").unwrap(), dest.join("a (1).txt"));
        std::fs::remove_dir_all(dest).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn refuses_symlink_escapes() {
        let dest = temp_dir();
        let outside = temp_dir();
        std::os::unix::fs::symlink(&outside, dest.join("link")).unwrap();
        assert!(save_path(&dest, "link/a.txt").is_err());
        std::fs::remove_dir_all(dest).unwrap();
        std::fs::remove_dir_all(outside).unwrap();
    }
}
