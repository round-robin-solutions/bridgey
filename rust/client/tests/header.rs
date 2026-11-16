//! The committed C header matches the Rust ABI (cbindgen.toml). BRIDGEY_WRITE_HEADER=1 rewrites it.

#[test]
fn header_is_current() {
    let dir = env!("CARGO_MANIFEST_DIR");
    let config = cbindgen::Config::from_file(format!("{dir}/cbindgen.toml")).unwrap();
    let mut generated = Vec::new();
    cbindgen::Builder::new().with_crate(dir).with_config(config).generate().expect("cbindgen").write(&mut generated);
    let path = format!("{dir}/include/bridgey_core.h");
    if std::env::var_os("BRIDGEY_WRITE_HEADER").is_some() {
        std::fs::write(&path, &generated).unwrap();
    }
    let committed = std::fs::read(&path).unwrap_or_default();
    assert!(committed == generated, "include/bridgey_core.h is stale: run BRIDGEY_WRITE_HEADER=1 cargo test -p bridgey-client --test header");
}
