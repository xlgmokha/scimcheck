const std = @import("std");
const Io = std.Io;

const Client = @import("Client.zig");
const args_ = @import("args.zig");
const check = @import("check.zig");
const commands = @import("commands.zig");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    const argv = try init.minimal.args.toSlice(arena);
    const args = args_.parse(arena, argv[1..], stderr) catch |err| switch (err) {
        error.Usage => {
            try stderr.writeAll("run 'scimcheck --help' for usage\n");
            return 2;
        },
        else => |e| return e,
    };

    if (args.positional.items.len == 0) {
        try stderr.writeAll(args_.usage);
        return 2;
    }
    const command = args.positional.items[0];
    const rest = args.positional.items[1..];
    if (!std.mem.eql(u8, command, "check") and !commands.isCommand(command)) {
        try stderr.print("error: unknown command '{s}'; run 'scimcheck --help' for usage\n", .{command});
        return 2;
    }

    const url = args.url orelse init.environ_map.get("SCIM_URL") orelse {
        try stderr.writeAll("error: set the service provider URL with --url or SCIM_URL\n");
        return 2;
    };
    const token = args.token orelse init.environ_map.get("SCIM_TOKEN");
    const authorization = if (token) |t| try std.fmt.allocPrint(arena, "Bearer {s}", .{t}) else null;

    var client: Client = .init(init.gpa, io, url, authorization);
    defer client.deinit();
    if (args.verbose) client.trace = stderr;

    if (std.mem.eql(u8, command, "check")) {
        var options: check.Options = .{ .keep = args.keep };
        if (args.only) |only| {
            options.only = .initEmpty();
            var it = std.mem.tokenizeAny(u8, only, ", ");
            while (it.next()) |name| {
                const section = std.meta.stringToEnum(check.Section, name) orelse {
                    try stderr.print("error: unknown section '{s}'\n", .{name});
                    return 2;
                };
                options.only.insert(section);
            }
        }
        var suite: check.Suite = .init(arena, io, &client, stdout, options);
        const summary = suite.run();
        return if (summary.failed > 0) 1 else 0;
    }

    const ctx: commands.Context = .{
        .arena = arena,
        .io = io,
        .client = &client,
        .args = args,
        .stdout = stdout,
        .stderr = stderr,
    };
    return commands.run(ctx, command, rest) catch |err| switch (err) {
        error.Usage => {
            try stderr.print("error: query flags such as --filter only apply to list and search\n", .{});
            return 2;
        },
        error.InvalidCharacter, error.Overflow => {
            try stderr.writeAll("error: --start-index and --count must be integers\n");
            return 2;
        },
        error.ConnectionRefused, error.UnknownHostName, error.TlsInitializationFailed => {
            try stderr.print("error: cannot reach {s}: {s}\n", .{ url, @errorName(err) });
            return 1;
        },
        else => |e| return e,
    };
}

test {
    // Analyze every declaration, including ones nothing calls yet.
    std.testing.refAllDecls(Client);
    std.testing.refAllDecls(args_);
    std.testing.refAllDecls(check);
    std.testing.refAllDecls(commands);
    std.testing.refAllDecls(@import("json.zig"));
    std.testing.refAllDecls(@import("output.zig"));
}
