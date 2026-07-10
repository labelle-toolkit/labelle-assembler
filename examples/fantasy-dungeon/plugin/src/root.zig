//! Root module for the `fantasy-dungeon` reference asset plugin.
//!
//! Deliberately empty of plugin machinery (no `Controller`, `Systems`,
//! `Components`, or `Hooks`). This plugin ships CONTENT, not code: its value is
//! the bundled `tiles` / `props` packs, the plugin-level `banner` atlas, and
//! the license/author metadata declared in `plugin.labelle`. The module exists
//! only to make the plugin a valid Zig package the generated game build can
//! reference — see `build.zig`.
