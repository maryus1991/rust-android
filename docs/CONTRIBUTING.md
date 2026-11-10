# Contributing and plugin development

* Run before every PR: `bash tests/run-all.sh`, `shellcheck scripts/*.sh scripts/lib/*.sh scripts/ci/*.sh tests/*.sh`, `cargo fmt --all`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace`.
* Never weaken a security check or a test to get CI green.
* Do not edit anything under `src-tauri/gen/`.

## Adding a feature / native plugin
1. Create `plugins/<name>/` (`tauri plugin new <name> --android --ios --no-api`), add it to the workspace `Cargo.toml` and to `src-tauri/Cargo.toml`.
2. Register it in `src-tauri/src/lib.rs` **only if its feature flag is enabled**.
3. Expose functionality only through an action in `bridge.rs::spec()` with the right origin kind and feature gate; add unit tests.
4. Add the flag to `config/app.json`, `Features` in `config.rs` (+ `is_enabled`, `features_json`) and set its status in `config/features.json`.
   `tests/run-all.sh` (`registry_matches_implementation`) fails if registry, config, Rust and bridge disagree.
5. Android permissions → `scripts/sync-config.sh` (plugin manifest); iOS usage strings → same script (`Info.ios.plist`).
6. Run `bash scripts/gen-features-doc.sh` and document platform limits honestly.
