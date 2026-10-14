//! Hand-coded catalogue runtime (ADR-019, ZIG Slice 5 Part A).
//!
//! The `Models` / `ScopedModels` / `Providers` builders reached via
//! `client.models()` / `client.providers()`. Two halves:
//!
//!   * The OFFLINE compiled-catalogue walk — `Models.list` / `Models.get` /
//!     `Models.withCapability` over the generated `compiled_in_models` slice.
//!     Pure, no IO, no key.
//!   * The `/models` list() URL + header ASSEMBLY seam — `ScopedModels.listRequest`
//!     (delegating to `catalogueListRequest`). It reads the generated
//!     `catalogueConfig` (endpoint + cursor_param) and `providers.spec().base_url`,
//!     splices the QueryParamKey `?key=` for query-auth providers (Google), then
//!     appends the pagination cursor as `&<cursor_param>=` — the same
//!     `?key=...&pageToken=...` order Go/Python/Rust/Swift assemble (CR-003
//!     cross-SDK catalogue-URL byte-parity). Auth headers come from the shared
//!     `http.buildAuthHeaders` (never a provider-name switch).
//!
//! Zig has no live HTTP send, so the live pagination loop and `.live()`
//! aggregation are OUT of scope — the catalogue-wire suite exercises only the
//! request the list() path WOULD send (mirrors Rust's catalogue_wire driver,
//! which builds the request without a live server). Mirrors `rust/src/models.rs`.

const std = @import("std");

const catalogue = @import("providers/generated/catalogue.zig");
const providers = @import("providers/generated/providers.zig");
const provider_info = @import("providers/generated/provider_info.zig");
const request_defs = @import("providers/generated/request_defs.zig");
const http = @import("http.zig");

pub const Capability = @import("capability.zig").Capability;

/// The universal model descriptor (ADR-019). `capabilities` is always
///
pub const ModelInfo = @import("providers/generated/structs.zig").ModelInfo;

/// Catalogue error sentinel. A provider without `hasModelsEndpoint`
/// (no generated `catalogueConfig`) has nothing to fetch — `listRequest`
/// reports `error.NotSupported` rather than assembling a bogus URL. The live
/// `Scope` / `Unavailable` variants (Rust `CatalogueError`) belong to the
/// send path, which Zig does not build.
pub const CatalogueError = error{NotSupported};

/// The assembled `/models` list request for one page — the real request the
/// list() path would send (URL + headers), returned instead of sent because
/// Zig has no live transport. Method is always GET.
pub const CatalogueRequest = struct {
    method: http.Method,
    url: []const u8,
    headers: []const http.Header,
};

// === URL / header assembly seam (mirrors rust/src/models.rs) ===

/// The percent-encoder and the base-URL + `?key=` assembly both live in
/// `http.zig` now: the send terminals (HANDOFF-046) need byte-identical
/// assembly, and duplicating it here would be the "remember to splice the query
/// key in N places" rule this project root-fixes to N=1. The `?key=` still goes
/// on FIRST (before any pagination cursor) so `?key=...&<cursor>=...` matches
/// the other SDKs' assembly order (CR-003) — `appendCursor` runs after.
const urlencode = http.urlencode;
const buildCatalogueUrl = http.buildUrl;

/// Append the pagination cursor to an already-assembled URL, using the cursor
/// query-param name carried by the generated `catalogueConfig` (ADR-067 Fix A).
/// An empty cursor or an empty cursor_param (PaginationNone) leaves the URL
/// unchanged. Applied AFTER any `?key=` splice, so a query-auth provider
/// assembles `?key=...&<cursor_param>=...`.
fn appendCursor(
    arena: std.mem.Allocator,
    raw_url: []const u8,
    cursor_param: []const u8,
    cursor: []const u8,
) ![]const u8 {
    if (cursor.len == 0 or cursor_param.len == 0) return raw_url;
    const sep: u8 = if (std.mem.indexOfScalar(u8, raw_url, '?') != null) '&' else '?';
    return std.fmt.allocPrint(arena, "{s}{c}{s}={s}", .{
        raw_url,
        sep,
        cursor_param,
        try urlencode(arena, cursor),
    });
}

/// Assemble the `/models` list request for one page (URL + auth headers). The
/// real seam the list() path would send; no network. `cursor` is "" for the
/// first page. Errors with `NotSupported` when the provider has no live models
/// endpoint (no generated `catalogueConfig`).
pub fn catalogueListRequest(
    arena: std.mem.Allocator,
    provider: providers.ProviderName,
    base_url_override: ?[]const u8,
    api_key: []const u8,
    cursor: []const u8,
) !CatalogueRequest {
    const cfg = catalogue.catalogueConfig(provider) orelse return error.NotSupported;
    const url = try appendCursor(
        arena,
        try buildCatalogueUrl(arena, provider, base_url_override, cfg.endpoint, api_key),
        cfg.cursor_param,
        cursor,
    );
    const headers = try http.buildAuthHeaders(arena, provider, api_key);
    return .{ .method = .GET, .url = url, .headers = headers };
}

