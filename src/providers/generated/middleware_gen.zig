// Code generated — DO NOT EDIT.


/// Which side of an operation an `Event` describes.
pub const MiddlewarePhase = enum {
    pre,
    post,
};

/// The operation an `Event` describes. Tags derive from the
/// `MiddlewareOp` instances; `@tagName` IS the canonical op label.
pub const MiddlewareOp = enum {
    llm_request,
    tool_call,
    cache_create,
    upload,
    batch_submit,
    image_generation,
    music_generation,
    video_generation,
    models_list,
};
