const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const config_types = @import("../config_types.zig");

const log = std.log.scoped(.matrix);

/// Matrix channel via Client-Server API.
///
/// - Inbound: long-poll /_matrix/client/v3/sync
/// - Outbound: POST /_matrix/client/v3/rooms/{roomId}/send/m.room.message/{txnId}
pub const MatrixChannel = struct {
    allocator: std.mem.Allocator,
    account_id: []const u8 = "default",
    homeserver: []const u8,
    access_token: []const u8,
    room_id: []const u8,
    user_id: ?[]const u8 = null,
    allow_from: []const []const u8,
    group_allow_from: []const []const u8,
    group_policy: []const u8,
    running: bool = false,

    next_batch_buf: [1024]u8 = undefined,
    next_batch_len: usize = 0,
    txn_counter: u64 = 0,

    pub const MAX_MESSAGE_LEN: usize = 4000;

    pub fn init(
        allocator: std.mem.Allocator,
        homeserver: []const u8,
        access_token: []const u8,
        room_id: []const u8,
        allow_from: []const []const u8,
    ) MatrixChannel {
        return .{
            .allocator = allocator,
            .homeserver = stripTrailingSlashes(homeserver),
            .access_token = access_token,
            .room_id = room_id,
            .allow_from = allow_from,
            .group_allow_from = &.{},
            .group_policy = "allowlist",
        };
    }

    pub fn initFromConfig(allocator: std.mem.Allocator, cfg: config_types.MatrixConfig) MatrixChannel {
        var ch = init(allocator, cfg.homeserver, cfg.access_token, cfg.room_id, cfg.allow_from);
        ch.account_id = cfg.account_id;
        ch.user_id = cfg.user_id;
        ch.group_allow_from = cfg.group_allow_from;
        ch.group_policy = cfg.group_policy;
        return ch;
    }

    pub fn channelName(_: *const MatrixChannel) []const u8 {
        return "matrix";
    }

    pub fn nextBatch(self: *const MatrixChannel) []const u8 {
        return self.next_batch_buf[0..self.next_batch_len];
    }

    fn setNextBatch(self: *MatrixChannel, token: []const u8) void {
        const len = @min(token.len, self.next_batch_buf.len);
        if (len > 0) {
            @memcpy(self.next_batch_buf[0..len], token[0..len]);
        }
        self.next_batch_len = len;
    }

    fn authHeader(self: *const MatrixChannel, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{self.access_token});
    }

    fn buildWhoAmIUrl(self: *const MatrixChannel, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.writeAll(self.homeserver);
        try w.writeAll("/_matrix/client/v3/account/whoami");
        return fbs.getWritten();
    }

    fn buildSyncUrl(self: *const MatrixChannel, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.writeAll(self.homeserver);
        try w.writeAll("/_matrix/client/v3/sync?timeout=30000");
        if (self.next_batch_len > 0) {
            try w.writeAll("&since=");
            try appendUrlEncoded(w, self.nextBatch());
        }
        return fbs.getWritten();
    }

    fn buildSendUrl(self: *const MatrixChannel, buf: []u8, room_id: []const u8, txn_id: []const u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.writeAll(self.homeserver);
        try w.writeAll("/_matrix/client/v3/rooms/");
        try appendUrlEncoded(w, room_id);
        try w.writeAll("/send/m.room.message/");
        try appendUrlEncoded(w, txn_id);
        return fbs.getWritten();
    }

    fn buildTypingUrl(self: *const MatrixChannel, buf: []u8, room_id: []const u8, user_id: []const u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.writeAll(self.homeserver);
        try w.writeAll("/_matrix/client/v3/rooms/");
        try appendUrlEncoded(w, room_id);
        try w.writeAll("/typing/");
        try appendUrlEncoded(w, user_id);
        return fbs.getWritten();
    }

    fn nextTxnId(self: *MatrixChannel, buf: []u8) ![]const u8 {
        self.txn_counter += 1;
        return std.fmt.bufPrint(buf, "nullclaw-{s}-{d}-{d}", .{
            self.account_id,
            std.time.timestamp(),
            self.txn_counter,
        });
    }

    fn normalizeTargetRoom(self: *const MatrixChannel, target: []const u8) ?[]const u8 {
        var t = std.mem.trim(u8, target, " \t\r\n");
        if (t.len == 0) t = self.room_id;
        if (t.len == 0) return null;

        if (std.mem.startsWith(u8, t, "matrix:")) t = std.mem.trim(u8, t["matrix:".len..], " \t\r\n");
        if (std.mem.startsWith(u8, t, "room:")) t = std.mem.trim(u8, t["room:".len..], " \t\r\n");
        if (std.mem.startsWith(u8, t, "channel:")) t = std.mem.trim(u8, t["channel:".len..], " \t\r\n");

        return if (t.len > 0) t else null;
    }

    fn sendMessageChunk(self: *MatrixChannel, room_id: []const u8, chunk: []const u8) !void {
        var txn_buf: [256]u8 = undefined;
        const txn_id = try self.nextTxnId(&txn_buf);

        var url_buf: [2048]u8 = undefined;
        const url = try self.buildSendUrl(&url_buf, room_id, txn_id);

        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(self.allocator);
        const w = body_list.writer(self.allocator);
        try w.writeAll("{\"msgtype\":\"m.text\",\"body\":");
        try root.appendJsonStringW(w, chunk);
        try w.writeAll("}");

        const auth_header = try self.authHeader(self.allocator);
        defer self.allocator.free(auth_header);

        const headers = [_][]const u8{auth_header};
        const resp = try root.http_util.curlPost(self.allocator, url, body_list.items, &headers);
        defer self.allocator.free(resp);

        if (std.mem.indexOf(u8, resp, "\"event_id\"") == null) {
            return error.MatrixSendFailed;
        }
    }

    pub fn sendMessage(self: *MatrixChannel, target: []const u8, message: []const u8) !void {
        const room_id = self.normalizeTargetRoom(target) orelse return error.InvalidTarget;

        const text = std.mem.trim(u8, message, " \t\r\n");
        if (text.len == 0) return;

        var it = root.splitMessage(text, MAX_MESSAGE_LEN);
        while (it.next()) |chunk| {
            const trimmed = std.mem.trim(u8, chunk, " \t\r\n");
            if (trimmed.len == 0) continue;
            try self.sendMessageChunk(room_id, trimmed);
        }
    }

    /// Send Matrix typing indicator (best-effort, errors ignored).
    pub fn sendTypingIndicator(self: *MatrixChannel, target: []const u8) void {
        if (builtin.is_test) return;

        const room_id = self.normalizeTargetRoom(target) orelse return;
        const uid = self.user_id orelse return;
        if (uid.len == 0) return;

        var url_buf: [4096]u8 = undefined;
        const url = self.buildTypingUrl(&url_buf, room_id, uid) catch return;

        const auth_header = self.authHeader(self.allocator) catch return;
        defer self.allocator.free(auth_header);
        const headers = [_][]const u8{auth_header};

        const resp = root.http_util.curlPost(
            self.allocator,
            url,
            "{\"typing\":true,\"timeout\":15000}",
            &headers,
        ) catch return;
        self.allocator.free(resp);
    }

    pub fn healthCheck(self: *MatrixChannel) bool {
        if (builtin.is_test) return true;

        var url_buf: [1024]u8 = undefined;
        const url = self.buildWhoAmIUrl(&url_buf) catch return false;

        const auth_header = self.authHeader(self.allocator) catch return false;
        defer self.allocator.free(auth_header);
        const headers = [_][]const u8{auth_header};

        const resp = root.http_util.curlGet(self.allocator, url, &headers, "10") catch return false;
        defer self.allocator.free(resp);

        return std.mem.indexOf(u8, resp, "\"user_id\"") != null;
    }

    fn senderAllowed(self: *const MatrixChannel, sender: []const u8) bool {
        if (std.mem.eql(u8, self.group_policy, "disabled")) return false;
        if (std.mem.eql(u8, self.group_policy, "open")) return true;

        const effective = if (self.group_allow_from.len > 0) self.group_allow_from else self.allow_from;
        if (effective.len == 0) return false;
        return root.isAllowed(effective, sender);
    }

    fn collectDirectRooms(
        allocator: std.mem.Allocator,
        root_obj: std.json.ObjectMap,
    ) !std.StringHashMapUnmanaged(void) {
        var direct_rooms: std.StringHashMapUnmanaged(void) = .empty;
        errdefer direct_rooms.deinit(allocator);

        const account_data_val = root_obj.get("account_data") orelse return direct_rooms;
        if (account_data_val != .object) return direct_rooms;

        const events_val = account_data_val.object.get("events") orelse return direct_rooms;
        if (events_val != .array) return direct_rooms;

        for (events_val.array.items) |event| {
            if (event != .object) continue;

            const type_val = event.object.get("type") orelse continue;
            if (type_val != .string or !std.mem.eql(u8, type_val.string, "m.direct")) continue;

            const content_val = event.object.get("content") orelse continue;
            if (content_val != .object) continue;

            var users_it = content_val.object.iterator();
            while (users_it.next()) |user_entry| {
                const rooms_val = user_entry.value_ptr.*;
                if (rooms_val != .array) continue;
                for (rooms_val.array.items) |room_id_val| {
                    if (room_id_val != .string or room_id_val.string.len == 0) continue;
                    try direct_rooms.put(allocator, room_id_val.string, {});
                }
            }
        }

        return direct_rooms;
    }

    fn eventArrayHasDirectMemberFlag(events_val: std.json.Value) bool {
        if (events_val != .array) return false;

        for (events_val.array.items) |event| {
            if (event != .object) continue;

            const type_val = event.object.get("type") orelse continue;
            if (type_val != .string or !std.mem.eql(u8, type_val.string, "m.room.member")) continue;

            const content_val = event.object.get("content") orelse continue;
            if (content_val != .object) continue;

            const is_direct_val = content_val.object.get("is_direct") orelse continue;
            if (is_direct_val == .bool and is_direct_val.bool) return true;
        }

        return false;
    }

    fn roomLooksDirect(
        room_id: []const u8,
        room: std.json.Value,
        direct_rooms: *const std.StringHashMapUnmanaged(void),
    ) bool {
        if (direct_rooms.contains(room_id)) return true;
        if (room != .object) return false;

        if (room.object.get("summary")) |summary_val| {
            if (summary_val == .object) {
                var total_members: usize = 0;
                var has_member_counts = false;

                if (summary_val.object.get("m.joined_member_count")) |joined_val| {
                    if (joined_val == .integer and joined_val.integer >= 0) {
                        total_members += @as(usize, @intCast(joined_val.integer));
                        has_member_counts = true;
                    }
                }
                if (summary_val.object.get("m.invited_member_count")) |invited_val| {
                    if (invited_val == .integer and invited_val.integer >= 0) {
                        total_members += @as(usize, @intCast(invited_val.integer));
                        has_member_counts = true;
                    }
                }

                if (has_member_counts and total_members > 0 and total_members <= 2) {
                    return true;
                }
            }
        }

        if (room.object.get("state")) |state_val| {
            if (state_val == .object) {
                if (state_val.object.get("events")) |state_events| {
                    if (eventArrayHasDirectMemberFlag(state_events)) return true;
                }
            }
        }

        if (room.object.get("timeline")) |timeline_val| {
            if (timeline_val == .object) {
                if (timeline_val.object.get("events")) |timeline_events| {
                    if (eventArrayHasDirectMemberFlag(timeline_events)) return true;
                }
            }
        }

        return false;
    }

    pub fn parseSyncResponse(self: *MatrixChannel, allocator: std.mem.Allocator, payload: []const u8) ![]root.ChannelMessage {
        var out: std.ArrayListUnmanaged(root.ChannelMessage) = .empty;
        errdefer {
            for (out.items) |*msg| msg.deinit(allocator);
            out.deinit(allocator);
        }

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return &.{};
        defer parsed.deinit();

        if (parsed.value != .object) return &.{};
        const root_obj = parsed.value.object;
        var direct_rooms = try collectDirectRooms(allocator, root_obj);
        defer direct_rooms.deinit(allocator);

        if (root_obj.get("next_batch")) |next_batch| {
            if (next_batch == .string and next_batch.string.len > 0) {
                self.setNextBatch(next_batch.string);
            }
        }

        const rooms_val = root_obj.get("rooms") orelse return toOwnedMessages(allocator, &out);
        if (rooms_val != .object) return toOwnedMessages(allocator, &out);

        const join_val = rooms_val.object.get("join") orelse return toOwnedMessages(allocator, &out);
        if (join_val != .object) return toOwnedMessages(allocator, &out);

        var rooms_it = join_val.object.iterator();
        while (rooms_it.next()) |room_entry| {
            const room_id = room_entry.key_ptr.*;
            const room = room_entry.value_ptr.*;
            const room_is_direct = roomLooksDirect(room_id, room, &direct_rooms);

            if (self.room_id.len > 0 and !std.mem.eql(u8, room_id, self.room_id)) continue;
            if (room != .object) continue;

            const timeline_val = room.object.get("timeline") orelse continue;
            if (timeline_val != .object) continue;

            const events_val = timeline_val.object.get("events") orelse continue;
            if (events_val != .array) continue;

            for (events_val.array.items) |event| {
                if (event != .object) continue;

                const type_val = event.object.get("type") orelse continue;
                if (type_val != .string) continue;
                if (!std.mem.eql(u8, type_val.string, "m.room.message")) continue;

                const sender_val = event.object.get("sender") orelse continue;
                if (sender_val != .string) continue;
                const sender = sender_val.string;

                if (self.user_id) |uid| {
                    if (std.mem.eql(u8, uid, sender)) continue;
                }

                if (!self.senderAllowed(sender)) continue;

                const content_val = event.object.get("content") orelse continue;
                if (content_val != .object) continue;

                // Extract body text (may be absent for some media messages)
                const body_raw: []const u8 = if (content_val.object.get("body")) |bv|
                    (if (bv == .string) bv.string else "")
                else
                    "";
                const body = std.mem.trim(u8, body_raw, " \t\r\n");

                // Check msgtype for media messages
                const msgtype: []const u8 = if (content_val.object.get("msgtype")) |mt|
                    (if (mt == .string) mt.string else "m.text")
                else
                    "m.text";

                const is_media = std.mem.eql(u8, msgtype, "m.image") or
                    std.mem.eql(u8, msgtype, "m.file") or
                    std.mem.eql(u8, msgtype, "m.video") or
                    std.mem.eql(u8, msgtype, "m.audio");

                // Skip if no body and no media
                if (body.len == 0 and !is_media) continue;

                // Build final content: body + downloaded media
                var content_buf: std.ArrayListUnmanaged(u8) = .empty;
                defer content_buf.deinit(allocator);

                if (body.len > 0) {
                    content_buf.appendSlice(allocator, body) catch {};
                }

                if (is_media) {
                    if (content_val.object.get("url")) |url_val| {
                        if (url_val == .string) {
                            const mxc_url = url_val.string;
                            // Download mxc:// URL
                            if (mxcToHttpUrl(allocator, self.homeserver, mxc_url)) |download_url| {
                                defer allocator.free(download_url);

                                if (!builtin.is_test) {
                                    const auth_hdr = self.authHeader(allocator) catch null;
                                    defer if (auth_hdr) |h| allocator.free(h);
                                    const hdrs: []const []const u8 = if (auth_hdr) |h| &.{h} else &.{};

                                    if (root.http_util.curlGet(allocator, download_url, hdrs, "30")) |data| {
                                        defer allocator.free(data);

                                        const rand = std.crypto.random;
                                        const rand_id = rand.int(u64);
                                        var path_buf: [1024]u8 = undefined;
                                        const local_path = std.fmt.bufPrint(&path_buf, "/tmp/matrix_{x}.dat", .{rand_id}) catch "";

                                        if (local_path.len > 0) {
                                            if (std.fs.createFileAbsolute(local_path, .{ .read = false })) |file| {
                                                file.writeAll(data) catch {
                                                    file.close();
                                                };
                                                file.close();

                                                const tag = if (std.mem.eql(u8, msgtype, "m.image")) "[IMAGE:" else "[FILE:";
                                                if (content_buf.items.len > 0) content_buf.appendSlice(allocator, "\n") catch {};
                                                content_buf.appendSlice(allocator, tag) catch {};
                                                content_buf.appendSlice(allocator, local_path) catch {};
                                                content_buf.appendSlice(allocator, "]") catch {};
                                            } else |_| {}
                                        }
                                    } else |_| {}
                                } else {
                                    // In tests, just append the mxc URL as a tag
                                    const tag = if (std.mem.eql(u8, msgtype, "m.image")) "[IMAGE:" else "[FILE:";
                                    if (content_buf.items.len > 0) content_buf.appendSlice(allocator, "\n") catch {};
                                    content_buf.appendSlice(allocator, tag) catch {};
                                    content_buf.appendSlice(allocator, mxc_url) catch {};
                                    content_buf.appendSlice(allocator, "]") catch {};
                                }
                            }
                        }
                    }
                }

                // Skip if we ended up with nothing
                if (content_buf.items.len == 0) continue;

                const event_id: []const u8 = blk: {
                    if (event.object.get("event_id")) |eid| {
                        if (eid == .string and eid.string.len > 0) break :blk eid.string;
                    }
                    break :blk "matrix-event";
                };

                const timestamp: u64 = blk: {
                    if (event.object.get("origin_server_ts")) |ts| {
                        if (ts == .integer and ts.integer > 0) {
                            break :blk @as(u64, @intCast(ts.integer)) / 1000;
                        }
                    }
                    break :blk root.nowEpochSecs();
                };

                const final_content = content_buf.toOwnedSlice(allocator) catch
                    try allocator.dupe(u8, body);

                try out.append(allocator, .{
                    .id = try allocator.dupe(u8, event_id),
                    .sender = try allocator.dupe(u8, sender),
                    .content = final_content,
                    .channel = "matrix",
                    .timestamp = timestamp,
                    .reply_target = try allocator.dupe(u8, room_id),
                    .is_group = !room_is_direct,
                });
            }
        }

        return toOwnedMessages(allocator, &out);
    }

    pub fn pollMessages(self: *MatrixChannel, allocator: std.mem.Allocator) ![]root.ChannelMessage {
        if (builtin.is_test) return &.{};

        var url_buf: [4096]u8 = undefined;
        const url = try self.buildSyncUrl(&url_buf);

        const auth_header = try self.authHeader(allocator);
        defer allocator.free(auth_header);
        const headers = [_][]const u8{auth_header};

        const resp = root.http_util.curlGet(allocator, url, &headers, "35") catch |err| {
            log.warn("Matrix sync failed: {}", .{err});
            return err;
        };
        defer allocator.free(resp);

        if (resp.len == 0) return &.{};
        return self.parseSyncResponse(allocator, resp);
    }

    fn vtableStart(ptr: *anyopaque) anyerror!void {
        const self: *MatrixChannel = @ptrCast(@alignCast(ptr));
        self.running = true;
    }

    fn vtableStop(ptr: *anyopaque) void {
        const self: *MatrixChannel = @ptrCast(@alignCast(ptr));
        self.running = false;
    }

    fn vtableSend(ptr: *anyopaque, target: []const u8, message: []const u8, media: []const []const u8) anyerror!void {
        const self: *MatrixChannel = @ptrCast(@alignCast(ptr));

        if (message.len > 0) {
            try self.sendMessage(target, message);
        }

        for (media) |file_path| {
            self.sendFileMessage(target, file_path) catch |err| {
                log.warn("Matrix: sendFileMessage failed: {}", .{err});
                // Fallback: send file path as text
                self.sendMessage(target, file_path) catch {};
            };
        }
    }

    /// Upload a file to Matrix media repo and send an m.image or m.file message.
    fn sendFileMessage(self: *MatrixChannel, target: []const u8, file_path: []const u8) !void {
        const room_id = self.normalizeTargetRoom(target) orelse return error.InvalidTarget;
        const http_util = @import("../http_util.zig");

        // Determine content type and msgtype
        const content_type = http_util.guessContentType(file_path);
        const is_image = std.mem.startsWith(u8, content_type, "image/");
        const msgtype = if (is_image) "m.image" else "m.file";

        // Extract filename from path
        const filename = std.fs.path.basename(file_path);

        // Build upload URL: POST /_matrix/media/v3/upload?filename=<name>
        var upload_url_buf: [4096]u8 = undefined;
        var upload_fbs = std.io.fixedBufferStream(&upload_url_buf);
        const uw = upload_fbs.writer();
        try uw.writeAll(self.homeserver);
        try uw.writeAll("/_matrix/media/v3/upload?filename=");
        try appendUrlEncoded(uw, filename);
        const upload_url = upload_fbs.getWritten();

        // Auth header
        const auth_header = try self.authHeader(self.allocator);
        defer self.allocator.free(auth_header);

        // Upload file
        const upload_resp = try http_util.curlPostFile(
            self.allocator,
            upload_url,
            file_path,
            content_type,
            &.{auth_header},
        );
        defer self.allocator.free(upload_resp);

        // Parse mxc:// URL from response: {"content_uri":"mxc://..."}
        const mxc_url = extractMxcUrl(self.allocator, upload_resp) orelse return error.MatrixUploadFailed;
        defer self.allocator.free(mxc_url);

        // Send m.image or m.file message
        var txn_buf: [256]u8 = undefined;
        const txn_id = try self.nextTxnId(&txn_buf);

        var url_buf: [2048]u8 = undefined;
        const send_url = try self.buildSendUrl(&url_buf, room_id, txn_id);

        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(self.allocator);
        const w = body_list.writer(self.allocator);
        try w.writeAll("{\"msgtype\":\"");
        try w.writeAll(msgtype);
        try w.writeAll("\",\"body\":");
        try root.appendJsonStringW(w, filename);
        try w.writeAll(",\"url\":");
        try root.appendJsonStringW(w, mxc_url);
        try w.writeAll("}");

        const headers = [_][]const u8{auth_header};
        const resp = try root.http_util.curlPost(self.allocator, send_url, body_list.items, &headers);
        defer self.allocator.free(resp);

        if (std.mem.indexOf(u8, resp, "\"event_id\"") == null) {
            return error.MatrixSendFailed;
        }
    }

    fn vtableName(ptr: *anyopaque) []const u8 {
        const self: *MatrixChannel = @ptrCast(@alignCast(ptr));
        return self.channelName();
    }

    fn vtableHealthCheck(ptr: *anyopaque) bool {
        const self: *MatrixChannel = @ptrCast(@alignCast(ptr));
        return self.healthCheck();
    }

    pub const vtable = root.Channel.VTable{
        .start = &vtableStart,
        .stop = &vtableStop,
        .send = &vtableSend,
        .name = &vtableName,
        .healthCheck = &vtableHealthCheck,
    };

    pub fn channel(self: *MatrixChannel) root.Channel {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};

