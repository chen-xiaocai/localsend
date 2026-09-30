//! The `devices` command: lists the LocalSend devices that are online, found
//! over the LAN (multicast announcements, subnet scan) and over Tailscale
//! (direct probes of every tailnet node).
//!
//! When a `receive` daemon owns the port, its `peers.json` is merged in and
//! only the direct probes run here.

use super::{AppEvent, Network, discovery, spawn_staged_discovery, start_network, stop_network};
use crate::peers_file::{self, PeerRecord};
use crate::storage::Repository;
use crate::tailscale;
use localsend::discovery::{DeviceIdentity, DiscoveryConfig, DiscoveryHandle, HttpChannel};
use localsend::http::server::v2::ServerEventV2;
use localsend::multicast::{DEFAULT_MULTICAST_GROUP, DEFAULT_MULTICAST_GROUP_V6, DEFAULT_PORT};
use localsend::util::interface::InterfaceFilter;
use serde::Serialize;
use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

pub(super) struct Options {
    pub timeout: Duration,
    pub json: bool,
    pub lan: bool,
    pub tailscale: bool,
}

/// One row of the output; the field names match the former Dart CLI.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DeviceRow {
    alias: String,
    ip: String,
    port: u16,
    protocol: String,
    system: String,
    device_type: Option<String>,
    device_model: Option<String>,
    source: &'static str,
    fingerprint: String,
    addresses: Vec<String>,
    last_seen: u64,
}

pub(super) async fn run(storage: Repository, options: Options) -> anyhow::Result<()> {
    let identity = storage.identity.clone();

    let mut probe_channels: Vec<HttpChannel> = Vec::new();
    if options.tailscale {
        match tailscale::peers().await {
            Ok(peers) => probe_channels.extend(tailscale::channels(&peers, DEFAULT_PORT)),
            Err(err) => eprintln!("Tailscale unavailable: {err:#}"),
        }
    }
    if options.lan {
        probe_channels.extend(storage.paired.known_http_channels());
    }

    let mut records: Vec<PeerRecord> = Vec::new();
    match start_network(&identity, super::TAILSCALE_DISCOVERY_TIMEOUT).await {
        Ok(network) => {
            // No daemon is running: run the full discovery here.
            records.extend(discover_with_server(&storage, network, probe_channels, &options).await);
        }
        Err(err) => {
            // The port is taken, most likely by the `receive` daemon.
            let from_daemon = peers_file::read_fresh(&peers_file::path(), peers_file::unix_now());
            if from_daemon.is_empty() && options.lan {
                eprintln!(
                    "Could not start the server ({err:#}) and no running receive daemon was found; LAN results may be incomplete."
                );
            }
            records.extend(
                from_daemon
                    .into_iter()
                    .filter(|record| options.lan || is_tailscale_record(record)),
            );
            records.extend(probe_only(&identity, probe_channels, options.timeout).await);
        }
    }

    let rows = merge(records, &identity.fingerprint, &options);
    if options.json {
        println!("{}", serde_json::to_string_pretty(&rows)?);
        return Ok(());
    }
    if rows.is_empty() {
        println!("No online LocalSend devices found.");
        println!(
            "Tip: Tailscale peers must be online and LocalSend must be running on port {DEFAULT_PORT}."
        );
        return Ok(());
    }
    print_table(&rows);
    Ok(())
}

async fn discover_with_server(
    storage: &Repository,
    network: Network,
    probe_channels: Vec<HttpChannel>,
    options: &Options,
) -> Vec<PeerRecord> {
    let Network {
        server,
        server_stop_tx,
        server_tx: _,
        mut server_rx,
        discovery,
        mut discovery_rx,
        discovery_stop_tx,
    } = network;
    let (events_tx, mut events_rx) = mpsc::channel::<AppEvent>(16);

    if options.lan {
        spawn_staged_discovery(
            discovery.clone(),
            events_tx.clone(),
            probe_channels,
            storage.identity.port,
        );
    } else {
        let discovery = discovery.clone();
        tokio::spawn(async move {
            let _ = discovery.discover_known_http_channels(probe_channels).await;
            let _ = events_tx.send(AppEvent::DiscoveryFinished).await;
        });
    }

    let deadline = tokio::time::sleep(options.timeout);
    tokio::pin!(deadline);
    loop {
        tokio::select! {
            // Peers answer the announcement by registering with our server.
            Some(event) = server_rx.recv() => {
                if let ServerEventV2::Register { ip, info } = event {
                    discovery::device_confirmed(&discovery, &storage.identity.fingerprint, ip.to_string(), info);
                }
            }
            Some(_) = discovery_rx.recv() => {}
            Some(event) = events_rx.recv() => {
                if matches!(event, AppEvent::DiscoveryFinished) && !options.lan {
                    break;
                }
            }
            _ = &mut deadline => break,
        }
    }

    let records = discovery
        .devices()
        .iter()
        .map(PeerRecord::from_device)
        .collect();
    stop_network(&server, Some(server_stop_tx), &discovery, discovery_stop_tx).await;
    records
}

