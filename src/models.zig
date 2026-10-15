//! Hand-coded catalogue runtime (ADR-019, ZIG Slice 5 Part A).
//!
//! The `Models` / `ScopedModels` / `Providers` builders reached via
//! `client.models()` / `client.providers()`. Two halves:
//!
//!   * The OFFLINE compiled-catalogue walk — `Models.list` / `Models.get` /
//!     `Models.withCapability` over the generated `compiled_in_models` slice.
//!     Pure, no IO, no key.
//!   * The LIVE `/models` send — `ScopedModels.list` / `ScopedModels.get`.
//!     `catalogueListRequest` assembles each page's request: it reads the
//!     generated `catalogueConfig` (endpoint + cursor_param) and the base URL,
//!     splices the QueryParamKey `?key=` for query-auth providers (Google), then
//!     appends the pagination cursor as `&<cursor_param>=` — the same
//!     `?key=...&pageToken=...` order Go/Python/Rust/Swift assemble (CR-003
//!     cross-SDK catalogue-URL byte-parity). Headers come from the shared
//!     `http.composeHeaders` (auth + required + custom, never a provider-name
//!     switch). Each reply page is decoded by the generated parser the config's
//!     `parser_kind` names, then enriched with the compiled-in capabilities.
//!
//! The catalogue-wire suite asserts the assembled request; the response-wire
//! `models-*` goldens assert the parsers. Mirrors `rust/src/models.rs`.

const std = @import("std");

const catalogue = @import("providers/generated/catalogue.zig");
const providers = @import("providers/generated/providers.zig");
const provider_info = @import("providers/generated/provider_info.zig");
const request_defs = @import("providers/generated/request_defs.zig");
const http = @import("http.zig");
const json = @import("json.zig");
const send = @import("send.zig");
const middleware = @import("middleware.zig");
const models_parsers = @import("providers/generated/models_parsers.zig");

pub const Capability = @import("capability.zig").Capability;

/// The universal model descriptor (ADR-019). `capabilities` is always
///
pub const ModelInfo = @import("providers/generated/structs.zig").ModelInfo;

/// Catalogue errors (ADR-019, Rust `CatalogueError`):
///   - `NotSupported` — the provider has no live models endpoint (no generated
///     `catalogueConfig`), so there is nothing to fetch.
///   - `Scope` — HTTP 403 whose body mentions scope or permission (OpenAI's
///     `api.model.read` scope is the canonical case).
///   - `Unavailable` — any other non-2xx reply, a transport failure, or a body
///     the parser cannot decode.
pub const CatalogueError = error{ NotSupported, Scope, Unavailable };

/// The assembled `/models` list request for one page (URL + headers) — the
/// request `ScopedModels.list` sends. Method is always GET.
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

/// Assemble the `/models` list request for one page (URL + headers). The
/// request `ScopedModels.list` sends; no network. `cursor` is "" for the first
/// page. `custom` are the client's custom headers (ADR-052), skipped when they
/// collide with an auth or required header. Errors with `NotSupported` when
/// the provider has no live models endpoint (no generated `catalogueConfig`).
pub fn catalogueListRequest(
    arena: std.mem.Allocator,
    provider: providers.ProviderName,
    base_url_override: ?[]const u8,
    api_key: []const u8,
    cursor: []const u8,
    custom: []const http.Header,
) !CatalogueRequest {
    const cfg = catalogue.catalogueConfig(provider) orelse return error.NotSupported;
    return catalogueRequest(arena, provider, base_url_override, api_key, cfg.endpoint, cfg.cursor_param, cursor, custom);
}

fn catalogueRequest(
    arena: std.mem.Allocator,
    provider: providers.ProviderName,
    base_url_override: ?[]const u8,
    api_key: []const u8,
    endpoint: []const u8,
    cursor_param: []const u8,
    cursor: []const u8,
    custom: []const http.Header,
) !CatalogueRequest {
    const url = try appendCursor(
        arena,
        // No SigV4 provider has a catalogue endpoint, so there is no region.
        try buildCatalogueUrl(arena, provider, base_url_override, endpoint, api_key, ""),
        cursor_param,
        cursor,
    );
    const headers = try http.composeHeaders(arena, provider, api_key, &.{}, null, custom);
    return .{ .method = .GET, .url = url, .headers = headers };
}

// === Live send (mirrors rust/src/models.rs paginate / fetch_catalogue_url) ===