/// Convert mxc://server/media_id to an HTTP download URL.
/// Returns allocated string or null if the URL is not a valid mxc:// URL.
fn mxcToHttpUrl(allocator: std.mem.Allocator, homeserver: []const u8, mxc_url: []const u8) ?[]u8 {
    // mxc://server_name/media_id
    if (!std.mem.startsWith(u8, mxc_url, "mxc://")) return null;
    const rest = mxc_url[6..]; // after "mxc://"
    const slash_pos = std.mem.indexOf(u8, rest, "/") orelse return null;
    const server = rest[0..slash_pos];
    const media_id = rest[slash_pos + 1 ..];
    if (server.len == 0 or media_id.len == 0) return null;

    return std.fmt.allocPrint(allocator, "{s}/_matrix/media/v3/download/{s}/{s}", .{
        homeserver, server, media_id,
    }) catch null;
}

/// Extract content_uri from Matrix upload response JSON.
fn extractMxcUrl(allocator: std.mem.Allocator, resp: []const u8) ?[]u8 {
    // Simple extraction: find "content_uri":"mxc://..."
    const key = "\"content_uri\":\"";
    const start = (std.mem.indexOf(u8, resp, key) orelse return null) + key.len;
    const end = std.mem.indexOf(u8, resp[start..], "\"") orelse return null;
    const uri = resp[start .. start + end];
    if (!std.mem.startsWith(u8, uri, "mxc://")) return null;
    return allocator.dupe(u8, uri) catch null;
}

