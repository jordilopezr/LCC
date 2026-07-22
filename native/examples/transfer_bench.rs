//! Benchmark spike: SFTP vs SCP upload throughput over an IAP tunnel.
//!
//! Usage: transfer_bench <host> <port> <username> <local_file> <remote_dir>
//!
//! Uploads the same file once via SFTP (the app's current mechanism, 128 KB
//! buffer) and once via legacy SCP (libssh2 scp_send), timing each, then
//! deletes both remote copies. Decides the "faster uploads" investment with
//! data instead of hunches.

use ssh2::Session;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::Path;
use std::time::Instant;

const BUF: usize = 128 * 1024;

fn session(host: &str, port: u16, user: &str) -> Session {
    let tcp = TcpStream::connect(format!("{host}:{port}")).expect("tcp connect");
    let mut sess = Session::new().expect("session");
    sess.set_tcp_stream(tcp);
    sess.handshake().expect("handshake");
    if sess.userauth_agent(user).is_err() {
        let key = dirs::home_dir().unwrap().join(".ssh").join("id_rsa");
        sess.userauth_pubkey_file(user, None, &key, None)
            .expect("pubkey auth");
    }
    assert!(sess.authenticated(), "ssh auth failed");
    sess
}

fn report(label: &str, bytes: u64, secs: f64) {
    let mbs = bytes as f64 / 1_000_000.0 / secs;
    println!("{label}: {bytes} bytes in {secs:.1}s = {mbs:.2} MB/s");
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let [_, host, port, user, local, remote_dir] = &args[..] else {
        eprintln!("usage: transfer_bench <host> <port> <username> <local_file> <remote_dir>");
        std::process::exit(2);
    };
    let port: u16 = port.parse().expect("port");
    let data = std::fs::read(local).expect("read local file");
    let size = data.len() as u64;
    println!("file: {local} ({size} bytes)");

    // --- SFTP (what the app does today) ---
    let sftp_path = format!("{remote_dir}/bench_sftp.bin");
    let sess = session(host, port, user);
    let sftp = sess.sftp().expect("sftp");
    let start = Instant::now();
    let mut remote = sftp.create(Path::new(&sftp_path)).expect("sftp create");
    for chunk in data.chunks(BUF) {
        remote.write_all(chunk).expect("sftp write");
    }
    drop(remote);
    report("SFTP", size, start.elapsed().as_secs_f64());

    // --- SCP (legacy protocol, streams over the channel) ---
    let scp_path = format!("{remote_dir}/bench_scp.bin");
    let start = Instant::now();
    let mut ch = sess
        .scp_send(Path::new(&scp_path), 0o644, size, None)
        .expect("scp_send");
    for chunk in data.chunks(BUF) {
        ch.write_all(chunk).expect("scp write");
    }
    ch.send_eof().expect("eof");
    ch.wait_eof().expect("wait eof");
    ch.close().expect("close");
    ch.wait_close().expect("wait close");
    report("SCP ", size, start.elapsed().as_secs_f64());

    // --- verify sizes remotely, then clean up ---
    for p in [&sftp_path, &scp_path] {
        let st = sftp.stat(Path::new(p)).expect("stat");
        assert_eq!(st.size, Some(size), "remote size mismatch for {p}");
        sftp.unlink(Path::new(p)).expect("unlink");
    }
    println!("verified sizes and cleaned up remote files");

    // --- exercise a raw exec channel write as an upper bound (cat > file) ---
    let raw_path = format!("{remote_dir}/bench_raw.bin");
    let start = Instant::now();
    let mut ch = sess.channel_session().expect("channel");
    ch.exec(&format!("cat > {raw_path}")).expect("exec cat");
    for chunk in data.chunks(BUF) {
        ch.write_all(chunk).expect("raw write");
    }
    ch.send_eof().expect("eof");
    ch.wait_eof().expect("wait eof");
    ch.close().expect("close");
    ch.wait_close().expect("wait close");
    report("RAW ", size, start.elapsed().as_secs_f64());
    let st = sftp.stat(Path::new(&raw_path)).expect("stat raw");
    assert_eq!(st.size, Some(size), "raw size mismatch");
    sftp.unlink(Path::new(&raw_path)).expect("unlink raw");
    println!("raw channel verified and cleaned up");
}