// === Offline compiled-catalogue walk ===

fn compiledToModelInfo(def: catalogue.CompiledModelDef) ModelInfo {
    return .{
        .id = def.id,
        .provider = def.provider,
        .capabilities = def.capabilities,
        .display_name = def.display_name,
        .description = def.description,
        .context_window = def.context_window,
        .max_output = def.max_output,
        .created = 0,
        .raw = null,
    };
}

fn capsContain(caps: []const Capability, c: Capability) bool {
    for (caps) |x| {
        if (x == c) return true;
    }
    return false;
}

fn catalogueFilter(arena: std.mem.Allocator, cap_filter: ?Capability) ![]ModelInfo {
    var list: std.ArrayList(ModelInfo) = .empty;
    for (catalogue.compiled_in_models) |def| {
        if (cap_filter) |c| {
            if (!capsContain(def.capabilities, c)) continue;
        }
        try list.append(arena, compiledToModelInfo(def));
    }
    return list.toOwnedSlice(arena);
}

fn catalogueLookup(id: []const u8) ?ModelInfo {
    for (catalogue.compiled_in_models) |def| {
        if (std.mem.eql(u8, def.id, id)) return compiledToModelInfo(def);
    }
    return null;
}

// === Public builders (mirror rust/src/builders/catalogue.rs) ===

/// The catalogue builder reached via `client.models()`. `list`/`get` walk the
/// compiled-in slice synchronously; `provider(p)` scopes to one provider's live
/// URL-assembly seam; `withCapability` composes a capability filter. There is no
/// `.live()` — Zig has no live transport.
pub const Models = struct {
    base_url: ?[]const u8 = null,
    cap_filter: ?Capability = null,

    ///
    /// contains `c`. Composes with `list` and `provider(p)`.
    pub fn withCapability(self: Models, c: Capability) Models {
        var m = self;
        m.cap_filter = c;
        return m;
    }

    /// Scope the catalogue to a single provider; returns `ScopedModels` on which
    /// `raw()` and `listRequest(...)` are reachable.
    pub fn provider(self: Models, p: providers.ProviderName) ScopedModels {
        return .{ .provider = p, .base_url = self.base_url, .cap_filter = self.cap_filter };
    }

    /// The compiled-in catalogue, filtered by `withCapability` when set. Returns
    /// an arena-backed slice. Sync, no IO, no key.
    pub fn list(self: Models, arena: std.mem.Allocator) ![]ModelInfo {
        return catalogueFilter(arena, self.cap_filter);
    }

    /// A compiled-in model by id, or `null` when no entry matches. Unfiltered
    /// point lookup (a `get` ignores the capability filter, mirroring Rust).
    pub fn get(self: Models, id: []const u8) ?ModelInfo {
        _ = self;
        return catalogueLookup(id);
    }
};

/// The single-provider live-catalogue sub-builder reached via `Models.provider(p)`.
/// `raw()` opts into populating `ModelInfo.raw` (ADR-014); `listRequest` assembles
/// the request the live list() would send. The live send/paginate/`get` are out of
/// scope (no Zig transport).
pub const ScopedModels = struct {
    provider: providers.ProviderName,
    base_url: ?[]const u8 = null,
    cap_filter: ?Capability = null,
    raw_flag: bool = false,

    pub fn raw(self: ScopedModels) ScopedModels {
        var s = self;
        s.raw_flag = true;
        return s;
    }

    /// Assemble the `/models` list request for one page (URL + headers) — the
    /// real seam the live list() would send. `cursor` is "" for the first page.
    pub fn listRequest(
        self: ScopedModels,
        arena: std.mem.Allocator,
        api_key: []const u8,
        cursor: []const u8,
    ) !CatalogueRequest {
        return catalogueListRequest(arena, self.provider, self.base_url, api_key, cursor);
    }
};

/// The providers-namespace prototype reached via `client.providers()`. `list()`
/// returns the providers with both a live models endpoint AND configured on this
/// client, as secret-free `ProviderInfo`. A Zig `Client` carries one provider, so
/// the result is a 0- or 1-element slice (mirrors go/providers.go). The static
/// roster of every supported provider is `provider_info.all_provider_info`.
pub const Providers = struct {
    provider: providers.ProviderName,

    pub fn list(self: Providers, arena: std.mem.Allocator) ![]const provider_info.ProviderInfo {
        if (catalogue.catalogueConfig(self.provider) == null) return &.{};
        const one = try arena.alloc(provider_info.ProviderInfo, 1);
        one[0] = provider_info.providerInfo(self.provider);
        return one;
    }
};

// === Unit tests (offline compiled walk + URL assembly) ===






































































