fn stripTrailingSlashes(url: []const u8) []const u8 {
    var end = url.len;
    while (end > 0 and url[end - 1] == '/') : (end -= 1) {}
    return url[0..end];
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
}

fn appendUrlEncoded(writer: anytype, text: []const u8) !void {
    for (text) |c| {
        if (isUnreserved(c)) {
            try writer.writeByte(c);
        } else {
            var esc: [3]u8 = undefined;
            const upper = "0123456789ABCDEF";
            esc[0] = '%';
            esc[1] = upper[(c >> 4) & 0x0F];
            esc[2] = upper[c & 0x0F];
            try writer.writeAll(&esc);
        }
    }
}

fn toOwnedMessages(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(root.ChannelMessage),
) ![]root.ChannelMessage {
    if (list.items.len == 0) {
        list.deinit(allocator);
        return &.{};
    }
    return list.toOwnedSlice(allocator);
}

test "MatrixChannel initFromConfig maps account and policy fields" {
    const cfg = config_types.MatrixConfig{
        .account_id = "work",
        .homeserver = "https://matrix.example/",
        .access_token = "tok",
        .room_id = "!room:example",
        .user_id = "@bot:example",
        .allow_from = &.{"@alice:example"},
        .group_allow_from = &.{"@bob:example"},
        .group_policy = "open",
    };

    const ch = MatrixChannel.initFromConfig(std.testing.allocator, cfg);
    try std.testing.expectEqualStrings("work", ch.account_id);
    try std.testing.expectEqualStrings("https://matrix.example", ch.homeserver);
    try std.testing.expectEqualStrings("@bot:example", ch.user_id.?);
    try std.testing.expectEqualStrings("open", ch.group_policy);
    try std.testing.expectEqual(@as(usize, 1), ch.allow_from.len);
    try std.testing.expectEqual(@as(usize, 1), ch.group_allow_from.len);
}

