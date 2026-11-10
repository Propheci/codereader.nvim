//! Backend for codereader.nvim: the Note store, Anchor re-finding and Trails.
//!
//! The Lua plugin owns all UI and calls the `codereader` binary once per
//! operation, reading a JSON envelope whose `schema_version` it checks. See
//! `docs/adr/0002-rust-binary-thin-lua.md`. Domain terms follow `GLOSSARY.md`.

pub mod fsutil;
pub mod ids;
pub mod note;
pub mod project;
pub mod resolve;
pub mod store;
pub mod trail;

/// Version of the JSON payloads the binary emits. Bump on any breaking change;
/// the Lua side refuses a version it does not know.
pub const SCHEMA_VERSION: u32 = 1;