/// Probes the given addresses with a discovery that has no server of its own
/// (the daemon owns the port).
async fn probe_only(
    identity: &crate::storage::Identity,
    channels: Vec<HttpChannel>,
    timeout: Duration,
) -> Vec<PeerRecord> {
    if channels.is_empty() {
        return Vec::new();
    }
    let (_stop_tx, stop_rx) = oneshot::channel::<()>();
    let discovery: Arc<DiscoveryHandle> = Arc::new(
        localsend::discovery::start(
            DiscoveryConfig {
                group: DEFAULT_MULTICAST_GROUP,
                group_v6: Some(DEFAULT_MULTICAST_GROUP_V6),
                port: DEFAULT_PORT,
                interface_filter: InterfaceFilter::default(),
                device: identity.multicast_device(),
                identity: DeviceIdentity {
                    cert_pem: identity.cert_pem.clone(),
                    private_key_pem: identity.key_pem.clone(),
                },
                timeout: super::TAILSCALE_DISCOVERY_TIMEOUT,
                event_tx: None,
            },
            stop_rx,
        )
        .await,
    );
    // Without a server, an answer to an announcement would point to the daemon.
    discovery.set_answer_announcements(false);
    match tokio::time::timeout(timeout, discovery.discover_known_http_channels(channels)).await {
        Ok(Ok(devices)) => devices.iter().map(PeerRecord::from_device).collect(),
        Ok(Err(err)) => {
            eprintln!("Probing failed: {err}");
            Vec::new()
        }
        Err(_) => discovery
            .devices()
            .iter()
            .map(PeerRecord::from_device)
            .collect(),
    }
}

fn is_tailscale_ip(host: &str) -> bool {
    match host
        .split('%')
        .next()
        .and_then(|host| host.parse::<IpAddr>().ok())
    {
        // 100.64.0.0/10 (CGNAT range used by Tailscale)
        Some(IpAddr::V4(ip)) => ip.octets()[0] == 100 && (ip.octets()[1] & 0b1100_0000) == 64,
        // fd7a:115c:a1e0::/48
        Some(IpAddr::V6(ip)) => ip.segments()[..3] == [0xfd7a, 0x115c, 0xa1e0],
        None => false,
    }
}

fn is_tailscale_record(record: &PeerRecord) -> bool {
    record
        .addresses
        .iter()
        .any(|address| is_tailscale_ip(&address.host))
}

/// One row per device (by fingerprint), without this device, LAN addresses
/// before Tailscale ones.
fn merge(records: Vec<PeerRecord>, own_fingerprint: &str, options: &Options) -> Vec<DeviceRow> {
    let mut by_fingerprint: HashMap<String, PeerRecord> = HashMap::new();
    for record in records {
        if record.fingerprint == own_fingerprint {
            continue;
        }
        match by_fingerprint.get_mut(&record.fingerprint) {
            Some(existing) => {
                for address in record.addresses {
                    if !existing.addresses.contains(&address) {
                        existing.addresses.push(address);
                    }
                }
                existing.last_seen = existing.last_seen.max(record.last_seen);
            }
            None => {
                by_fingerprint.insert(record.fingerprint.clone(), record);
            }
        }
    }

    let mut rows: Vec<DeviceRow> = by_fingerprint
        .into_values()
        .filter_map(|mut record| {
            record.addresses.retain(|address| {
                let tailscale = is_tailscale_ip(&address.host);
                (tailscale && options.tailscale) || (!tailscale && options.lan)
            });
            record
                .addresses
                .sort_by_key(|address| is_tailscale_ip(&address.host));
            let primary = record.addresses.first()?.clone();
            let system = match (&record.device_model, &record.device_type) {
                (Some(model), Some(device_type)) => format!("{model} / {device_type}"),
                (Some(model), None) => model.clone(),
                (None, Some(device_type)) => device_type.clone(),
                (None, None) => "unknown".to_string(),
            };
            Some(DeviceRow {
                alias: record.alias,
                ip: primary.host.clone(),
                port: primary.port,
                protocol: primary.protocol.clone(),
                system,
                device_type: record.device_type,
                device_model: record.device_model,
                source: if is_tailscale_ip(&primary.host) {
                    "tailscale"
                } else {
                    "lan"
                },
                fingerprint: record.fingerprint,
                addresses: record
                    .addresses
                    .iter()
                    .map(|address| {
                        format!("{}:{} {}", address.host, address.port, address.protocol)
                    })
                    .collect(),
                last_seen: record.last_seen,
            })
        })
        .collect();
    rows.sort_by(|a, b| a.alias.cmp(&b.alias).then(a.ip.cmp(&b.ip)));
    rows
}

