const std = @import("std");
const net = std.net;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Connection = net.Server.Connection;

const host = "127.0.0.1";
const port = 7182;

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

        // Unused until non-blocking implementation
        //try self.clients.append(client);

        try self.handle(client);
    }

    pub fn handle(self: *Server, client: Connection) !void {
        const reader = client.stream.reader();
        const data_length = try reader.read(&self.buffer);
        const data = self.buffer[0..data_length];

        const writer = client.stream.writer();
        try writer.writeAll(data);

        client.stream.close();
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
