const std = @import("std");
const net = std.net;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Connection = net.Server.Connection;

const host = "127.0.0.1";
const port = 7182;

const Status = enum(u16) {
    ok = 200,
    not_found = 404,
    internal_server_error = 500,
    not_implemented = 501,

    pub fn name(self: Status) []const u8 {
        return switch (self) {
            .ok => "OK",
            .not_found => "Not Found",
            .internal_server_error => "Internal Server Error",
            .not_implemented => "Not Implemented",
        };
    }
};

const Method = enum {
    get,

    pub fn name(self: Method) []const u8 {
        return switch (self) {
            .get => "GET",
        };
    }
};

const Request = struct {
    method: Method,
    uri: []const u8,
    version: []const u8,

    pub fn parse(allocator: Allocator, data: []const u8) !Request {
        var pos: u32 = 0;
        while (pos < data.len and data[pos] != ' ') : (pos += 1) {}
        const method_name = data[0..pos];
        const method: Method = blk: {
            if (std.mem.eql(u8, method_name, "GET")) {
                break :blk .get;
            }
            return error.NotImplemented;
        };

        pos += 1;
        const uri_start = pos;
        while (pos < data.len and data[pos] != ' ') : (pos += 1) {}
        const uri = try allocator.dupe(u8, data[uri_start..pos]);

        pos += 1;
        const version_start = pos;
        while (pos < data.len and data[pos] != '\n') : (pos += 1) {}
        const version = try allocator.dupe(u8, data[version_start .. pos - 1]);

        return .{
            .method = method,
            .uri = uri,
            .version = version,
        };
    }

    pub fn deinit(self: *Request, allocator: Allocator) void {
        allocator.free(self.uri);
        allocator.free(self.version);
    }
};

const Server = struct {
    allocator: Allocator,
    address: net.Address,

    buffer: [1024]u8 = undefined,
    server: net.Server = undefined,
    clients: ArrayList(Connection) = undefined,

    pub fn start(self: *Server) !void {
        self.server = try self.address.listen(.{
            .reuse_port = true,
        });
        self.clients = ArrayList(Connection).init(self.allocator);
    }

    pub fn accept(self: *Server) !void {
        const client = try self.server.accept();
        defer client.stream.close();

        // Unused until non-blocking implementation
        //try self.clients.append(client);

        try self.handle(client);
    }

    pub fn handle(self: *Server, client: Connection) !void {
        const writer = client.stream.writer();
        errdefer writeResponseLine(.internal_server_error, writer) catch {};

        const reader = client.stream.reader();
        const data_length = try reader.read(&self.buffer);
        const data = self.buffer[0..data_length];
        var request = Request.parse(self.allocator, data) catch |err| {
            if (err == error.NotImplemented) {
                try writeResponseLine(.not_implemented, writer);
                return;
            }
            return err;
        };
        defer request.deinit(self.allocator);

        const file = std.fs.cwd().openFile(request.uri[1..], .{}) catch |err| {
            if (err == error.FileNotFound) {
                try writeResponseLine(.not_found, writer);
                return;
            }
            return err;
        };
        defer file.close();

        try writeResponseLine(.ok, writer);

        const headers = [_]Header{
            .{ "Server", "Toy Server" },
            .{ "Content-Type", "text/html" },
        };
        try writeHeaders(&headers, writer);

        try writer.writeByte('\n');

        const body = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(body);
        try writer.writeAll(body);
    }

    fn writeResponseLine(status: Status, writer: anytype) !void {
        try writer.print("HTTP/1.1 {} {s}\n", .{ @intFromEnum(status), status.name() });
    }

    const Header = struct { []const u8, []const u8 };
    fn writeHeaders(headers: []const Header, writer: anytype) !void {
        for (headers) |header| {
            try writer.print("{s}: {s}\n", .{ header[0], header[1] });
        }
    }

    pub fn close(self: *Server) void {
        self.server.deinit();
        for (self.clients.items) |client| {
            client.stream.close();
        }
        self.clients.deinit();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const in = try net.Ip4Address.parse(host, port);
    const address = net.Address{ .in = in };

    var server = Server{
        .allocator = allocator,
        .address = address,
    };
    try server.start();
    defer server.close();

    while (true) {
        try server.accept();
    }
}
