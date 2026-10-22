const std = @import("std");

// Since parse is the only public function, these variables can be set there and
// used globally.
var stdout: *std.Io.Writer = undefined;
var stderr: *std.Io.Writer = undefined;

pub fn parse(
    init: std.process.Init,
    T: type,
    errorCheck: ?fn (args: T, stderr: *std.Io.Writer) anyerror!bool,
) !T {
    const allocator = init.gpa;
    const io = init.io;

    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    stdout = &stdout_writer.interface;
    var stderr_writer = std.Io.File.stderr().writer(io, &.{});
    stderr = &stderr_writer.interface;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.minimal.args.toSlice(a);

    const fields = @typeInfo(T).@"struct";
    var seen: [fields.field_names.len]bool = @splat(false);
    var result: T = undefined;
    errdefer {
        inline for (fields.field_names, seen) |field_name, seen_field| {
            if (seen_field) {
                freeField(allocator, @field(result, field_name));
            }
        }
    }

    try setFromCli(T, allocator, &arena, args, &seen, &result);
    try setFromEnv(T, allocator, &arena, &seen, &result, init.environ_map);
    try setFromDefaults(T, allocator, &seen, &result);

    inline for (fields.field_names, fields.field_types, seen) |field_name, field_type, seen_field| {
        if (!seen_field) {
            if (@typeInfo(stripOptional(field_type)) == .bool) {
                @field(result, field_name) = false;
            } else {
                try stderr.print(
                    "Missing required argument {s}\n",
                    .{field_name},
                );
                try printUsage(T, arena.allocator(), args[0]);
                std.process.exit(1);
            }
        }
    }

    if (errorCheck) |check| {
        if (!(try check(result, stderr))) {
            try printUsage(T, arena.allocator(), args[0]);
            std.process.exit(1);
        }
    }

    return result;
}

fn setFromCli(
    T: type,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    args: []const []const u8,
    seen: []bool,
    result: *T,
) !void {
    const a = arena.allocator();
    var i: usize = 1;
    args: while (i < args.len) : (i += 1) {
        const raw_arg = args[i];
        if (std.mem.eql(u8, raw_arg, "-h") or
            std.mem.eql(u8, raw_arg, "--help"))
        {
            try printUsage(T, arena.allocator(), args[0]);
            std.process.exit(0);
        }

        // TODO: Handle one-letter arguments
        if (!std.mem.startsWith(u8, raw_arg, "--")) {
            try stderr.print("Unknown argument: '{s}'\n", .{raw_arg});
            try printUsage(T, arena.allocator(), args[0]);
            std.process.exit(1);
        }

        const arg = try a.dupe(u8, raw_arg[2..]);
        defer a.free(arg);
        std.mem.replaceScalar(u8, arg, '-', '_');
        const fields = @typeInfo(T).@"struct";
        inline for (fields.field_names, fields.field_types, seen) |field_name, field_type, *seen_field| {
            if (!seen_field.* and std.ascii.eqlIgnoreCase(arg, field_name)) {
                const t = @typeInfo(stripOptional(field_type));
                if (t == .bool) {
                    @field(result, field_name) = true;
                } else {
                    i += 1;
                    if (i >= args.len) {
                        try stderr.print(
                            "Missing required value for argument {s} {s}\n",
                            .{ raw_arg, field_name },
                        );
                        try printUsage(T, arena.allocator(), args[0]);
                        std.process.exit(1);
                    }
                    switch (t) {
                        .int => @field(result, field_name) =
                            try std.fmt.parseInt(
                                stripOptional(field_type),
                                args[i],
                                0,
                            ),
                        .pointer => @field(
                            result,
                            field_name,
                        ) = try allocator.dupe(u8, args[i]),
                        .bool => comptime unreachable,
                        else => @compileError(
                            "Disallowed or unimplemented struct field type.",
                        ),
                    }
                }
                seen_field.* = true;
                continue :args;
            }
        }

        try stderr.print("Unknown argument: '{s}'\n", .{raw_arg});
        try printUsage(T, arena.allocator(), args[0]);
        std.process.exit(1);
    }
}

