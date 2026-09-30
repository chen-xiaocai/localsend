//! `peers.json`: the devices known to a running `receive` daemon.
//!
//! While the daemon runs it owns the port, so a `devices` command cannot run
//! the full discovery itself. The daemon keeps this file up to date instead,
//! and `devices` merges it into its own results.

use localsend::discovery::StatefulDevice;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// How often the daemon rewrites the file.
pub const WRITE_INTERVAL: Duration = Duration::from_secs(5);

/// The file is ignored when the daemon has not written it for this long
/// (it is not running any more).
pub const MAX_FILE_AGE: Duration = Duration::from_secs(15);

/// A device is listed when it was confirmed within this time. The daemon
/// re-announces and re-probes more often than that.
pub const MAX_PEER_AGE: Duration = Duration::from_secs(120);

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerAddress {
    pub host: String,
    pub port: u16,
    pub protocol: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerRecord {
    pub alias: String,
    pub fingerprint: String,
    pub device_model: Option<String>,
    pub device_type: Option<String>,
    pub version: String,
    pub addresses: Vec<PeerAddress>,

    /// Unix seconds of the last confirmation.
    pub last_seen: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PeersFile {
    /// Unix seconds of the last write.
    pub updated_at: u64,
    pub peers: Vec<PeerRecord>,
}

pub fn unix_now() -> u64 {
    unix_seconds(SystemTime::now())
}

fn unix_seconds(time: SystemTime) -> u64 {
    time.duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

impl PeerRecord {
    pub fn from_device(device: &StatefulDevice) -> Self {
        let addresses = device
            .get_ranked_channels()
            .into_iter()
            .filter_map(|channel| channel.http())
            .map(|http| PeerAddress {
                host: http.host.clone(),
                port: http.port,
                protocol: http.protocol.as_str().to_string(),
            })
            .collect();
        let last_seen = device
            .logs
            .last()
            .map(|log| unix_seconds(log.timestamp))
            .unwrap_or_else(unix_now);
        Self {
            alias: device.device.alias.clone(),
            fingerprint: device.device.fingerprint.clone(),
            device_model: device.device.device_model.clone(),
            device_type: device
                .device
                .device_type
                .as_ref()
                .map(|t| format!("{t:?}").to_lowercase()),
            version: device.device.version.clone(),
            addresses,
            last_seen,
        }
    }
}

/// `$XDG_STATE_HOME/localsend-cli/peers.json`, or `~/.local/state/localsend-cli/peers.json`.
pub fn path() -> PathBuf {
    std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| dirs::home_dir().map(|home| home.join(".local").join("state")))
        .unwrap_or_else(|| PathBuf::from("."))
        .join("localsend-cli")
        .join("peers.json")
}

/// Writes the file atomically (temporary file + rename), so a concurrent
/// reader never sees a half-written file.
pub fn write(path: &Path, file: &PeersFile) -> anyhow::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(file)?)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

/// The recently confirmed peers of a daemon that is still writing the file,
/// or an empty list.
pub fn read_fresh(path: &Path, now: u64) -> Vec<PeerRecord> {
    let Ok(bytes) = std::fs::read(path) else {
        return Vec::new();
    };
    let Ok(file) = serde_json::from_slice::<PeersFile>(&bytes) else {
        return Vec::new();
    };
    fresh_peers(file, now)
}

fn fresh_peers(file: PeersFile, now: u64) -> Vec<PeerRecord> {
    if now.saturating_sub(file.updated_at) > MAX_FILE_AGE.as_secs() {
        return Vec::new();
    }
    file.peers
        .into_iter()
        .filter(|peer| now.saturating_sub(peer.last_seen) <= MAX_PEER_AGE.as_secs())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn peer(fingerprint: &str, last_seen: u64) -> PeerRecord {
        PeerRecord {
            alias: fingerprint.to_uppercase(),
            fingerprint: fingerprint.to_string(),
            device_model: None,
            device_type: Some("mobile".to_string()),
            version: "2.1".to_string(),
            addresses: vec![PeerAddress {
                host: "192.168.1.2".to_string(),
                port: 53317,
                protocol: "https".to_string(),
            }],
            last_seen,
        }
    }

    #[test]
    fn a_stale_file_yields_nothing() {
        let file = PeersFile {
            updated_at: 1000,
            peers: vec![peer("a", 1000)],
        };
        assert!(fresh_peers(file, 1000 + MAX_FILE_AGE.as_secs() + 1).is_empty());
    }

    #[test]
    fn only_recently_seen_peers_are_returned() {
        let file = PeersFile {
            updated_at: 1000,
            peers: vec![
                peer("old", 1000 - MAX_PEER_AGE.as_secs() - 1),
                peer("new", 990),
            ],
        };
        let fresh = fresh_peers(file, 1005);
        assert_eq!(fresh.len(), 1);
        assert_eq!(fresh[0].fingerprint, "new");
    }

    #[test]
    fn write_and_read_round_trip() {
        let dir =
            std::env::temp_dir().join(format!("localsend-cli-peers-test-{}", uuid::Uuid::new_v4()));
        let path = dir.join("peers.json");
        let now = unix_now();
        let file = PeersFile {
            updated_at: now,
            peers: vec![peer("a", now)],
        };
        write(&path, &file).unwrap();
        assert_eq!(read_fresh(&path, now), file.peers);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