test "MatrixChannel buildTypingUrl encodes room and user ids" {
    var ch = MatrixChannel.init(
        std.testing.allocator,
        "https://matrix.example",
        "tok",
        "!room:example",
        &.{"*"},
    );
    ch.user_id = "@bot:example";

    var buf: [512]u8 = undefined;
    const url = try ch.buildTypingUrl(&buf, "!room:example", "@bot:example");
    try std.testing.expectEqualStrings(
        "https://matrix.example/_matrix/client/v3/rooms/%21room%3Aexample/typing/%40bot%3Aexample",
        url,
    );
}

test "MatrixChannel sendTypingIndicator is no-op in tests" {
    var ch = MatrixChannel.init(
        std.testing.allocator,
        "https://matrix.example",
        "tok",
        "!room:example",
        &.{"*"},
    );
    ch.user_id = "@bot:example";
    ch.sendTypingIndicator("!room:example");
}

test "MatrixChannel parseSyncResponse extracts messages and next_batch" {
    const allocator = std.testing.allocator;

    var ch = MatrixChannel.init(
        allocator,
        "https://matrix.example",
        "tok",
        "!room:example",
        &.{"*"},
    );

    const payload =
        \\{
        \\  "next_batch": "s123",
        \\  "rooms": {
        \\    "join": {
        \\      "!room:example": {
        \\        "timeline": {
        \\          "events": [
        \\            {
        \\              "type": "m.room.message",
        \\              "sender": "@alice:example",
        \\              "event_id": "$evt1",
        \\              "origin_server_ts": 1700000000000,
        \\              "content": {
        \\                "msgtype": "m.text",
        \\                "body": "hello"
        \\              }
        \\            }
        \\          ]
        \\        }
        \\      },
        \\      "!other:example": {
        \\        "timeline": {
        \\          "events": [
        \\            {
        \\              "type": "m.room.message",
        \\              "sender": "@bob:example",
        \\              "event_id": "$evt2",
        \\              "origin_server_ts": 1700000000000,
        \\              "content": { "msgtype": "m.text", "body": "ignored" }
        \\            }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    const msgs = try ch.parseSyncResponse(allocator, payload);
    defer {
        for (msgs) |*m| m.deinit(allocator);
        if (msgs.len > 0) allocator.free(msgs);
    }

    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expectEqualStrings("$evt1", msgs[0].id);
    try std.testing.expectEqualStrings("@alice:example", msgs[0].sender);
    try std.testing.expectEqualStrings("hello", msgs[0].content);
    try std.testing.expectEqualStrings("!room:example", msgs[0].reply_target.?);
    try std.testing.expect(msgs[0].is_group);
    try std.testing.expectEqualStrings("s123", ch.nextBatch());
}

test "MatrixChannel parseSyncResponse marks m.direct rooms as direct chats" {
    const allocator = std.testing.allocator;

    var ch = MatrixChannel.init(
        allocator,
        "https://matrix.example",
        "tok",
        "!dm:example",
        &.{"@alice:example"},
    );

    const payload =
        \\{
        \\  "account_data": {
        \\    "events": [
        \\      {
        \\        "type": "m.direct",
        \\        "content": {
        \\          "@alice:example": ["!dm:example"]
        \\        }
        \\      }
        \\    ]
        \\  },
        \\  "rooms": {
        \\    "join": {
        \\      "!dm:example": {
        \\        "timeline": {
        \\          "events": [
        \\            {
        \\              "type": "m.room.message",
        \\              "sender": "@alice:example",
        \\              "event_id": "$evt-dm",
        \\              "content": { "msgtype": "m.text", "body": "hello dm" }
        \\            }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    const msgs = try ch.parseSyncResponse(allocator, payload);
    defer {
        for (msgs) |*m| m.deinit(allocator);
        if (msgs.len > 0) allocator.free(msgs);
    }

    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expect(!msgs[0].is_group);
    try std.testing.expectEqualStrings("!dm:example", msgs[0].reply_target.?);
}

test "MatrixChannel parseSyncResponse allowlist and policy semantics" {
    const allocator = std.testing.allocator;

    var ch_allow = MatrixChannel.init(
        allocator,
        "https://matrix.example",
        "tok",
        "!room:example",
        &.{"@allowed:example"},
    );

    const payload_blocked =
        \\{
        \\  "rooms": { "join": { "!room:example": { "timeline": { "events": [
        \\    {"type":"m.room.message","sender":"@blocked:example","content":{"msgtype":"m.text","body":"x"}}
        \\  ]}}}}
        \\}
    ;
    const blocked = try ch_allow.parseSyncResponse(allocator, payload_blocked);
    defer {
        for (blocked) |*m| m.deinit(allocator);
        if (blocked.len > 0) allocator.free(blocked);
    }
    try std.testing.expectEqual(@as(usize, 0), blocked.len);

    var ch_open = MatrixChannel.init(
        allocator,
        "https://matrix.example",
        "tok",
        "!room:example",
        &.{},
    );
    ch_open.group_policy = "open";

    const payload_open =
        \\{
        \\  "rooms": { "join": { "!room:example": { "timeline": { "events": [
        \\    {"type":"m.room.message","sender":"@someone:example","content":{"msgtype":"m.text","body":"ok"}}
        \\  ]}}}}
        \\}
    ;
    const open_msgs = try ch_open.parseSyncResponse(allocator, payload_open);
    defer {
        for (open_msgs) |*m| m.deinit(allocator);
        if (open_msgs.len > 0) allocator.free(open_msgs);
    }
    try std.testing.expectEqual(@as(usize, 1), open_msgs.len);
}

test "MatrixChannel parseSyncResponse drops all when group_policy is disabled" {
    const allocator = std.testing.allocator;

    var ch = MatrixChannel.init(
        allocator,
        "https://matrix.example",
        "tok",
        "!room:example",
        &.{"*"},
    );
    ch.group_policy = "disabled";

    const payload =
        \\{
        \\  "rooms": { "join": { "!room:example": { "timeline": { "events": [
        \\    {"type":"m.room.message","sender":"@alice:example","content":{"msgtype":"m.text","body":"hello"}}
        \\  ]}}}}
        \\}
    ;

    const msgs = try ch.parseSyncResponse(allocator, payload);
    defer {
        for (msgs) |*m| m.deinit(allocator);
        if (msgs.len > 0) allocator.free(msgs);
    }
    try std.testing.expectEqual(@as(usize, 0), msgs.len);
}

test "MatrixChannel parseSyncResponse skips self and malformed payload safely" {
    const allocator = std.testing.allocator;

    var ch = MatrixChannel.init(
        allocator,
        "https://matrix.example",
        "tok",
        "!room:example",
        &.{"*"},
    );
    ch.user_id = "@bot:example";

    const payload =
        \\{
        \\  "rooms": {
        \\    "join": {
        \\      "!room:example": {
        \\        "timeline": {
        \\          "events": [
        \\            {"type":"m.room.message","sender":"@bot:example","content":{"msgtype":"m.text","body":"loop"}},
        \\            {"type":"m.room.message","sender":"@alice:example","content":"bad"},
        \\            {"type":"m.room.member","sender":"@alice:example","content":{}}
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    const msgs = try ch.parseSyncResponse(allocator, payload);
    defer {
        for (msgs) |*m| m.deinit(allocator);
        if (msgs.len > 0) allocator.free(msgs);
    }
    try std.testing.expectEqual(@as(usize, 0), msgs.len);

    const malformed = try ch.parseSyncResponse(allocator, "{not json");
    defer {
        for (malformed) |*m| m.deinit(allocator);
        if (malformed.len > 0) allocator.free(malformed);
    }
    try std.testing.expectEqual(@as(usize, 0), malformed.len);
}

test "MatrixChannel parseSyncResponse group_allow_from overrides fallback allow_from" {
    const allocator = std.testing.allocator;

    var ch = MatrixChannel.init(
        allocator,
        "https://matrix.example",
        "tok",
        "!room:example",
        &.{"@alice:example"},
    );
    ch.group_allow_from = &.{"@bob:example"};
    ch.group_policy = "allowlist";

    const payload =
        \\{
        \\  "rooms": { "join": { "!room:example": { "timeline": { "events": [
        \\    {"type":"m.room.message","sender":"@alice:example","event_id":"$evt-a","content":{"msgtype":"m.text","body":"blocked"}},
        \\    {"type":"m.room.message","sender":"@bob:example","event_id":"$evt-b","content":{"msgtype":"m.text","body":"allowed"}}
        \\  ]}}}}
        \\}
    ;

    const msgs = try ch.parseSyncResponse(allocator, payload);
    defer {
        for (msgs) |*m| m.deinit(allocator);
        if (msgs.len > 0) allocator.free(msgs);
    }

    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expectEqualStrings("@bob:example", msgs[0].sender);
    try std.testing.expectEqualStrings("allowed", msgs[0].content);
}

test "MatrixChannel parseSyncResponse with empty room_id accepts multiple rooms" {
    const allocator = std.testing.allocator;

    var ch = MatrixChannel.init(
        allocator,
        "https://matrix.example",
        "tok",
        "",
        &.{"*"},
    );
    ch.group_policy = "open";

    const payload =
        \\{
        \\  "rooms": {
        \\    "join": {
        \\      "!room-a:example": {
        \\        "timeline": {
        \\          "events": [
        \\            {"type":"m.room.message","sender":"@alice:example","event_id":"$evt-a","content":{"msgtype":"m.text","body":"from-a"}}
        \\          ]
        \\        }
        \\      },
        \\      "!room-b:example": {
        \\        "timeline": {
        \\          "events": [
        \\            {"type":"m.room.message","sender":"@bob:example","event_id":"$evt-b","content":{"msgtype":"m.text","body":"from-b"}}
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    const msgs = try ch.parseSyncResponse(allocator, payload);
    defer {
        for (msgs) |*m| m.deinit(allocator);
        if (msgs.len > 0) allocator.free(msgs);
    }

    try std.testing.expectEqual(@as(usize, 2), msgs.len);

    var saw_a = false;
    var saw_b = false;
    for (msgs) |m| {
        if (std.mem.eql(u8, m.reply_target.?, "!room-a:example") and std.mem.eql(u8, m.content, "from-a")) {
            saw_a = true;
        }
        if (std.mem.eql(u8, m.reply_target.?, "!room-b:example") and std.mem.eql(u8, m.content, "from-b")) {
            saw_b = true;
        }
    }
    try std.testing.expect(saw_a);
    try std.testing.expect(saw_b);
}

test "mxcToHttpUrl converts valid mxc url" {
    const allocator = std.testing.allocator;
    const url = mxcToHttpUrl(allocator, "https://matrix.example", "mxc://matrix.org/abc123").?;
    defer allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://matrix.example/_matrix/media/v3/download/matrix.org/abc123",
        url,
    );
}

test "mxcToHttpUrl returns null for non-mxc url" {
    try std.testing.expect(mxcToHttpUrl(std.testing.allocator, "https://matrix.example", "https://foo.com/bar") == null);
}

test "mxcToHttpUrl returns null for malformed mxc" {
    try std.testing.expect(mxcToHttpUrl(std.testing.allocator, "https://matrix.example", "mxc://") == null);
    try std.testing.expect(mxcToHttpUrl(std.testing.allocator, "https://matrix.example", "mxc://server") == null);
    try std.testing.expect(mxcToHttpUrl(std.testing.allocator, "https://matrix.example", "mxc://server/") == null);
}

test "extractMxcUrl parses upload response" {
    const allocator = std.testing.allocator;
    const resp = "{\"content_uri\":\"mxc://matrix.org/uploaded123\"}";
    const url = extractMxcUrl(allocator, resp).?;
    defer allocator.free(url);
    try std.testing.expectEqualStrings("mxc://matrix.org/uploaded123", url);
}

test "extractMxcUrl returns null for bad response" {
    try std.testing.expect(extractMxcUrl(std.testing.allocator, "{}") == null);
    try std.testing.expect(extractMxcUrl(std.testing.allocator, "{\"content_uri\":\"https://not-mxc\"}") == null);
}

test "MatrixChannel parseSyncResponse handles m.image messages" {
    const allocator = std.testing.allocator;

    var ch = MatrixChannel.init(
        allocator,
        "https://matrix.example",
        "tok",
        "!room:example",
        &.{"*"},
    );

    const payload =
        \\{
        \\  "rooms": {
        \\    "join": {
        \\      "!room:example": {
        \\        "timeline": {
        \\          "events": [
        \\            {
        \\              "type": "m.room.message",
        \\              "sender": "@alice:example",
        \\              "event_id": "$img1",
        \\              "origin_server_ts": 1700000000000,
        \\              "content": {
        \\                "msgtype": "m.image",
        \\                "body": "photo.jpg",
        \\                "url": "mxc://matrix.org/abc123"
        \\              }
        \\            }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    const msgs = try ch.parseSyncResponse(allocator, payload);
    defer {
        for (msgs) |*m| m.deinit(allocator);
        if (msgs.len > 0) allocator.free(msgs);
    }

    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    // In test mode, should contain the mxc URL tag
    try std.testing.expect(std.mem.indexOf(u8, msgs[0].content, "[IMAGE:mxc://matrix.org/abc123]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msgs[0].content, "photo.jpg") != null);
}

test "MatrixChannel parseSyncResponse handles m.file messages" {
    const allocator = std.testing.allocator;

    var ch = MatrixChannel.init(
        allocator,
        "https://matrix.example",
        "tok",
        "!room:example",
        &.{"*"},
    );

    const payload =
        \\{
        \\  "rooms": {
        \\    "join": {
        \\      "!room:example": {
        \\        "timeline": {
        \\          "events": [
        \\            {
        \\              "type": "m.room.message",
        \\              "sender": "@alice:example",
        \\              "event_id": "$file1",
        \\              "content": {
        \\                "msgtype": "m.file",
        \\                "body": "report.pdf",
        \\                "url": "mxc://matrix.org/def456"
        \\              }
        \\            }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    const msgs = try ch.parseSyncResponse(allocator, payload);
    defer {
        for (msgs) |*m| m.deinit(allocator);
        if (msgs.len > 0) allocator.free(msgs);
    }

    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expect(std.mem.indexOf(u8, msgs[0].content, "[FILE:mxc://matrix.org/def456]") != null);
}

test "http_util guessContentType" {
    const http_util = @import("../http_util.zig");
    try std.testing.expectEqualStrings("image/png", http_util.guessContentType("photo.png"));
    try std.testing.expectEqualStrings("image/jpeg", http_util.guessContentType("photo.jpg"));
    try std.testing.expectEqualStrings("application/pdf", http_util.guessContentType("doc.pdf"));
    try std.testing.expectEqualStrings("application/octet-stream", http_util.guessContentType("file.xyz"));
}