fn setFromEnv(
    T: type,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    seen: []bool,
    result: *T,
    env: *std.process.Environ.Map,
) !void {
    const a = arena.allocator();
    var iterator = env.iterator();
    while (iterator.next()) |entry| {
        const key = try a.dupe(u8, entry.key_ptr.*);
        defer a.free(key);
        std.mem.replaceScalar(u8, key, '-', '_');
        const fields = @typeInfo(T).@"struct";
        inline for (fields.field_names, fields.field_types, seen) |field_name, field_type, *seen_field| {
            if (!seen_field.* and std.ascii.eqlIgnoreCase(key, field_name)) {
                switch (@typeInfo(stripOptional(field_type))) {
                    .bool => {
                        const value = try a.dupe(u8, entry.value_ptr.*);
                        defer a.free(value);
                        @field(result, field_name) = value.len > 0 and
                            !std.ascii.eqlIgnoreCase(value, "false");
                    },
                    .int => @field(result, field_name) = try std.fmt.parseInt(
                        stripOptional(field_type),
                        entry.value_ptr.*,
                        0,
                    ),
                    .pointer => @field(
                        result,
                        field_name,
                    ) = try allocator.dupe(u8, entry.value_ptr.*),
                    else => @compileError(
                        "Disallowed or unimplemented struct field type.",
                    ),
                }
                seen_field.* = true;
            }
        }
    }
}

fn setFromDefaults(
    T: type,
    allocator: std.mem.Allocator,
    seen: []bool,
    result: *T,
) !void {
    const fields = @typeInfo(T).@"struct";
    inline for (
        fields.field_names,
        fields.field_types,
        fields.field_attrs,
        seen,
    ) |field_name, field_type, field_attrs, *seen_field| {
        if (!seen_field.*) {
            if (field_attrs.defaultValue(field_type)) |default| {
                switch (@typeInfo(stripOptional(field_type))) {
                    .bool, .int, .float, .@"enum" => {
                        @field(result, field_name) = default;
                    },
                    .pointer => @field(
                        result,
                        field_name,
                    ) = if (default) |p| try allocator.dupe(u8, p) else null,
                    else => @compileError("Disallowed struct field type."),
                }
                seen_field.* = true;
            }
        }
    }
}

fn printUsage(T: type, allocator: std.mem.Allocator, argv0: []const u8) !void {
    try stdout.print("Usage: {s} [options]\n\n", .{argv0});
    try stdout.print("Options:\n", .{});
    const fields = @typeInfo(T).@"struct";
    inline for (fields.field_names, fields.field_types) |field_name, field_type| {
        switch (@typeInfo(stripOptional(field_type))) {
            .bool => {
                const flag_version = try allocator.dupe(u8, field_name);
                defer allocator.free(flag_version);
                std.mem.replaceScalar(u8, flag_version, '_', '-');
                try stdout.print("--{s}\n", .{flag_version});
            },
            else => {
                const flag_version = try allocator.dupe(u8, field_name);
                defer allocator.free(flag_version);
                std.mem.replaceScalar(u8, flag_version, '_', '-');
                try stdout.print("--{s} {s}\n", .{ flag_version, field_name });
            },
        }
    }
}

fn stripOptional(T: type) type {
    const info = @typeInfo(T);
    if (info != .optional) return T;
    return stripOptional(info.optional.child);
}

fn freeField(allocator: std.mem.Allocator, field: anytype) void {
    switch (@typeInfo(@TypeOf(field))) {
        .pointer => allocator.free(field),
        .optional => if (field) |v| freeField(allocator, v),
        .bool, .int, .float, .@"enum" => {},
        else => @compileError("Disallowed struct field type."),
    }
}