fn print_table(rows: &[DeviceRow]) {
    let table: Vec<[String; 5]> =
        std::iter::once(["Alias", "IP", "System", "Source", "Protocol"].map(String::from))
            .chain(rows.iter().map(|row| {
                [
                    row.alias.clone(),
                    format!("{}:{}", row.ip, row.port),
                    row.system.clone(),
                    row.source.to_string(),
                    row.protocol.clone(),
                ]
            }))
            .collect();
    let widths: Vec<usize> = (0..5)
        .map(|col| {
            table
                .iter()
                .map(|row| row[col].chars().count())
                .max()
                .unwrap_or(0)
        })
        .collect();
    for (i, row) in table.iter().enumerate() {
        let line: Vec<String> = row
            .iter()
            .zip(&widths)
            .map(|(cell, width)| format!("{cell:<width$}"))
            .collect();
        println!("{}", line.join("  ").trim_end());
        if i == 0 {
            let dashes: Vec<String> = row
                .iter()
                .zip(&widths)
                .map(|(cell, width)| format!("{:<width$}", "-".repeat(cell.chars().count())))
                .collect();
            println!("{}", dashes.join("  ").trim_end());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::peers_file::PeerAddress;

    fn record(fingerprint: &str, hosts: &[&str]) -> PeerRecord {
        PeerRecord {
            alias: fingerprint.to_string(),
            fingerprint: fingerprint.to_string(),
            device_model: Some("MacBook".to_string()),
            device_type: Some("desktop".to_string()),
            version: "2.2".to_string(),
            addresses: hosts
                .iter()
                .map(|host| PeerAddress {
                    host: host.to_string(),
                    port: 53317,
                    protocol: "https".to_string(),
                })
                .collect(),
            last_seen: 1,
        }
    }

    fn options(lan: bool, tailscale: bool) -> Options {
        Options {
            timeout: Duration::from_secs(1),
            json: false,
            lan,
            tailscale,
        }
    }

    #[test]
    fn detects_tailscale_addresses() {
        assert!(is_tailscale_ip("100.75.58.59"));
        assert!(is_tailscale_ip("100.127.0.1"));
        assert!(!is_tailscale_ip("100.128.0.1"));
        assert!(!is_tailscale_ip("192.168.71.72"));
        assert!(is_tailscale_ip("fd7a:115c:a1e0::2"));
    }

    #[test]
    fn merges_by_fingerprint_and_prefers_lan() {
        let rows = merge(
            vec![
                record("mac", &["100.75.58.59"]),
                record("mac", &["192.168.71.72"]),
                record("self", &["1.2.3.4"]),
            ],
            "self",
            &options(true, true),
        );
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].ip, "192.168.71.72");
        assert_eq!(rows[0].source, "lan");
        assert_eq!(rows[0].addresses.len(), 2);
    }

    #[test]
    fn filters_by_source() {
        let records = || {
            vec![
                record("mac", &["100.75.58.59", "192.168.71.72"]),
                record("phone", &["192.168.71.85"]),
            ]
        };
        let tailscale_only = merge(records(), "self", &options(false, true));
        assert_eq!(tailscale_only.len(), 1);
        assert_eq!(tailscale_only[0].ip, "100.75.58.59");
        assert_eq!(tailscale_only[0].source, "tailscale");
        assert_eq!(merge(records(), "self", &options(true, false)).len(), 2);
    }
}