/// One GET. A transport failure or non-2xx reply is `Unavailable`, except a
/// 403 whose body names a scope or permission, which is `Scope`.
fn fetchPage(transport: http.Transport, arena: std.mem.Allocator, req: CatalogueRequest) ![]const u8 {
    const resp = transport.send(arena, .{ .method = req.method, .url = req.url, .headers = req.headers }) catch
        return error.Unavailable;
    if (resp.status >= 200 and resp.status < 300) return resp.body;
    if (resp.status == 403 and scopeBodyMatches(resp.body)) return error.Scope;
    return error.Unavailable;
}

fn scopeBodyMatches(body: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(body, "scope") != null or
        std.ascii.indexOfIgnoreCase(body, "permission") != null;
}

/// Decode one reply page with the generated parser the config names (never a
/// provider-name switch).
fn dispatchParser(arena: std.mem.Allocator, kind: []const u8, body: []const u8) !models_parsers.ParsedModelsPage {
    const value = std.json.parseFromSliceLeaky(json.Value, arena, body, .{}) catch return error.Unavailable;
    if (std.mem.eql(u8, kind, "ParseAnthropicModels")) return models_parsers.parseAnthropicModelsResponse(arena, value);
    if (std.mem.eql(u8, kind, "ParseGoogleModels")) return models_parsers.parseGoogleModelsResponse(arena, value);
    if (std.mem.eql(u8, kind, "ParseOpenAICohortModels")) return models_parsers.parseOpenAICohortModelsResponse(arena, value);
    return error.NotSupported;
}

/// A parsed wire record as a `ModelInfo`: capabilities from the compiled-in
/// catalogue (empty for an id the SDK does not know), `raw` only under `raw()`.
fn enrich(provider: providers.ProviderName, rec: models_parsers.ParsedModelRecord, keep_raw: bool) ModelInfo {
    return .{
        .id = rec.id,
        .provider = provider,
        .capabilities = catalogue.ontologyCapabilities(provider, rec.id) orelse &.{},
        .display_name = rec.display_name,
        .description = rec.description,
        .context_window = rec.context_window,
        .max_output = rec.max_output,
        .created = rec.created,
        .raw = if (keep_raw) rec.raw else null,
    };
}

