// No Rust commands are exposed to web content: this plugin only ships native
// Android code (manifest permissions + download handling). See docs/PLUGINS.md.
const COMMANDS: &[&str] = &[];

fn main() {
    tauri_plugin::Builder::new(COMMANDS)
        .android_path("android")
        .build();
}
