//! Writes protocol/test-vectors/connect-v1.json (run from rust/).

fn main() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocol/test-vectors/connect-v1.json");
    let text = serde_json::to_string_pretty(&bridgey_connect_proto::vectors::generate()).expect("JSON") + "\n";
    std::fs::write(path, text).expect("write");
    println!("wrote {path}");
}