/// Fire `models_list` pre (vetoable) before `run`, and post after it with the
/// outcome, once per call rather than once per page (Rust parity).
fn observed(ctx: *const http.Ctx, provider: providers.ProviderName, model: []const u8, comptime T: type, result_fn: anytype, args: anytype) !T {
    const mws = ctx.middlewares();
    var ev = middleware.Event{ .op = .models_list, .phase = .pre, .provider = @tagName(provider), .model = model };
    var veto_reason: []const u8 = "";
    middleware.firePre(mws, ev, &veto_reason) catch return error.MiddlewareVeto;
    const result = @call(.auto, result_fn, args);
    if (result) |_| {} else |_| middleware.setEventError(&ev, .{ .transport = "models endpoint unavailable" });
    middleware.firePost(mws, ev);
    return result;
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
/// `/models` endpoint; `withCapability` composes a capability filter. Carries
/// the client's send context (base URL, custom headers, middleware, transport).
pub const Models = struct {
    ctx: http.Ctx,
    cap_filter: ?Capability = null,

    ///
    /// contains `c`. Composes with `list` and `provider(p)`.
    pub fn withCapability(self: Models, c: Capability) Models {
        var m = self;
        m.cap_filter = c;
        return m;
    }

    /// Scope the catalogue to a single provider's live endpoint.
    pub fn provider(self: Models, p: providers.ProviderName) ScopedModels {
        return .{ .provider = p, .ctx = self.ctx, .cap_filter = self.cap_filter };
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

/// The single-provider live catalogue reached via `Models.provider(p)`. `list`
/// pages through the provider's `/models` endpoint; `get` fetches one model;
/// `raw()` keeps each wire record on `ModelInfo.raw` (ADR-014).
pub const ScopedModels = struct {
    provider: providers.ProviderName,
    ctx: http.Ctx,
    cap_filter: ?Capability = null,
    raw_flag: bool = false,

    pub fn raw(self: ScopedModels) ScopedModels {
        var s = self;
        s.raw_flag = true;
        return s;
    }

    /// Assemble the `/models` list request for one page (URL + headers) — the
    /// request `list` sends. `cursor` is "" for the first page.
    pub fn listRequest(
        self: ScopedModels,
        arena: std.mem.Allocator,
        api_key: []const u8,
        cursor: []const u8,
    ) !CatalogueRequest {
        return catalogueListRequest(arena, self.provider, self.ctx.base_url, api_key, cursor, self.ctx.customHeaders());
    }

    /// Every model the provider's live `/models` endpoint lists, following the
    /// pagination cursor until the last page. Each record is enriched with the
    /// compiled-in capabilities, then the `withCapability` filter applies.
    /// Fires `models_list` middleware once per call. Arena-backed result.
    pub fn list(self: ScopedModels, arena: std.mem.Allocator, api_key: []const u8) ![]ModelInfo {
        return send.withTransport(&self.ctx, listWith, self, .{ arena, api_key });
    }

    /// `list` over an injected transport.
    fn listWith(self: ScopedModels, transport: http.Transport, arena: std.mem.Allocator, api_key: []const u8) ![]ModelInfo {
        const cfg = catalogue.catalogueConfig(self.provider) orelse return error.NotSupported;
        const records = try observed(&self.ctx, self.provider, "", []const models_parsers.ParsedModelRecord, paginate, .{ self, transport, arena, api_key, cfg });
        var out: std.ArrayList(ModelInfo) = .empty;
        for (records) |rec| {
            const info = enrich(self.provider, rec, self.raw_flag);
            if (self.cap_filter) |c| if (!capsContain(info.capabilities, c)) continue;
            try out.append(arena, info);
        }
        return out.toOwnedSlice(arena);
    }

    fn paginate(
        self: ScopedModels,
        transport: http.Transport,
        arena: std.mem.Allocator,
        api_key: []const u8,
        cfg: catalogue.CatalogueConfig,
    ) ![]const models_parsers.ParsedModelRecord {
        var all: std.ArrayList(models_parsers.ParsedModelRecord) = .empty;
        var cursor: []const u8 = "";
        while (true) {
            const req = try self.listRequest(arena, api_key, cursor);
            const page = try dispatchParser(arena, cfg.parser_kind, try fetchPage(transport, arena, req));
            try all.appendSlice(arena, page.records);
            if (page.next_cursor.len == 0) return all.items;
            cursor = page.next_cursor;
        }
    }

    /// One model from the provider's live endpoint (`<endpoint>/<id>`). An
    /// unfiltered point lookup, like `Models.get`. Fires `models_list`
    /// middleware with `id` as the model.
    pub fn get(self: ScopedModels, arena: std.mem.Allocator, api_key: []const u8, id: []const u8) !ModelInfo {
        return send.withTransport(&self.ctx, getWith, self, .{ arena, api_key, id });
    }

    /// `get` over an injected transport.
    fn getWith(self: ScopedModels, transport: http.Transport, arena: std.mem.Allocator, api_key: []const u8, id: []const u8) !ModelInfo {
        const cfg = catalogue.catalogueConfig(self.provider) orelse return error.NotSupported;
        const rec = try observed(&self.ctx, self.provider, id, models_parsers.ParsedModelRecord, fetchOne, .{ self, transport, arena, api_key, id, cfg });
        return enrich(self.provider, rec, self.raw_flag);
    }

    /// The single-record reply is the list record shape without the envelope,
    /// so it is wrapped in the provider's list envelope and decoded by the same
    /// parser (Rust `parse_single_record`).
    fn fetchOne(
        self: ScopedModels,
        transport: http.Transport,
        arena: std.mem.Allocator,
        api_key: []const u8,
        id: []const u8,
        cfg: catalogue.CatalogueConfig,
    ) !models_parsers.ParsedModelRecord {
        const endpoint = try std.fmt.allocPrint(arena, "{s}/{s}", .{ cfg.endpoint, id });
        const req = try catalogueRequest(arena, self.provider, self.ctx.base_url, api_key, endpoint, "", "", self.ctx.customHeaders());
        const body = try fetchPage(transport, arena, req);
        const envelope_key = if (std.mem.eql(u8, cfg.parser_kind, "ParseGoogleModels")) "models" else "data";
        const wrapped = try std.fmt.allocPrint(arena, "{{\"{s}\":[{s}]}}", .{ envelope_key, body });
        const page = try dispatchParser(arena, cfg.parser_kind, wrapped);
        if (page.records.len == 0) return error.Unavailable;
        return page.records[0];
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

fn testModels() Models {
    return .{ .ctx = .{ .gpa = std.testing.allocator, .io = std.testing.io } };
}







































































































// === Live catalogue send (ADR-019) ===

/// Records the (op, phase) of every middleware event.
const ModelsHook = struct {
    seen: [8]struct { op: middleware.MiddlewareOp, phase: middleware.MiddlewarePhase } = undefined,
    count: usize = 0,

    fn call(ptr: *anyopaque, ev: *const middleware.Event) ?[]const u8 {
        const self: *ModelsHook = @ptrCast(@alignCast(ptr));
        if (self.count < self.seen.len) {
            self.seen[self.count] = .{ .op = ev.op, .phase = ev.phase };
            self.count += 1;
        }
        return null;
    }
};

fn sentHeader(req: http.Request, name: []const u8) ?[]const u8 {
    for (req.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}


















































































































