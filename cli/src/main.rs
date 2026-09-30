mod app;
mod banner;
mod device_list;
mod peers_file;
mod picker;
mod sanitize;
mod send_task;
mod slots;
mod storage;
mod tailscale;
mod ui;
mod util;

use clap::{Parser, Subcommand};
use std::path::PathBuf;

#[derive(Subcommand)]
pub enum Command {
    /// Send one or more files or directories
    Send {
        /// Destination device: an exact alias or IP address
        #[arg(long, value_name = "TARGET")]
        to: Option<String>,

        /// Files or directories to send (directories are collected recursively)
        #[arg(value_name = "PATH", required = true, num_args = 1..)]
        paths: Vec<PathBuf>,
    },

    /// Receive without a terminal (e.g. as a systemd service): transfer
    /// requests are accepted automatically, events are printed as log lines
    Receive {
        /// Only accept transfers from paired devices, decline all others
        #[arg(long)]
        only_paired: bool,
    },

    /// List the online devices found over the LAN and Tailscale
    Devices {
        /// How long to discover, in seconds
        #[arg(short, long, default_value_t = 5)]
        timeout: u64,

        /// Print machine-readable JSON
        #[arg(long)]
        json: bool,

        /// Skip the LAN (multicast, subnet scan)
        #[arg(long)]
        no_lan: bool,

        /// Skip the Tailscale peers
        #[arg(long)]
        no_tailscale: bool,
    },

    /// Restart the systemd user service running `receive`
    Restart {
        /// Name of the systemd user unit
        #[arg(long, default_value = "localsend")]
        unit: String,
    },
}

/// LocalSend CLI
#[derive(Parser)]
#[command(name = "localsend-cli", version, about, after_help = HELP_SECTIONS)]
pub struct Args {
    /// Device name shown to other devices [default: config.toml, else the hostname]
    #[arg(long, global = true, env = "LOCALSEND_ALIAS")]
    pub alias: Option<String>,

    /// Port of the HTTP server [default: config.toml, else 53317]
    #[arg(short, long, global = true, env = "LOCALSEND_PORT")]
    pub port: Option<u16>,

    /// Directory where received files are saved [default: config.toml, else the Downloads folder]
    #[arg(long, visible_alias = "dest", global = true, env = "LOCALSEND_DESTINATION")]
    pub destination: Option<PathBuf>,

    #[command(subcommand)]
    pub command: Option<Command>,
}

const HELP_SECTIONS: &str = "Events:\n  \
                             D      Discovery\n  \
                             S      Sending files\n  \
                             R      Receiving files\n\
                             \nHotkeys:\n  \
                             1-9    Send files to the device with that number\n  \
                             D      Show the paired and discovered devices\n  \
                             W+S    Toggle share via link: serve files to browsers over plain HTTP\n  \
                             W+R    Toggle receive via link: let browsers upload files over plain HTTP\n  \
                             Y/N/P  Accept / Decline / Accept-and-Pair an incoming request\n  \
                             Ctrl+C Cancel the current transfer or request, or quit when idle\n \
                             \nEnvironment Variables:\n  \
                             XDG_CONFIG_HOME, LOCALSEND_ALIAS, LOCALSEND_PORT, LOCALSEND_DESTINATION";

fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    tokio::runtime::Runtime::new()?.block_on(app::run(args))
}

#[cfg(test)]
mod tests {
    use super::{Args, Command};
    use clap::Parser;
    use std::path::PathBuf;

    #[test]
    fn accepts_mixed_send_paths() {
        let args = Args::try_parse_from(["localsend-cli", "send", "one.txt", "two.txt", "backup"])
            .unwrap();

        let Some(Command::Send { to, paths }) = args.command else {
            panic!("expected the send command");
        };
        assert_eq!(to, None);
        assert_eq!(
            paths,
            vec![
                PathBuf::from("one.txt"),
                PathBuf::from("two.txt"),
                PathBuf::from("backup"),
            ]
        );
    }

    #[test]
    fn accepts_a_destination_alias() {
        let args =
            Args::try_parse_from(["localsend-cli", "send", "--to", "Cute Tomato", "one.txt"])
                .unwrap();

        let Some(Command::Send { to, paths }) = args.command else {
            panic!("expected the send command");
        };
        assert_eq!(to.as_deref(), Some("Cute Tomato"));
        assert_eq!(paths, vec![PathBuf::from("one.txt")]);
    }

    #[test]
    fn accepts_a_destination_ip() {
        let args =
            Args::try_parse_from(["localsend-cli", "send", "--to", "192.168.27.26", "one.txt"])
                .unwrap();

        let Some(Command::Send { to, paths }) = args.command else {
            panic!("expected the send command");
        };
        assert_eq!(to.as_deref(), Some("192.168.27.26"));
        assert_eq!(paths, vec![PathBuf::from("one.txt")]);
    }

    #[test]
    fn requires_at_least_one_send_path() {
        assert!(Args::try_parse_from(["localsend-cli", "send"]).is_err());
    }

    #[test]
    fn accepts_interactive_mode_without_a_command() {
        let args = Args::try_parse_from(["localsend-cli"]).unwrap();

        assert!(args.command.is_none());
    }
}
