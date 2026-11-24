//! Comptime generation of libwayland listener structs.
//!
//! `listener(c.wl_foo_listener, Handlers, Data)` fills each event slot with `Handlers.<event>`
//! when declared, else a no-op. Handlers take `*Data` as their first parameter instead of
//! `?*anyopaque`; the remaining parameters must match the C signature exactly (checked at
//! compile time), so no handler needs the usual `@ptrCast(@alignCast(data))` boilerplate.
const std = @import("std");
const builtin = @import("builtin");

comptime {
    // Undeclared events point at a zero-argument no-op. Calling a C function with more
    // arguments than it reads is harmless on these caller-cleanup ABIs.
    switch (builtin.cpu.arch) {
        .x86_64, .aarch64, .riscv64 => {},
        else => @compileError("wl.listener: no-op event slots are only verified on x86_64/aarch64/riscv64"),
    }
}

fn noop() callconv(.c) void {}

pub fn listener(comptime Listener: type, comptime Handlers: type, comptime Data: type) Listener {
    comptime {
        var l: Listener = undefined;
        const info = @typeInfo(Listener).@"struct";
        for (info.field_names, info.field_types) |name, FieldType| {
            const FnPtr = @typeInfo(FieldType).optional.child;
            if (@hasDecl(Handlers, name)) {
                const handler = @field(Handlers, name);
                check(FnPtr, @TypeOf(handler), Data, name);
                @field(l, name) = @ptrCast(&handler);
            } else {
                @field(l, name) = @ptrCast(&noop);
            }
        }
        return l;
    }
}

fn check(comptime FnPtr: type, comptime Handler: type, comptime Data: type, comptime name: []const u8) void {
    const want = @typeInfo(@typeInfo(FnPtr).pointer.child).@"fn";
    const have = @typeInfo(Handler).@"fn";
    const where = @typeName(Data) ++ " handler '" ++ name ++ "'";
    if (!std.meta.eql(have.attrs.@"callconv", std.builtin.CallingConvention.c)) @compileError(where ++ " must be callconv(.c)");
    if (have.param_types.len != want.param_types.len) @compileError(where ++ ": wrong number of parameters");
    if (have.param_types[0].? != *Data) @compileError(where ++ ": first parameter must be *" ++ @typeName(Data));
    for (want.param_types[1..], have.param_types[1..], 1..) |w, h, i| {
        if (w.? != h.?) @compileError(std.fmt.comptimePrint("{s}: parameter {d} is {s}, expected {s}", .{ where, i, @typeName(h.?), @typeName(w.?) }));
    }
}
