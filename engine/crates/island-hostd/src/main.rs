use std::env;
use std::net::SocketAddr;
use std::path::PathBuf;

use codex_island_hostd::{HostDaemonServerConfig, codex_app_server_command, serve_host_daemon};

fn main() {
    let mut args = env::args().skip(1);
    match args.next().as_deref() {
        Some("--version") => {
            println!("{}", env!("CARGO_PKG_VERSION"));
        }
        Some("print-app-server-command") => {
            let shell = args.next().unwrap_or_else(|| "/bin/zsh".to_string());
            let config = codex_app_server_command(shell.as_ref());
            println!("{}", config.program.display());
            for arg in config.args {
                println!("{arg}");
            }
        }
        Some("serve") => {
            let bind_addr = args
                .next()
                .unwrap_or_else(|| "127.0.0.1:7331".to_string())
                .parse::<SocketAddr>()
                .expect("invalid bind address");
            let shell = args.next().unwrap_or_else(|| "/bin/zsh".to_string());
            let mut config = HostDaemonServerConfig::local(bind_addr, shell.as_ref());

            if let Some(state_dir) = args.next() {
                config.daemon.state_dir = PathBuf::from(state_dir);
            }

            if let Err(error) = serve_host_daemon(config) {
                eprintln!("codex-island-hostd serve failed: {error:?}");
                std::process::exit(1);
            }
        }
        _ => {
            eprintln!(
                "codex-island-hostd usage:\n  --version\n  print-app-server-command [shell]\n  serve [bind-addr] [shell] [state-dir]"
            );
        }
    }
}
