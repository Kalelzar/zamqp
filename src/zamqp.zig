const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const c = std.c;

const log = std.log.scoped(.zamqp);

pub const boolean_t = c_int;
pub const flags_t = u32;
pub const channel_t = u16;

pub const bytes_t = extern struct {
    len: usize,
    bytes: ?[*]const u8,

    pub fn init(buf: []const u8) bytes_t {
        if (buf.len == 0) return empty();
        return .{ .len = buf.len, .bytes = buf.ptr };
    }

    pub fn slice(self: bytes_t) ?[]const u8 {
        return (self.bytes orelse return null)[0..self.len];
    }

    pub const initZ = amqp_cstring_bytes;

    pub fn empty() bytes_t {
        return .{ .len = 0, .bytes = null };
    }
};

pub const array_t = extern struct {
    num_entries: c_int,
    entries: ?*opaque {},

    pub fn empty() array_t {
        return .{ .num_entries = 0, .entries = null };
    }
};

pub const field_value_t = extern struct {
    kind: u8,
    value: extern union {
        boolean: c_int,
        i8: c_short,
        u8: c_ushort,
        i16: c_short,
        u16: c_ushort,
        i32: c_int,
        u32: c_uint,
        i64: c_longlong,
        u64: c_ulonglong,
        f32: f32,
        f64: f64,
        decimal: amqp_decimal_t,
        bytes: bytes_t,
        table: table_t,
        array: array_t,
    },
};

pub const table_entry_t = extern struct { key: bytes_t, value: field_value_t };

pub const table_t = extern struct {
    num_entries: c_int,
    entries: ?[*]table_entry_t,

    pub fn empty() table_t {
        return .{ .num_entries = 0, .entries = null };
    }
};

pub const DEFAULT_FRAME_SIZE: c_int = 131072;
pub const DEFAULT_MAX_CHANNELS: c_int = 2047;
// pub const DEFAULT_HEARTBEAT: c_int = 0;
// pub const DEFAULT_VHOST = "/";

pub const version_number = amqp_version_number;
pub const version = amqp_version;

pub const ConnectionInfo = extern struct {
    user: [*:0]u8,
    password: [*:0]u8,
    host: [*:0]u8,
    vhost: [*:0]u8,
    port: c_int,
    ssl: boolean_t,
};

pub fn parse_url(url: [*:0]u8) error{ BadUrl, Unexpected }!ConnectionInfo {
    var result: ConnectionInfo = undefined;
    return switch (amqp_parse_url(url, &result)) {
        .OK => result,
        .BAD_URL => error.BadUrl,
        else => |code| unexpected(code),
    };
}

pub const Connection = struct {
    handle: amqp_connection_state_t,

    pub fn new() error{OutOfMemory}!Connection {
        return Connection{ .handle = amqp_new_connection() orelse return error.OutOfMemory };
    }

    pub fn close(self: Connection, code: ReplyCode) !void {
        return amqp_connection_close(self.handle, @intFromEnum(code)).ok();
    }

    pub fn destroy(self: *Connection) !void {
        const status = amqp_destroy_connection(self.handle);
        self.handle = undefined;
        return status.ok();
    }

    pub fn maybe_release_buffers(self: Connection) void {
        amqp_maybe_release_buffers(self.handle);
    }

    /// Not every function updates this. See docs of `amqp_get_rpc_reply`.
    pub fn last_rpc_reply(self: Connection) RpcReply {
        return amqp_get_rpc_reply(self.handle);
    }

    pub fn login(
        self: Connection,
        vhost: [*:0]const u8,
        sasl_auth: SaslAuth,
        extra: struct {
            heartbeat: c_int,
            channel_max: c_int = DEFAULT_MAX_CHANNELS,
            frame_max: c_int = DEFAULT_FRAME_SIZE,
        },
    ) !void {
        return switch (sasl_auth) {
            .plain => |plain| amqp_login(self.handle, vhost, extra.channel_max, extra.frame_max, extra.heartbeat, AMQP_SASL_METHOD_PLAIN, plain.username, plain.password),
            .external => |external| amqp_login(self.handle, vhost, extra.channel_max, extra.frame_max, extra.heartbeat, AMQP_SASL_METHOD_EXTERNAL, external.identity),
        }.ok();
    }

    pub fn login_with_properties(
        self: Connection,
        vhost: [*:0]const u8,
        sasl_auth: SaslAuth,
        extra: struct {
            heartbeat: c_int,
            channel_max: c_int = DEFAULT_MAX_CHANNELS,
            frame_max: c_int = DEFAULT_FRAME_SIZE,
            properties: [*c]const table_t,
        },
    ) !void {
        return switch (sasl_auth) {
            .plain => |plain| amqp_login_with_properties(self.handle, vhost, extra.channel_max, extra.frame_max, extra.heartbeat, extra.properties, AMQP_SASL_METHOD_PLAIN, plain.username, plain.password),
            .external => |external| amqp_login_with_properties(self.handle, vhost, extra.channel_max, extra.frame_max, extra.heartbeat, extra.properties, AMQP_SASL_METHOD_EXTERNAL, external.identity),
        }.ok();
    }

    pub fn simple_wait_frame(self: Connection, timeout: ?*c.timeval) !Frame {
        var f: Frame = undefined;
        try amqp_simple_wait_frame_noblock(self.handle, &f, timeout).ok();
        return f;
    }

    pub fn consume_message(self: Connection, timeout: ?*c.timeval, flags: c_int) !Envelope {
        var e: Envelope = undefined;
        try amqp_consume_message(self.handle, &e, timeout, flags).ok();
        return e;
    }

    pub fn channel(self: Connection, number: channel_t) Channel {
        return .{ .connection = self, .number = number };
    }

    pub const SaslAuth = union(enum) {
        plain: struct {
            username: [*:0]const u8,
            password: [*:0]const u8,
        },
        external: struct {
            identity: [*:0]const u8,
        },
    };
};

pub const Channel = struct {
    connection: Connection,
    number: channel_t,

    pub fn open(self: Channel) !*channel_open_ok_t {
        return amqp_channel_open(self.connection.handle, self.number) orelse self.connection.last_rpc_reply().err();
    }

    pub fn close(self: Channel, code: ReplyCode) !void {
        return amqp_channel_close(self.connection.handle, self.number, @intFromEnum(code)).ok();
    }

    pub fn exchange_declare(
        self: Channel,
        exchange: bytes_t,
        type_: bytes_t,
        extra: struct {
            passive: bool = false,
            durable: bool = false,
            auto_delete: bool = false,
            internal: bool = false,
            arguments: table_t = table_t.empty(),
        },
    ) !void {
        _ = amqp_exchange_declare(
            self.connection.handle,
            self.number,
            exchange,
            type_,
            @intFromBool(extra.passive),
            @intFromBool(extra.durable),
            @intFromBool(extra.auto_delete),
            @intFromBool(extra.internal),
            extra.arguments,
        ) orelse return self.connection.last_rpc_reply().err();
    }

    pub fn queue_declare(
        self: Channel,
        queue: bytes_t,
        extra: struct {
            passive: bool = false,
            durable: bool = false,
            exclusive: bool = false,
            auto_delete: bool = false,
            arguments: table_t = table_t.empty(),
        },
    ) !*queue_declare_ok_t {
        return amqp_queue_declare(
            self.connection.handle,
            self.number,
            queue,
            @intFromBool(extra.passive),
            @intFromBool(extra.durable),
            @intFromBool(extra.exclusive),
            @intFromBool(extra.auto_delete),
            extra.arguments,
        ) orelse self.connection.last_rpc_reply().err();
    }

    pub fn queue_bind(self: Channel, queue: bytes_t, exchange: bytes_t, routing_key: bytes_t, arguments: table_t) !void {
        _ = amqp_queue_bind(self.connection.handle, self.number, queue, exchange, routing_key, arguments) orelse return self.connection.last_rpc_reply().err();
    }

    pub fn queue_unbind(self: Channel, queue: bytes_t, exchange: bytes_t, routing_key: bytes_t, arguments: table_t) !void {
        _ = amqp_queue_unbind(self.connection.handle, self.number, queue, exchange, routing_key, arguments) orelse return self.connection.last_rpc_reply().err();
    }

    pub fn basic_publish(
        self: Channel,
        exchange: bytes_t,
        routing_key: bytes_t,
        body: bytes_t,
        properties: BasicProperties,
        extra: struct {
            mandatory: bool = false,
            immediate: bool = false,
        },
    ) !void {
        return amqp_basic_publish(
            self.connection.handle,
            self.number,
            exchange,
            routing_key,
            @intFromBool(extra.mandatory),
            @intFromBool(extra.immediate),
            &properties,
            body,
        ).ok();
    }

    pub fn basic_consume(
        self: Channel,
        queue: bytes_t,
        extra: struct {
            consumer_tag: bytes_t = bytes_t.empty(),
            no_local: bool = false,
            no_ack: bool = false,
            exclusive: bool = false,
            arguments: table_t = table_t.empty(),
        },
    ) !*basic_consume_ok_t {
        return amqp_basic_consume(
            self.connection.handle,
            self.number,
            queue,
            extra.consumer_tag,
            @intFromBool(extra.no_local),
            @intFromBool(extra.no_ack),
            @intFromBool(extra.exclusive),
            extra.arguments,
        ) orelse self.connection.last_rpc_reply().err();
    }

    pub fn basic_cancel(self: Channel, consumer_tag: bytes_t) !*amqp_basic_cancel_ok_t {
        return amqp_basic_cancel(self.connection.handle, self.number, consumer_tag) orelse self.connection.last_rpc_reply().err();
    }

    pub fn basic_ack(self: Channel, delivery_tag: u64, multiple: bool) !void {
        return amqp_basic_ack(self.connection.handle, self.number, delivery_tag, @intFromBool(multiple)).ok();
    }

    pub fn basic_reject(self: Channel, delivery_tag: u64, requeue: bool) !void {
        return amqp_basic_reject(self.connection.handle, self.number, delivery_tag, @intFromBool(requeue)).ok();
    }

    pub fn basic_qos(self: Channel, prefetch_size: u32, prefetch_count: u16, global: bool) !void {
        _ = amqp_basic_qos(
            self.connection.handle,
            self.number,
            prefetch_size,
            prefetch_count,
            @intFromBool(global),
        ) orelse return self.connection.last_rpc_reply().err();
    }

    pub fn read_message(self: Channel, flags: c_int) !Message {
        var msg: Message = undefined;
        try amqp_read_message(self.connection.handle, self.number, &msg, flags).ok();
        return msg;
    }

    pub fn maybe_release_buffers(self: Channel) void {
        amqp_maybe_release_buffers_on_channel(self.connection.handle, self.number);
    }
};

pub const socket_t = opaque {};

pub const TcpSocket = struct {
    handle: *amqp_socket_t,

    pub fn new(connection: *Connection) error{OutOfMemory}!TcpSocket {
        return TcpSocket{ .handle = amqp_tcp_socket_new(connection.handle) orelse return error.OutOfMemory };
    }

    pub fn set_sockfd(self: TcpSocket, sockfd: c_int) void {
        amqp_tcp_socket_set_sockfd(self.handle, sockfd);
    }

    pub fn open(self: TcpSocket, host: [*:0]const u8, port: c_int, timeout: ?*c.timeval) !void {
        return amqp_socket_open_noblock(self.handle, host, port, timeout).ok();
    }
};

pub const SslSocket = struct {
    handle: *socket_t,

    pub fn new(connection: Connection) error{OutOfMemory}!SslSocket {
        return SslSocket{ .handle = amqp_ssl_socket_new(connection.handle) orelse return error.OutOfMemory };
    }

    pub fn open(self: SslSocket, host: [*:0]const u8, port: c_int, timeout: ?*c.timeval) !void {
        return amqp_socket_open_noblock(self.handle, host, port, timeout).ok();
    }

    pub fn set_cacert(self: SslSocket, cacert_path: [*:0]const u8) !void {
        return amqp_ssl_socket_set_cacert(self.handle, cacert_path).ok();
    }

    pub fn set_key(self: SslSocket, cert_path: [*:0]const u8, key_path: [*:0]const u8) !void {
        return amqp_ssl_socket_set_key(self.handle, cert_path, key_path).ok();
    }

    pub fn set_key_buffer(self: SslSocket, cert_path: [*:0]const u8, key: []const u8) !void {
        return amqp_ssl_socket_set_key_buffer(self.handle, cert_path, key.ptr, key.len).ok();
    }

    pub fn set_verify_peer(self: SslSocket, verify: bool) void {
        amqp_ssl_socket_set_verify_peer(self.handle, @intFromBool(verify));
    }

    pub fn set_verify_hostname(self: SslSocket, verify: bool) void {
        amqp_ssl_socket_set_verify_hostname(self.handle, @intFromBool(verify));
    }

    pub fn set_ssl_versions(self: SslSocket, min: TlsVersion, max: TlsVersion) error{ Unsupported, InvalidParameter, Unexpected }!void {
        return switch (amqp_ssl_socket_set_ssl_versions(self.handle, min, max)) {
            .OK => {},
            .UNSUPPORTED => error.Unsupported,
            .INVALID_PARAMETER => error.InvalidParameter,
            else => |code| unexpected(code),
        };
    }

    const TlsVersion = enum(c_int) {
        v1 = 1,
        v1_1 = 2,
        v1_2 = 3,
        vLATEST = 65535,
        _,
    };
};

/// Do not use fields directly to avoid bugs.
pub const BasicProperties = extern struct {
    _flags: flags_t,
    _content_type: bytes_t,
    _content_encoding: bytes_t,
    _headers: table_t,
    _delivery_mode: u8,
    _priority: u8,
    _correlation_id: bytes_t,
    _reply_to: bytes_t,
    _expiration: bytes_t,
    _message_id: bytes_t,
    _timestamp: u64,
    _type_: bytes_t,
    _user_id: bytes_t,
    _app_id: bytes_t,
    _cluster_id: bytes_t,

    pub fn init(fields: anytype) BasicProperties {
        var props: BasicProperties = undefined;
        props._flags = 0;

        inline for (meta.fields(@TypeOf(fields))) |f| {
            @field(props, "_" ++ f.name) = @field(fields, f.name);
            props._flags |= @intFromEnum(@field(Flag, f.name));
        }

        return props;
    }

    pub fn get(self: BasicProperties, comptime flag: Flag) ?flag.Type() {
        if (self._flags & @intFromEnum(flag) == 0) return null;
        return @field(self, "_" ++ @tagName(flag));
    }

    pub fn set(self: *BasicProperties, comptime flag: Flag, value: ?flag.Type()) void {
        if (value) |val| {
            self._flags |= @intFromEnum(flag);
            @field(self, "_" ++ @tagName(flag)) = val;
        } else {
            self._flags &= ~@intFromEnum(flag);
            @field(self, "_" ++ @tagName(flag)) = undefined;
        }
    }

    pub const Flag = enum(flags_t) {
        content_type = 1 << 15,
        content_encoding = 1 << 14,
        headers = 1 << 13,
        delivery_mode = 1 << 12,
        priority = 1 << 11,
        correlation_id = 1 << 10,
        reply_to = 1 << 9,
        expiration = 1 << 8,
        message_id = 1 << 7,
        timestamp = 1 << 6,
        type_ = 1 << 5,
        user_id = 1 << 4,
        app_id = 1 << 3,
        cluster_id = 1 << 2,
        _,

        pub fn Type(flag: Flag) type {
            const needle = "_" ++ @tagName(flag);
            inline for (comptime meta.fields(BasicProperties)) |field| {
                if (comptime mem.eql(u8, field.name, needle)) return field.type;
            }
            unreachable;
        }
    };
};

pub const pool_blocklist_t = extern struct {
    num_blocks: c_int,
    blocklist: [*]?*anyopaque,
};

pub const pool_t = extern struct {
    pagesize: usize,
    pages: pool_blocklist_t,
    large_blocks: pool_blocklist_t,
    next_page: c_int,
    alloc_block: [*]u8,
    alloc_used: usize,
};

pub const Message = extern struct {
    properties: BasicProperties,
    body: bytes_t,
    pool: pool_t,

    pub fn destroy(self: *Message) void {
        amqp_destroy_message(self);
    }
};

pub const Envelope = extern struct {
    channel: channel_t,
    consumer_tag: bytes_t,
    delivery_tag: u64,
    redelivered: boolean_t,
    exchange: bytes_t,
    routing_key: bytes_t,
    message: Message,

    pub fn destroy(self: *Envelope) void {
        amqp_destroy_envelope(self);
    }
};

pub const Frame = extern struct {
    frame_type: Type,
    channel: channel_t,
    payload: extern union {
        /// frame_type == .METHOD
        method: method_t,
        /// frame_type == .HEADER
        properties: extern struct {
            class_id: u16,
            body_size: u64,
            decoded: ?*anyopaque,
            raw: bytes_t,
        },
        /// frame_type == BODY
        body_fragment: bytes_t,
        /// used during initial handshake
        protocol_header: extern struct {
            transport_high: u8,
            transport_low: u8,
            protocol_version_major: u8,
            protocol_version_minor: u8,
        },
    },

    pub const Type = enum(u8) {
        METHOD = 1,
        HEADER = 2,
        BODY = 3,
        HEARTBEAT = 8,
        _,
    };
};

fn unexpected(status: status_t) error{Unexpected} {
    log.err("unexpected librabbitmq error, code {}, message {s}", .{ status, status.string() });
    return error.Unexpected;
}

pub const ReplyCode = enum(u16) {
    REPLY_SUCCESS = 200,
    CONTENT_TOO_LARGE = 311,
    NO_ROUTE = 312,
    NO_CONSUMERS = 313,
    ACCESS_REFUSED = 403,
    NOT_FOUND = 404,
    RESOURCE_LOCKED = 405,
    PRECONDITION_FAILED = 406,
    CONNECTION_FORCED = 320,
    INVALID_PATH = 402,
    FRAME_ERROR = 501,
    SYNTAX_ERROR = 502,
    COMMAND_INVALID = 503,
    CHANNEL_ERROR = 504,
    UNEXPECTED_FRAME = 505,
    RESOURCE_ERROR = 506,
    NOT_ALLOWED = 530,
    NOT_IMPLEMENTED = 540,
    INTERNAL_ERROR = 541,
};

pub const LibraryError = error{
    OutOfMemory,
    BadAmqpData,
    UnknownClass,
    UnknownMethod,
    HostnameResolutionFailed,
    IncompatibleAmqpVersion,
    ConnectionClosed,
    BadUrl,
    SocketError,
    InvalidParameter,
    TableTooBig,
    WrongMethod,
    Timeout,
    TimerFailure,
    HeartbeatTimeout,
    UnexpectedState,
    SocketClosed,
    SocketInUse,
    BrokerUnsupportedSaslMethod,
    Unsupported,
    TcpError,
    TcpSocketlibInitError,
    SslError,
    SslHostnameVerifyFailed,
    SslPeerVerifyFailed,
    SslConnectionFailed,
    Unexpected,
};

pub const ServerError = error{
    ConnectionClosed,
    ChannelClosed,
    UnexpectedReply,
};

pub const Error = ServerError || LibraryError;

pub const status_t = enum(c_int) {
    OK = 0,
    NO_MEMORY = -1,
    BAD_AMQP_DATA = -2,
    UNKNOWN_CLASS = -3,
    UNKNOWN_METHOD = -4,
    HOSTNAME_RESOLUTION_FAILED = -5,
    INCOMPATIBLE_AMQP_VERSION = -6,
    CONNECTION_CLOSED = -7,
    BAD_URL = -8,
    SOCKET_ERROR = -9,
    INVALID_PARAMETER = -10,
    TABLE_TOO_BIG = -11,
    WRONG_METHOD = -12,
    TIMEOUT = -13,
    TIMER_FAILURE = -14,
    HEARTBEAT_TIMEOUT = -15,
    UNEXPECTED_STATE = -16,
    SOCKET_CLOSED = -17,
    SOCKET_INUSE = -18,
    BROKER_UNSUPPORTED_SASL_METHOD = -19,
    UNSUPPORTED = -20,
    TCP_ERROR = -256,
    TCP_SOCKETLIB_INIT_ERROR = -257,
    SSL_ERROR = -512,
    SSL_HOSTNAME_VERIFY_FAILED = -513,
    SSL_PEER_VERIFY_FAILED = -514,
    SSL_CONNECTION_FAILED = -515,
    _,

    pub fn ok(status: status_t) LibraryError!void {
        return switch (status) {
            .OK => {},
            .NO_MEMORY => error.OutOfMemory,
            .BAD_AMQP_DATA => error.BadAmqpData,
            .UNKNOWN_CLASS => error.UnknownClass,
            .UNKNOWN_METHOD => error.UnknownMethod,
            .HOSTNAME_RESOLUTION_FAILED => error.HostnameResolutionFailed,
            .INCOMPATIBLE_AMQP_VERSION => error.IncompatibleAmqpVersion,
            .CONNECTION_CLOSED => error.ConnectionClosed,
            .BAD_URL => error.BadUrl,
            .SOCKET_ERROR => error.SocketError,
            .INVALID_PARAMETER => error.InvalidParameter,
            .TABLE_TOO_BIG => error.TableTooBig,
            .WRONG_METHOD => error.WrongMethod,
            .TIMEOUT => error.Timeout,
            .TIMER_FAILURE => error.TimerFailure,
            .HEARTBEAT_TIMEOUT => error.HeartbeatTimeout,
            .UNEXPECTED_STATE => error.UnexpectedState,
            .SOCKET_CLOSED => error.SocketClosed,
            .SOCKET_INUSE => error.SocketInUse,
            .BROKER_UNSUPPORTED_SASL_METHOD => error.BrokerUnsupportedSaslMethod,
            .UNSUPPORTED => error.Unsupported,
            .TCP_ERROR => error.TcpError,
            .TCP_SOCKETLIB_INIT_ERROR => error.TcpSocketlibInitError,
            .SSL_ERROR => error.SslError,
            .SSL_HOSTNAME_VERIFY_FAILED => error.SslHostnameVerifyFailed,
            .SSL_PEER_VERIFY_FAILED => error.SslPeerVerifyFailed,
            .SSL_CONNECTION_FAILED => error.SslConnectionFailed,
            _ => unexpected(status),
        };
    }

    pub fn string(self: status_t) [*c]const u8 {
        return amqp_error_string2(@intFromEnum(self));
    }
};

pub const method_number_t = enum(u32) {
    CONNECTION_START = 0x000A000A,
    CONNECTION_START_OK = 0x000A000B,
    CONNECTION_SECURE = 0x000A0014,
    CONNECTION_SECURE_OK = 0x000A0015,
    CONNECTION_TUNE = 0x000A001E,
    CONNECTION_TUNE_OK = 0x000A001F,
    CONNECTION_OPEN = 0x000A0028,
    CONNECTION_OPEN_OK = 0x000A0029,
    CONNECTION_CLOSE = 0x000A0032,
    CONNECTION_CLOSE_OK = 0x000A0033,
    CONNECTION_BLOCKED = 0x000A003C,
    CONNECTION_UNBLOCKED = 0x000A003D,
    CHANNEL_OPEN = 0x0014000A,
    CHANNEL_OPEN_OK = 0x0014000B,
    CHANNEL_FLOW = 0x00140014,
    CHANNEL_FLOW_OK = 0x00140015,
    CHANNEL_CLOSE = 0x00140028,
    CHANNEL_CLOSE_OK = 0x00140029,
    ACCESS_REQUEST = 0x001E000A,
    ACCESS_REQUEST_OK = 0x001E000B,
    EXCHANGE_DECLARE = 0x0028000A,
    EXCHANGE_DECLARE_OK = 0x0028000B,
    EXCHANGE_DELETE = 0x00280014,
    EXCHANGE_DELETE_OK = 0x00280015,
    EXCHANGE_BIND = 0x0028001E,
    EXCHANGE_BIND_OK = 0x0028001F,
    EXCHANGE_UNBIND = 0x00280028,
    EXCHANGE_UNBIND_OK = 0x00280033,
    QUEUE_DECLARE = 0x0032000A,
    QUEUE_DECLARE_OK = 0x0032000B,
    QUEUE_BIND = 0x00320014,
    QUEUE_BIND_OK = 0x00320015,
    QUEUE_PURGE = 0x0032001E,
    QUEUE_PURGE_OK = 0x0032001F,
    QUEUE_DELETE = 0x00320028,
    QUEUE_DELETE_OK = 0x00320029,
    QUEUE_UNBIND = 0x00320032,
    QUEUE_UNBIND_OK = 0x00320033,
    BASIC_QOS = 0x003C000A,
    BASIC_QOS_OK = 0x003C000B,
    BASIC_CONSUME = 0x003C0014,
    BASIC_CONSUME_OK = 0x003C0015,
    BASIC_CANCEL = 0x003C001E,
    BASIC_CANCEL_OK = 0x003C001F,
    BASIC_PUBLISH = 0x003C0028,
    BASIC_RETURN = 0x003C0032,
    BASIC_DELIVER = 0x003C003C,
    BASIC_GET = 0x003C0046,
    BASIC_GET_OK = 0x003C0047,
    BASIC_GET_EMPTY = 0x003C0048,
    BASIC_ACK = 0x003C0050,
    BASIC_REJECT = 0x003C005A,
    BASIC_RECOVER_ASYNC = 0x003C0064,
    BASIC_RECOVER = 0x003C006E,
    BASIC_RECOVER_OK = 0x003C006F,
    BASIC_NACK = 0x003C0078,
    TX_SELECT = 0x005A000A,
    TX_SELECT_OK = 0x005A000B,
    TX_COMMIT = 0x005A0014,
    TX_COMMIT_OK = 0x005A0015,
    TX_ROLLBACK = 0x005A001E,
    TX_ROLLBACK_OK = 0x005A001F,
    CONFIRM_SELECT = 0x0055000A,
    CONFIRM_SELECT_OK = 0x0055000B,
    _,
};

pub const method_t = extern struct {
    id: method_number_t,
    decoded: ?*anyopaque,
};

pub const RpcReply = extern struct {
    reply_type: response_type_t,
    reply: method_t,
    library_error: status_t,

    pub fn ok(self: RpcReply) Error!void {
        return switch (self.reply_type) {
            .NORMAL => {},
            .NONE => error.SocketError,
            .LIBRARY_EXCEPTION => self.library_error.ok(),
            .SERVER_EXCEPTION => switch (self.reply.id) {
                .CONNECTION_CLOSE => error.ConnectionClosed,
                .CHANNEL_CLOSE => error.ChannelClosed,
                else => error.UnexpectedReply,
            },
            _ => {
                log.err("unexpected librabbitmq response type, value {}", .{self.reply_type});
                return error.Unexpected;
            },
        };
    }

    pub fn err(self: RpcReply) Error {
        if (self.ok()) |_| {
            log.err("expected librabbitmq error, got success instead", .{});
            return error.Unexpected;
        } else |e| return e;
    }

    pub const response_type_t =
        enum(c_int) {
            NONE = 0,
            NORMAL = 1,
            LIBRARY_EXCEPTION = 2,
            SERVER_EXCEPTION = 3,
            _,
        };
};

pub const channel_open_ok_t = extern struct {
    channel_id: bytes_t,
};

pub const queue_declare_ok_t = extern struct {
    queue: bytes_t,
    message_count: u32,
    consumer_count: u32,
};

pub const basic_consume_ok_t = extern struct {
    consumer_tag: bytes_t,
};

pub const connection_close_t = extern struct {
    reply_code: ReplyCode,
    reply_text: bytes_t,
    class_id: u16,
    method_id: u16,
};

pub const channel_close_t = extern struct {
    reply_code: ReplyCode,
    reply_text: bytes_t,
    class_id: u16,
    method_id: u16,
};

// EXTERN:
pub const __builtin_bswap16 = std.zig.c_builtins.__builtin_bswap16;
pub const __builtin_bswap32 = std.zig.c_builtins.__builtin_bswap32;
pub const __builtin_bswap64 = std.zig.c_builtins.__builtin_bswap64;
pub const __builtin_signbit = std.zig.c_builtins.__builtin_signbit;
pub const __builtin_signbitf = std.zig.c_builtins.__builtin_signbitf;
pub const __builtin_popcount = std.zig.c_builtins.__builtin_popcount;
pub const __builtin_ctz = std.zig.c_builtins.__builtin_ctz;
pub const __builtin_clz = std.zig.c_builtins.__builtin_clz;
pub const __builtin_sqrt = std.zig.c_builtins.__builtin_sqrt;
pub const __builtin_sqrtf = std.zig.c_builtins.__builtin_sqrtf;
pub const __builtin_sin = std.zig.c_builtins.__builtin_sin;
pub const __builtin_sinf = std.zig.c_builtins.__builtin_sinf;
pub const __builtin_cos = std.zig.c_builtins.__builtin_cos;
pub const __builtin_cosf = std.zig.c_builtins.__builtin_cosf;
pub const __builtin_exp = std.zig.c_builtins.__builtin_exp;
pub const __builtin_expf = std.zig.c_builtins.__builtin_expf;
pub const __builtin_exp2 = std.zig.c_builtins.__builtin_exp2;
pub const __builtin_exp2f = std.zig.c_builtins.__builtin_exp2f;
pub const __builtin_log = std.zig.c_builtins.__builtin_log;
pub const __builtin_logf = std.zig.c_builtins.__builtin_logf;
pub const __builtin_log2 = std.zig.c_builtins.__builtin_log2;
pub const __builtin_log2f = std.zig.c_builtins.__builtin_log2f;
pub const __builtin_log10 = std.zig.c_builtins.__builtin_log10;
pub const __builtin_log10f = std.zig.c_builtins.__builtin_log10f;
pub const __builtin_abs = std.zig.c_builtins.__builtin_abs;
pub const __builtin_labs = std.zig.c_builtins.__builtin_labs;
pub const __builtin_llabs = std.zig.c_builtins.__builtin_llabs;
pub const __builtin_fabs = std.zig.c_builtins.__builtin_fabs;
pub const __builtin_fabsf = std.zig.c_builtins.__builtin_fabsf;
pub const __builtin_floor = std.zig.c_builtins.__builtin_floor;
pub const __builtin_floorf = std.zig.c_builtins.__builtin_floorf;
pub const __builtin_ceil = std.zig.c_builtins.__builtin_ceil;
pub const __builtin_ceilf = std.zig.c_builtins.__builtin_ceilf;
pub const __builtin_trunc = std.zig.c_builtins.__builtin_trunc;
pub const __builtin_truncf = std.zig.c_builtins.__builtin_truncf;
pub const __builtin_round = std.zig.c_builtins.__builtin_round;
pub const __builtin_roundf = std.zig.c_builtins.__builtin_roundf;
pub const __builtin_strlen = std.zig.c_builtins.__builtin_strlen;
pub const __builtin_strcmp = std.zig.c_builtins.__builtin_strcmp;
pub const __builtin_object_size = std.zig.c_builtins.__builtin_object_size;
pub const __builtin___memset_chk = std.zig.c_builtins.__builtin___memset_chk;
pub const __builtin_memset = std.zig.c_builtins.__builtin_memset;
pub const __builtin___memcpy_chk = std.zig.c_builtins.__builtin___memcpy_chk;
pub const __builtin_memcpy = std.zig.c_builtins.__builtin_memcpy;
pub const __builtin_expect = std.zig.c_builtins.__builtin_expect;
pub const __builtin_nanf = std.zig.c_builtins.__builtin_nanf;
pub const __builtin_huge_valf = std.zig.c_builtins.__builtin_huge_valf;
pub const __builtin_inff = std.zig.c_builtins.__builtin_inff;
pub const __builtin_isnan = std.zig.c_builtins.__builtin_isnan;
pub const __builtin_isinf = std.zig.c_builtins.__builtin_isinf;
pub const __builtin_isinf_sign = std.zig.c_builtins.__builtin_isinf_sign;
pub const __has_builtin = std.zig.c_builtins.__has_builtin;
pub const __builtin_assume = std.zig.c_builtins.__builtin_assume;
pub const __builtin_unreachable = std.zig.c_builtins.__builtin_unreachable;
pub const __builtin_constant_p = std.zig.c_builtins.__builtin_constant_p;
pub const __builtin_mul_overflow = std.zig.c_builtins.__builtin_mul_overflow;
pub const ptrdiff_t = c_longlong;
pub const wchar_t = c_ushort;
pub const max_align_t = extern struct {
    __clang_max_align_nonce1: c_longlong align(8) = std.mem.zeroes(c_longlong),
    __clang_max_align_nonce2: c_longdouble align(16) = std.mem.zeroes(c_longdouble),
};
pub const struct_timeval = c.timeval;
pub extern fn amqp_version_number() c_uint;
pub extern fn amqp_version() [*c]const u8;
pub const amqp_boolean_t = c_int;
pub const amqp_method_number_t = method_number_t;
pub const amqp_flags_t = c_uint;
pub const amqp_channel_t = c_ushort;
pub const struct_amqp_bytes_t_ = bytes_t;
pub const amqp_bytes_t = struct_amqp_bytes_t_;
pub const struct_amqp_decimal_t_ = extern struct {
    decimals: c_ushort = std.mem.zeroes(c_ushort),
    value: c_uint = std.mem.zeroes(c_uint),
};
pub const amqp_decimal_t = struct_amqp_decimal_t_;
pub const amqp_table_t = struct_amqp_table_t_;
pub const struct_amqp_array_t_ = extern struct {
    num_entries: c_int = std.mem.zeroes(c_int),
    entries: [*c]struct_amqp_field_value_t_ = std.mem.zeroes([*c]struct_amqp_field_value_t_),
};
pub const amqp_array_t = struct_amqp_array_t_;
const union_unnamed_1 = extern union {
    boolean: amqp_boolean_t,
    i8: c_short,
    u8: c_ushort,
    i16: c_short,
    u16: c_ushort,
    i32: c_int,
    u32: c_uint,
    i64: c_longlong,
    u64: c_ulonglong,
    f32: f32,
    f64: f64,
    decimal: amqp_decimal_t,
    bytes: amqp_bytes_t,
    table: amqp_table_t,
    array: amqp_array_t,
};
pub const struct_amqp_field_value_t_ = extern struct {
    kind: c_ushort = std.mem.zeroes(c_ushort),
    value: union_unnamed_1 = std.mem.zeroes(union_unnamed_1),
};
pub const amqp_field_value_t = struct_amqp_field_value_t_;
pub const struct_amqp_table_entry_t_ = extern struct {
    key: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    value: amqp_field_value_t = std.mem.zeroes(amqp_field_value_t),
};
pub const struct_amqp_table_t_ = table_t;
pub const amqp_table_entry_t = struct_amqp_table_entry_t_;
pub const AMQP_FIELD_KIND_BOOLEAN: c_int = 116;
pub const AMQP_FIELD_KIND_I8: c_int = 98;
pub const AMQP_FIELD_KIND_U8: c_int = 66;
pub const AMQP_FIELD_KIND_I16: c_int = 115;
pub const AMQP_FIELD_KIND_U16: c_int = 117;
pub const AMQP_FIELD_KIND_I32: c_int = 73;
pub const AMQP_FIELD_KIND_U32: c_int = 105;
pub const AMQP_FIELD_KIND_I64: c_int = 108;
pub const AMQP_FIELD_KIND_U64: c_int = 76;
pub const AMQP_FIELD_KIND_F32: c_int = 102;
pub const AMQP_FIELD_KIND_F64: c_int = 100;
pub const AMQP_FIELD_KIND_DECIMAL: c_int = 68;
pub const AMQP_FIELD_KIND_UTF8: c_int = 83;
pub const AMQP_FIELD_KIND_ARRAY: c_int = 65;
pub const AMQP_FIELD_KIND_TIMESTAMP: c_int = 84;
pub const AMQP_FIELD_KIND_TABLE: c_int = 70;
pub const AMQP_FIELD_KIND_VOID: c_int = 86;
pub const AMQP_FIELD_KIND_BYTES: c_int = 120;
pub const amqp_field_value_kind_t = c_uint;
pub const struct_amqp_pool_blocklist_t_ = extern struct {
    num_blocks: c_int = std.mem.zeroes(c_int),
    blocklist: [*c]?*anyopaque = std.mem.zeroes([*c]?*anyopaque),
};
pub const amqp_pool_blocklist_t = struct_amqp_pool_blocklist_t_;
pub const struct_amqp_pool_t_ = extern struct {
    pagesize: usize = std.mem.zeroes(usize),
    pages: amqp_pool_blocklist_t = std.mem.zeroes(amqp_pool_blocklist_t),
    large_blocks: amqp_pool_blocklist_t = std.mem.zeroes(amqp_pool_blocklist_t),
    next_page: c_int = std.mem.zeroes(c_int),
    alloc_block: [*c]u8 = std.mem.zeroes([*c]u8),
    alloc_used: usize = std.mem.zeroes(usize),
};
pub const amqp_pool_t = struct_amqp_pool_t_;
pub const struct_amqp_method_t_ = method_t;
pub const amqp_method_t = struct_amqp_method_t_;
const struct_unnamed_3 = extern struct {
    class_id: c_ushort = std.mem.zeroes(c_ushort),
    body_size: c_ulonglong = std.mem.zeroes(c_ulonglong),
    decoded: ?*anyopaque = std.mem.zeroes(?*anyopaque),
    raw: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
};
const struct_unnamed_4 = extern struct {
    transport_high: c_ushort = std.mem.zeroes(c_ushort),
    transport_low: c_ushort = std.mem.zeroes(c_ushort),
    protocol_version_major: c_ushort = std.mem.zeroes(c_ushort),
    protocol_version_minor: c_ushort = std.mem.zeroes(c_ushort),
};
const union_unnamed_2 = extern union {
    method: amqp_method_t,
    properties: struct_unnamed_3,
    body_fragment: amqp_bytes_t,
    protocol_header: struct_unnamed_4,
};
pub const struct_amqp_frame_t_ = Frame;
pub const amqp_frame_t = struct_amqp_frame_t_;
pub const AMQP_RESPONSE_NONE: c_int = 0;
pub const AMQP_RESPONSE_NORMAL: c_int = 1;
pub const AMQP_RESPONSE_LIBRARY_EXCEPTION: c_int = 2;
pub const AMQP_RESPONSE_SERVER_EXCEPTION: c_int = 3;
pub const enum_amqp_response_type_enum_ = c_uint;
pub const amqp_response_type_enum = enum_amqp_response_type_enum_;
pub const struct_amqp_rpc_reply_t_ = RpcReply;
pub const amqp_rpc_reply_t = struct_amqp_rpc_reply_t_;
pub const AMQP_SASL_METHOD_UNDEFINED: c_int = -1;
pub const AMQP_SASL_METHOD_PLAIN: c_int = 0;
pub const AMQP_SASL_METHOD_EXTERNAL: c_int = 1;
pub const enum_amqp_sasl_method_enum_ = c_int;
pub const amqp_sasl_method_enum = enum_amqp_sasl_method_enum_;
pub const struct_amqp_connection_state_t_ = Connection;
pub const amqp_connection_state_t = ?*struct_amqp_connection_state_t_;
pub const struct_amqp_socket_t_ = socket_t;
pub const amqp_socket_t = struct_amqp_socket_t_;
pub const AMQP_STATUS_OK: c_int = 0;
pub const AMQP_STATUS_NO_MEMORY: c_int = -1;
pub const AMQP_STATUS_BAD_AMQP_DATA: c_int = -2;
pub const AMQP_STATUS_UNKNOWN_CLASS: c_int = -3;
pub const AMQP_STATUS_UNKNOWN_METHOD: c_int = -4;
pub const AMQP_STATUS_HOSTNAME_RESOLUTION_FAILED: c_int = -5;
pub const AMQP_STATUS_INCOMPATIBLE_AMQP_VERSION: c_int = -6;
pub const AMQP_STATUS_CONNECTION_CLOSED: c_int = -7;
pub const AMQP_STATUS_BAD_URL: c_int = -8;
pub const AMQP_STATUS_SOCKET_ERROR: c_int = -9;
pub const AMQP_STATUS_INVALID_PARAMETER: c_int = -10;
pub const AMQP_STATUS_TABLE_TOO_BIG: c_int = -11;
pub const AMQP_STATUS_WRONG_METHOD: c_int = -12;
pub const AMQP_STATUS_TIMEOUT: c_int = -13;
pub const AMQP_STATUS_TIMER_FAILURE: c_int = -14;
pub const AMQP_STATUS_HEARTBEAT_TIMEOUT: c_int = -15;
pub const AMQP_STATUS_UNEXPECTED_STATE: c_int = -16;
pub const AMQP_STATUS_SOCKET_CLOSED: c_int = -17;
pub const AMQP_STATUS_SOCKET_INUSE: c_int = -18;
pub const AMQP_STATUS_BROKER_UNSUPPORTED_SASL_METHOD: c_int = -19;
pub const AMQP_STATUS_UNSUPPORTED: c_int = -20;
pub const _AMQP_STATUS_NEXT_VALUE: c_int = -21;
pub const AMQP_STATUS_TCP_ERROR: c_int = -256;
pub const AMQP_STATUS_TCP_SOCKETLIB_INIT_ERROR: c_int = -257;
pub const _AMQP_STATUS_TCP_NEXT_VALUE: c_int = -258;
pub const AMQP_STATUS_SSL_ERROR: c_int = -512;
pub const AMQP_STATUS_SSL_HOSTNAME_VERIFY_FAILED: c_int = -513;
pub const AMQP_STATUS_SSL_PEER_VERIFY_FAILED: c_int = -514;
pub const AMQP_STATUS_SSL_CONNECTION_FAILED: c_int = -515;
pub const AMQP_STATUS_SSL_SET_ENGINE_FAILED: c_int = -516;
pub const AMQP_STATUS_SSL_UNIMPLEMENTED: c_int = -517;
pub const _AMQP_STATUS_SSL_NEXT_VALUE: c_int = -518;
pub const enum_amqp_status_enum_ = c_int;
pub const amqp_status_enum = enum_amqp_status_enum_;
pub const AMQP_DELIVERY_NONPERSISTENT: c_int = 1;
pub const AMQP_DELIVERY_PERSISTENT: c_int = 2;
pub const amqp_delivery_mode_enum = c_uint;
pub extern fn amqp_constant_name(constantNumber: c_int) [*c]const u8;
pub extern fn amqp_constant_is_hard_error(constantNumber: c_int) amqp_boolean_t;
pub extern fn amqp_method_name(methodNumber: amqp_method_number_t) [*c]const u8;
pub extern fn amqp_method_has_content(methodNumber: amqp_method_number_t) amqp_boolean_t;
pub extern fn amqp_decode_method(methodNumber: amqp_method_number_t, pool: [*c]amqp_pool_t, encoded: amqp_bytes_t, decoded: [*c]?*anyopaque) c_int;
pub extern fn amqp_decode_properties(class_id: c_ushort, pool: [*c]amqp_pool_t, encoded: amqp_bytes_t, decoded: [*c]?*anyopaque) c_int;
pub extern fn amqp_encode_method(methodNumber: amqp_method_number_t, decoded: ?*anyopaque, encoded: amqp_bytes_t) c_int;
pub extern fn amqp_encode_properties(class_id: c_ushort, decoded: ?*anyopaque, encoded: amqp_bytes_t) c_int;
pub const struct_amqp_connection_start_t_ = extern struct {
    version_major: c_ushort = std.mem.zeroes(c_ushort),
    version_minor: c_ushort = std.mem.zeroes(c_ushort),
    server_properties: amqp_table_t = std.mem.zeroes(amqp_table_t),
    mechanisms: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    locales: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
};
pub const amqp_connection_start_t = struct_amqp_connection_start_t_;
pub const struct_amqp_connection_start_ok_t_ = extern struct {
    client_properties: amqp_table_t = std.mem.zeroes(amqp_table_t),
    mechanism: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    response: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    locale: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
};
pub const amqp_connection_start_ok_t = struct_amqp_connection_start_ok_t_;
pub const struct_amqp_connection_secure_t_ = extern struct {
    challenge: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
};
pub const amqp_connection_secure_t = struct_amqp_connection_secure_t_;
pub const struct_amqp_connection_secure_ok_t_ = extern struct {
    response: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
};
pub const amqp_connection_secure_ok_t = struct_amqp_connection_secure_ok_t_;
pub const struct_amqp_connection_tune_t_ = extern struct {
    channel_max: c_ushort = std.mem.zeroes(c_ushort),
    frame_max: c_uint = std.mem.zeroes(c_uint),
    heartbeat: c_ushort = std.mem.zeroes(c_ushort),
};
pub const amqp_connection_tune_t = struct_amqp_connection_tune_t_;
pub const struct_amqp_connection_tune_ok_t_ = extern struct {
    channel_max: c_ushort = std.mem.zeroes(c_ushort),
    frame_max: c_uint = std.mem.zeroes(c_uint),
    heartbeat: c_ushort = std.mem.zeroes(c_ushort),
};
pub const amqp_connection_tune_ok_t = struct_amqp_connection_tune_ok_t_;
pub const struct_amqp_connection_open_t_ = extern struct {
    virtual_host: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    capabilities: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    insist: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
};
pub const amqp_connection_open_t = struct_amqp_connection_open_t_;
pub const struct_amqp_connection_open_ok_t_ = extern struct {
    known_hosts: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
};
pub const amqp_connection_open_ok_t = struct_amqp_connection_open_ok_t_;
pub const struct_amqp_connection_close_t_ = extern struct {
    reply_code: c_ushort = std.mem.zeroes(c_ushort),
    reply_text: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    class_id: c_ushort = std.mem.zeroes(c_ushort),
    method_id: c_ushort = std.mem.zeroes(c_ushort),
};
pub const amqp_connection_close_t = struct_amqp_connection_close_t_;
pub const struct_amqp_connection_close_ok_t_ = extern struct {
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_connection_close_ok_t = struct_amqp_connection_close_ok_t_;
pub const struct_amqp_connection_blocked_t_ = extern struct {
    reason: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
};
pub const amqp_connection_blocked_t = struct_amqp_connection_blocked_t_;
pub const struct_amqp_connection_unblocked_t_ = extern struct {
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_connection_unblocked_t = struct_amqp_connection_unblocked_t_;
pub const struct_amqp_connection_update_secret_t_ = extern struct {
    new_secret: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    reason: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
};
pub const amqp_connection_update_secret_t = struct_amqp_connection_update_secret_t_;
pub const struct_amqp_connection_update_secret_ok_t_ = extern struct {
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_connection_update_secret_ok_t = struct_amqp_connection_update_secret_ok_t_;
pub const struct_amqp_channel_open_t_ = extern struct {
    out_of_band: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
};
pub const amqp_channel_open_t = struct_amqp_channel_open_t_;
pub const struct_amqp_channel_open_ok_t_ = channel_open_ok_t;
pub const amqp_channel_open_ok_t = struct_amqp_channel_open_ok_t_;
pub const struct_amqp_channel_flow_t_ = extern struct {
    active: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
};
pub const amqp_channel_flow_t = struct_amqp_channel_flow_t_;
pub const struct_amqp_channel_flow_ok_t_ = extern struct {
    active: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
};
pub const amqp_channel_flow_ok_t = struct_amqp_channel_flow_ok_t_;
pub const struct_amqp_channel_close_t_ = extern struct {
    reply_code: c_ushort = std.mem.zeroes(c_ushort),
    reply_text: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    class_id: c_ushort = std.mem.zeroes(c_ushort),
    method_id: c_ushort = std.mem.zeroes(c_ushort),
};
pub const amqp_channel_close_t = struct_amqp_channel_close_t_;
pub const struct_amqp_channel_close_ok_t_ = extern struct {
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_channel_close_ok_t = struct_amqp_channel_close_ok_t_;
pub const struct_amqp_access_request_t_ = extern struct {
    realm: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    exclusive: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    passive: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    active: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    write: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    read: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
};
pub const amqp_access_request_t = struct_amqp_access_request_t_;
pub const struct_amqp_access_request_ok_t_ = extern struct {
    ticket: c_ushort = std.mem.zeroes(c_ushort),
};
pub const amqp_access_request_ok_t = struct_amqp_access_request_ok_t_;
pub const struct_amqp_exchange_declare_t_ = extern struct {
    ticket: c_ushort = std.mem.zeroes(c_ushort),
    exchange: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    type: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    passive: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    durable: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    auto_delete: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    internal: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    nowait: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    arguments: amqp_table_t = std.mem.zeroes(amqp_table_t),
};
pub const amqp_exchange_declare_t = struct_amqp_exchange_declare_t_;
pub const struct_amqp_exchange_declare_ok_t_ = extern struct {
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_exchange_declare_ok_t = struct_amqp_exchange_declare_ok_t_;
pub const struct_amqp_exchange_delete_t_ = extern struct {
    ticket: c_ushort = std.mem.zeroes(c_ushort),
    exchange: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    if_unused: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    nowait: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
};
pub const amqp_exchange_delete_t = struct_amqp_exchange_delete_t_;
pub const struct_amqp_exchange_delete_ok_t_ = extern struct {
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_exchange_delete_ok_t = struct_amqp_exchange_delete_ok_t_;
pub const struct_amqp_exchange_bind_t_ = extern struct {
    ticket: c_ushort = std.mem.zeroes(c_ushort),
    destination: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    source: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    routing_key: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    nowait: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    arguments: amqp_table_t = std.mem.zeroes(amqp_table_t),
};
pub const amqp_exchange_bind_t = struct_amqp_exchange_bind_t_;
pub const struct_amqp_exchange_bind_ok_t_ = extern struct {
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_exchange_bind_ok_t = struct_amqp_exchange_bind_ok_t_;
pub const struct_amqp_exchange_unbind_t_ = extern struct {
    ticket: c_ushort = std.mem.zeroes(c_ushort),
    destination: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    source: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    routing_key: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    nowait: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    arguments: amqp_table_t = std.mem.zeroes(amqp_table_t),
};
pub const amqp_exchange_unbind_t = struct_amqp_exchange_unbind_t_;
pub const struct_amqp_exchange_unbind_ok_t_ = extern struct {
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_exchange_unbind_ok_t = struct_amqp_exchange_unbind_ok_t_;
pub const struct_amqp_queue_declare_t_ = extern struct {
    ticket: c_ushort = std.mem.zeroes(c_ushort),
    queue: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    passive: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    durable: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    exclusive: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    auto_delete: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    nowait: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    arguments: amqp_table_t = std.mem.zeroes(amqp_table_t),
};
pub const amqp_queue_declare_t = struct_amqp_queue_declare_t_;
pub const struct_amqp_queue_declare_ok_t_ = queue_declare_ok_t;
pub const amqp_queue_declare_ok_t = struct_amqp_queue_declare_ok_t_;
pub const struct_amqp_queue_bind_t_ = extern struct {
    ticket: c_ushort = std.mem.zeroes(c_ushort),
    queue: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    exchange: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    routing_key: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    nowait: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    arguments: amqp_table_t = std.mem.zeroes(amqp_table_t),
};
pub const amqp_queue_bind_t = struct_amqp_queue_bind_t_;
pub const struct_amqp_queue_bind_ok_t_ = extern struct {
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_queue_bind_ok_t = struct_amqp_queue_bind_ok_t_;
pub const struct_amqp_queue_purge_t_ = extern struct {
    ticket: c_ushort = std.mem.zeroes(c_ushort),
    queue: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    nowait: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
};
pub const amqp_queue_purge_t = struct_amqp_queue_purge_t_;
pub const struct_amqp_queue_purge_ok_t_ = extern struct {
    message_count: c_uint = std.mem.zeroes(c_uint),
};
pub const amqp_queue_purge_ok_t = struct_amqp_queue_purge_ok_t_;
pub const struct_amqp_queue_delete_t_ = extern struct {
    ticket: c_ushort = std.mem.zeroes(c_ushort),
    queue: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    if_unused: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    if_empty: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    nowait: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
};
pub const amqp_queue_delete_t = struct_amqp_queue_delete_t_;
pub const struct_amqp_queue_delete_ok_t_ = extern struct {
    message_count: c_uint = std.mem.zeroes(c_uint),
};
pub const amqp_queue_delete_ok_t = struct_amqp_queue_delete_ok_t_;
pub const struct_amqp_queue_unbind_t_ = extern struct {
    ticket: c_ushort = std.mem.zeroes(c_ushort),
    queue: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    exchange: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    routing_key: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    arguments: amqp_table_t = std.mem.zeroes(amqp_table_t),
};
pub const amqp_queue_unbind_t = struct_amqp_queue_unbind_t_;
pub const struct_amqp_queue_unbind_ok_t_ = extern struct {
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_queue_unbind_ok_t = struct_amqp_queue_unbind_ok_t_;
pub const struct_amqp_basic_qos_t_ = extern struct {
    prefetch_size: c_uint = std.mem.zeroes(c_uint),
    prefetch_count: c_ushort = std.mem.zeroes(c_ushort),
    global: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
};
pub const amqp_basic_qos_t = struct_amqp_basic_qos_t_;
pub const struct_amqp_basic_qos_ok_t_ = extern struct {
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_basic_qos_ok_t = struct_amqp_basic_qos_ok_t_;
pub const struct_amqp_basic_consume_t_ = extern struct {
    ticket: c_ushort = std.mem.zeroes(c_ushort),
    queue: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    consumer_tag: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    no_local: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    no_ack: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    exclusive: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    nowait: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    arguments: amqp_table_t = std.mem.zeroes(amqp_table_t),
};
pub const amqp_basic_consume_t = struct_amqp_basic_consume_t_;
pub const struct_amqp_basic_consume_ok_t_ = basic_consume_ok_t;
pub const amqp_basic_consume_ok_t = struct_amqp_basic_consume_ok_t_;
pub const struct_amqp_basic_cancel_t_ = extern struct {
    consumer_tag: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    nowait: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
};
pub const amqp_basic_cancel_t = struct_amqp_basic_cancel_t_;
pub const struct_amqp_basic_cancel_ok_t_ = extern struct {
    consumer_tag: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
};
pub const amqp_basic_cancel_ok_t = struct_amqp_basic_cancel_ok_t_;
pub const struct_amqp_basic_publish_t_ = extern struct {
    ticket: c_ushort = std.mem.zeroes(c_ushort),
    exchange: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    routing_key: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    mandatory: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    immediate: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
};
pub const amqp_basic_publish_t = struct_amqp_basic_publish_t_;
pub const struct_amqp_basic_return_t_ = extern struct {
    reply_code: c_ushort = std.mem.zeroes(c_ushort),
    reply_text: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    exchange: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    routing_key: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
};
pub const amqp_basic_return_t = struct_amqp_basic_return_t_;
pub const struct_amqp_basic_deliver_t_ = extern struct {
    consumer_tag: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    delivery_tag: c_ulonglong = std.mem.zeroes(c_ulonglong),
    redelivered: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    exchange: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    routing_key: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
};
pub const amqp_basic_deliver_t = struct_amqp_basic_deliver_t_;
pub const struct_amqp_basic_get_t_ = extern struct {
    ticket: c_ushort = std.mem.zeroes(c_ushort),
    queue: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    no_ack: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
};
pub const amqp_basic_get_t = struct_amqp_basic_get_t_;
pub const struct_amqp_basic_get_ok_t_ = extern struct {
    delivery_tag: c_ulonglong = std.mem.zeroes(c_ulonglong),
    redelivered: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    exchange: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    routing_key: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    message_count: c_uint = std.mem.zeroes(c_uint),
};
pub const amqp_basic_get_ok_t = struct_amqp_basic_get_ok_t_;
pub const struct_amqp_basic_get_empty_t_ = extern struct {
    cluster_id: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
};
pub const amqp_basic_get_empty_t = struct_amqp_basic_get_empty_t_;
pub const struct_amqp_basic_ack_t_ = extern struct {
    delivery_tag: c_ulonglong = std.mem.zeroes(c_ulonglong),
    multiple: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
};
pub const amqp_basic_ack_t = struct_amqp_basic_ack_t_;
pub const struct_amqp_basic_reject_t_ = extern struct {
    delivery_tag: c_ulonglong = std.mem.zeroes(c_ulonglong),
    requeue: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
};
pub const amqp_basic_reject_t = struct_amqp_basic_reject_t_;
pub const struct_amqp_basic_recover_async_t_ = extern struct {
    requeue: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
};
pub const amqp_basic_recover_async_t = struct_amqp_basic_recover_async_t_;
pub const struct_amqp_basic_recover_t_ = extern struct {
    requeue: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
};
pub const amqp_basic_recover_t = struct_amqp_basic_recover_t_;
pub const struct_amqp_basic_recover_ok_t_ = extern struct {
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_basic_recover_ok_t = struct_amqp_basic_recover_ok_t_;
pub const struct_amqp_basic_nack_t_ = extern struct {
    delivery_tag: c_ulonglong = std.mem.zeroes(c_ulonglong),
    multiple: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
    requeue: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
};
pub const amqp_basic_nack_t = struct_amqp_basic_nack_t_;
pub const struct_amqp_tx_select_t_ = extern struct {
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_tx_select_t = struct_amqp_tx_select_t_;
pub const struct_amqp_tx_select_ok_t_ = extern struct {
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_tx_select_ok_t = struct_amqp_tx_select_ok_t_;
pub const struct_amqp_tx_commit_t_ = extern struct {
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_tx_commit_t = struct_amqp_tx_commit_t_;
pub const struct_amqp_tx_commit_ok_t_ = extern struct {
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_tx_commit_ok_t = struct_amqp_tx_commit_ok_t_;
pub const struct_amqp_tx_rollback_t_ = extern struct {
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_tx_rollback_t = struct_amqp_tx_rollback_t_;
pub const struct_amqp_tx_rollback_ok_t_ = extern struct {
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_tx_rollback_ok_t = struct_amqp_tx_rollback_ok_t_;
pub const struct_amqp_confirm_select_t_ = extern struct {
    nowait: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
};
pub const amqp_confirm_select_t = struct_amqp_confirm_select_t_;
pub const struct_amqp_confirm_select_ok_t_ = extern struct {
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_confirm_select_ok_t = struct_amqp_confirm_select_ok_t_;
pub const struct_amqp_connection_properties_t_ = extern struct {
    _flags: amqp_flags_t = std.mem.zeroes(amqp_flags_t),
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_connection_properties_t = struct_amqp_connection_properties_t_;
pub const struct_amqp_channel_properties_t_ = extern struct {
    _flags: amqp_flags_t = std.mem.zeroes(amqp_flags_t),
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_channel_properties_t = struct_amqp_channel_properties_t_;
pub const struct_amqp_access_properties_t_ = extern struct {
    _flags: amqp_flags_t = std.mem.zeroes(amqp_flags_t),
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_access_properties_t = struct_amqp_access_properties_t_;
pub const struct_amqp_exchange_properties_t_ = extern struct {
    _flags: amqp_flags_t = std.mem.zeroes(amqp_flags_t),
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_exchange_properties_t = struct_amqp_exchange_properties_t_;
pub const struct_amqp_queue_properties_t_ = extern struct {
    _flags: amqp_flags_t = std.mem.zeroes(amqp_flags_t),
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_queue_properties_t = struct_amqp_queue_properties_t_;
pub const struct_amqp_basic_properties_t_ = BasicProperties;
pub const amqp_basic_properties_t = struct_amqp_basic_properties_t_;
pub const struct_amqp_tx_properties_t_ = extern struct {
    _flags: amqp_flags_t = std.mem.zeroes(amqp_flags_t),
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_tx_properties_t = struct_amqp_tx_properties_t_;
pub const struct_amqp_confirm_properties_t_ = extern struct {
    _flags: amqp_flags_t = std.mem.zeroes(amqp_flags_t),
    dummy: u8 = std.mem.zeroes(u8),
};
pub const amqp_confirm_properties_t = struct_amqp_confirm_properties_t_;
pub extern fn amqp_connection_update_secret(state: amqp_connection_state_t, channel: amqp_channel_t, new_secret: amqp_bytes_t, reason: amqp_bytes_t) [*c]amqp_connection_update_secret_ok_t;
pub extern fn amqp_channel_open(state: amqp_connection_state_t, channel: amqp_channel_t) [*c]amqp_channel_open_ok_t;
pub extern fn amqp_channel_flow(state: amqp_connection_state_t, channel: amqp_channel_t, active: amqp_boolean_t) [*c]amqp_channel_flow_ok_t;
pub extern fn amqp_exchange_declare(state: amqp_connection_state_t, channel: amqp_channel_t, exchange: amqp_bytes_t, @"type": amqp_bytes_t, passive: amqp_boolean_t, durable: amqp_boolean_t, auto_delete: amqp_boolean_t, internal: amqp_boolean_t, arguments: amqp_table_t) [*c]amqp_exchange_declare_ok_t;
pub extern fn amqp_exchange_delete(state: amqp_connection_state_t, channel: amqp_channel_t, exchange: amqp_bytes_t, if_unused: amqp_boolean_t) [*c]amqp_exchange_delete_ok_t;
pub extern fn amqp_exchange_bind(state: amqp_connection_state_t, channel: amqp_channel_t, destination: amqp_bytes_t, source: amqp_bytes_t, routing_key: amqp_bytes_t, arguments: amqp_table_t) [*c]amqp_exchange_bind_ok_t;
pub extern fn amqp_exchange_unbind(state: amqp_connection_state_t, channel: amqp_channel_t, destination: amqp_bytes_t, source: amqp_bytes_t, routing_key: amqp_bytes_t, arguments: amqp_table_t) [*c]amqp_exchange_unbind_ok_t;
pub extern fn amqp_queue_declare(state: amqp_connection_state_t, channel: amqp_channel_t, queue: amqp_bytes_t, passive: amqp_boolean_t, durable: amqp_boolean_t, exclusive: amqp_boolean_t, auto_delete: amqp_boolean_t, arguments: amqp_table_t) [*c]amqp_queue_declare_ok_t;
pub extern fn amqp_queue_bind(state: amqp_connection_state_t, channel: amqp_channel_t, queue: amqp_bytes_t, exchange: amqp_bytes_t, routing_key: amqp_bytes_t, arguments: amqp_table_t) [*c]amqp_queue_bind_ok_t;
pub extern fn amqp_queue_purge(state: amqp_connection_state_t, channel: amqp_channel_t, queue: amqp_bytes_t) [*c]amqp_queue_purge_ok_t;
pub extern fn amqp_queue_delete(state: amqp_connection_state_t, channel: amqp_channel_t, queue: amqp_bytes_t, if_unused: amqp_boolean_t, if_empty: amqp_boolean_t) [*c]amqp_queue_delete_ok_t;
pub extern fn amqp_queue_unbind(state: amqp_connection_state_t, channel: amqp_channel_t, queue: amqp_bytes_t, exchange: amqp_bytes_t, routing_key: amqp_bytes_t, arguments: amqp_table_t) [*c]amqp_queue_unbind_ok_t;
pub extern fn amqp_basic_qos(state: amqp_connection_state_t, channel: amqp_channel_t, prefetch_size: c_uint, prefetch_count: c_ushort, global: amqp_boolean_t) [*c]amqp_basic_qos_ok_t;
pub extern fn amqp_basic_consume(state: amqp_connection_state_t, channel: amqp_channel_t, queue: amqp_bytes_t, consumer_tag: amqp_bytes_t, no_local: amqp_boolean_t, no_ack: amqp_boolean_t, exclusive: amqp_boolean_t, arguments: amqp_table_t) [*c]amqp_basic_consume_ok_t;
pub extern fn amqp_basic_cancel(state: amqp_connection_state_t, channel: amqp_channel_t, consumer_tag: amqp_bytes_t) [*c]amqp_basic_cancel_ok_t;
pub extern fn amqp_basic_recover(state: amqp_connection_state_t, channel: amqp_channel_t, requeue: amqp_boolean_t) [*c]amqp_basic_recover_ok_t;
pub extern fn amqp_tx_select(state: amqp_connection_state_t, channel: amqp_channel_t) [*c]amqp_tx_select_ok_t;
pub extern fn amqp_tx_commit(state: amqp_connection_state_t, channel: amqp_channel_t) [*c]amqp_tx_commit_ok_t;
pub extern fn amqp_tx_rollback(state: amqp_connection_state_t, channel: amqp_channel_t) [*c]amqp_tx_rollback_ok_t;
pub extern fn amqp_confirm_select(state: amqp_connection_state_t, channel: amqp_channel_t) [*c]amqp_confirm_select_ok_t;
pub extern const amqp_empty_bytes: amqp_bytes_t;
pub extern const amqp_empty_table: amqp_table_t;
pub extern const amqp_empty_array: amqp_array_t;
pub extern fn init_amqp_pool(pool: [*c]amqp_pool_t, pagesize: usize) void;
pub extern fn recycle_amqp_pool(pool: [*c]amqp_pool_t) void;
pub extern fn empty_amqp_pool(pool: [*c]amqp_pool_t) void;
pub extern fn amqp_pool_alloc(pool: [*c]amqp_pool_t, amount: usize) ?*anyopaque;
pub extern fn amqp_pool_alloc_bytes(pool: [*c]amqp_pool_t, amount: usize, output: [*c]amqp_bytes_t) void;
pub extern fn amqp_cstring_bytes(cstr: [*c]const u8) amqp_bytes_t;
pub extern fn amqp_bytes_malloc_dup(src: amqp_bytes_t) amqp_bytes_t;
pub extern fn amqp_bytes_malloc(amount: usize) amqp_bytes_t;
pub extern fn amqp_bytes_free(bytes: amqp_bytes_t) void;
pub extern fn amqp_new_connection() amqp_connection_state_t;
pub extern fn amqp_get_sockfd(state: amqp_connection_state_t) c_int;
pub extern fn amqp_set_sockfd(state: amqp_connection_state_t, sockfd: c_int) void;
pub extern fn amqp_tune_connection(state: amqp_connection_state_t, channel_max: c_int, frame_max: c_int, heartbeat: c_int) status_t;
pub extern fn amqp_get_channel_max(state: amqp_connection_state_t) c_int;
pub extern fn amqp_get_frame_max(state: amqp_connection_state_t) c_int;
pub extern fn amqp_get_heartbeat(state: amqp_connection_state_t) c_int;
pub extern fn amqp_destroy_connection(state: amqp_connection_state_t) status_t;
pub extern fn amqp_handle_input(state: amqp_connection_state_t, received_data: amqp_bytes_t, decoded_frame: [*c]amqp_frame_t) c_int;
pub extern fn amqp_release_buffers_ok(state: amqp_connection_state_t) amqp_boolean_t;
pub extern fn amqp_release_buffers(state: amqp_connection_state_t) void;
pub extern fn amqp_maybe_release_buffers(state: amqp_connection_state_t) void;
pub extern fn amqp_maybe_release_buffers_on_channel(state: amqp_connection_state_t, channel: amqp_channel_t) void;
pub extern fn amqp_send_frame(state: amqp_connection_state_t, frame: [*c]const amqp_frame_t) status_t;
pub extern fn amqp_table_entry_cmp(entry1: ?*const anyopaque, entry2: ?*const anyopaque) c_int;
pub extern fn amqp_open_socket(hostname: [*c]const u8, portnumber: c_int) status_t;
pub extern fn amqp_send_header(state: amqp_connection_state_t) c_int;
pub extern fn amqp_frames_enqueued(state: amqp_connection_state_t) amqp_boolean_t;
pub extern fn amqp_simple_wait_frame(state: amqp_connection_state_t, decoded_frame: [*c]amqp_frame_t) status_t;
pub extern fn amqp_simple_wait_frame_noblock(state: amqp_connection_state_t, decoded_frame: [*c]amqp_frame_t, tv: ?*const struct_timeval) status_t;
pub extern fn amqp_simple_wait_method(state: amqp_connection_state_t, expected_channel: amqp_channel_t, expected_method: amqp_method_number_t, output: [*c]amqp_method_t) status_t;
pub extern fn amqp_send_method(state: amqp_connection_state_t, channel: amqp_channel_t, id: amqp_method_number_t, decoded: ?*anyopaque) status_t;
pub extern fn amqp_simple_rpc(state: amqp_connection_state_t, channel: amqp_channel_t, request_id: amqp_method_number_t, expected_reply_ids: [*c]amqp_method_number_t, decoded_request_method: ?*anyopaque) amqp_rpc_reply_t;
pub extern fn amqp_simple_rpc_decoded(state: amqp_connection_state_t, channel: amqp_channel_t, request_id: amqp_method_number_t, reply_id: amqp_method_number_t, decoded_request_method: ?*anyopaque) ?*anyopaque;
pub extern fn amqp_get_rpc_reply(state: amqp_connection_state_t) amqp_rpc_reply_t;
pub extern fn amqp_login(state: amqp_connection_state_t, vhost: [*c]const u8, channel_max: c_int, frame_max: c_int, heartbeat: c_int, sasl_method: amqp_sasl_method_enum, ...) amqp_rpc_reply_t;
pub extern fn amqp_login_with_properties(state: amqp_connection_state_t, vhost: [*c]const u8, channel_max: c_int, frame_max: c_int, heartbeat: c_int, properties: [*c]const amqp_table_t, sasl_method: amqp_sasl_method_enum, ...) amqp_rpc_reply_t;
pub extern fn amqp_basic_publish(state: amqp_connection_state_t, channel: amqp_channel_t, exchange: amqp_bytes_t, routing_key: amqp_bytes_t, mandatory: amqp_boolean_t, immediate: amqp_boolean_t, properties: [*c]const struct_amqp_basic_properties_t_, body: amqp_bytes_t) status_t;
pub extern fn amqp_channel_close(state: amqp_connection_state_t, channel: amqp_channel_t, code: c_int) amqp_rpc_reply_t;
pub extern fn amqp_connection_close(state: amqp_connection_state_t, code: c_int) amqp_rpc_reply_t;
pub extern fn amqp_basic_ack(state: amqp_connection_state_t, channel: amqp_channel_t, delivery_tag: c_ulonglong, multiple: amqp_boolean_t) status_t;
pub extern fn amqp_basic_get(state: amqp_connection_state_t, channel: amqp_channel_t, queue: amqp_bytes_t, no_ack: amqp_boolean_t) amqp_rpc_reply_t;
pub extern fn amqp_basic_reject(state: amqp_connection_state_t, channel: amqp_channel_t, delivery_tag: c_ulonglong, requeue: amqp_boolean_t) status_t;
pub extern fn amqp_basic_nack(state: amqp_connection_state_t, channel: amqp_channel_t, delivery_tag: c_ulonglong, multiple: amqp_boolean_t, requeue: amqp_boolean_t) status_t;
pub extern fn amqp_data_in_buffer(state: amqp_connection_state_t) amqp_boolean_t;
pub extern fn amqp_error_string(err: c_int) [*c]u8;
pub extern fn amqp_error_string2(err: c_int) [*c]const u8;
pub extern fn amqp_decode_table(encoded: amqp_bytes_t, pool: [*c]amqp_pool_t, output: [*c]amqp_table_t, offset: [*c]usize) status_t;
pub extern fn amqp_encode_table(encoded: amqp_bytes_t, input: [*c]amqp_table_t, offset: [*c]usize) status_t;
pub extern fn amqp_table_clone(original: [*c]const amqp_table_t, clone: [*c]amqp_table_t, pool: [*c]amqp_pool_t) status_t;
pub const struct_amqp_message_t_ = extern struct {
    properties: amqp_basic_properties_t = std.mem.zeroes(amqp_basic_properties_t),
    body: amqp_bytes_t = std.mem.zeroes(amqp_bytes_t),
    pool: amqp_pool_t = std.mem.zeroes(amqp_pool_t),
};
pub const amqp_message_t = struct_amqp_message_t_;
pub extern fn amqp_read_message(state: amqp_connection_state_t, channel: amqp_channel_t, message: [*c]amqp_message_t, flags: c_int) amqp_rpc_reply_t;
pub extern fn amqp_destroy_message(message: [*c]amqp_message_t) void;
pub const struct_amqp_envelope_t_ = Envelope;
pub const amqp_envelope_t = struct_amqp_envelope_t_;
pub extern fn amqp_consume_message(state: amqp_connection_state_t, envelope: [*c]amqp_envelope_t, timeout: ?*const struct_timeval, flags: c_int) amqp_rpc_reply_t;
pub extern fn amqp_destroy_envelope(envelope: [*c]amqp_envelope_t) void;
pub const struct_amqp_connection_info = extern struct {
    user: [*c]u8 = std.mem.zeroes([*c]u8),
    password: [*c]u8 = std.mem.zeroes([*c]u8),
    host: [*c]u8 = std.mem.zeroes([*c]u8),
    vhost: [*c]u8 = std.mem.zeroes([*c]u8),
    port: c_int = std.mem.zeroes(c_int),
    ssl: amqp_boolean_t = std.mem.zeroes(amqp_boolean_t),
};
pub extern fn amqp_default_connection_info(parsed: [*c]struct_amqp_connection_info) void;
pub extern fn amqp_parse_url(url: [*c]u8, parsed: [*c]struct_amqp_connection_info) c_int;
pub extern fn amqp_socket_open(self: ?*amqp_socket_t, host: [*c]const u8, port: c_int) status_t;
pub extern fn amqp_socket_open_noblock(self: ?*amqp_socket_t, host: [*c]const u8, port: c_int, timeout: ?*const struct_timeval) status_t;
pub extern fn amqp_socket_get_sockfd(self: ?*amqp_socket_t) c_int;
pub extern fn amqp_get_socket(state: amqp_connection_state_t) ?*amqp_socket_t;
pub extern fn amqp_get_server_properties(state: amqp_connection_state_t) [*c]amqp_table_t;
pub extern fn amqp_get_client_properties(state: amqp_connection_state_t) [*c]amqp_table_t;
pub extern fn amqp_get_handshake_timeout(state: amqp_connection_state_t) ?*struct_timeval;
pub extern fn amqp_set_handshake_timeout(state: amqp_connection_state_t, timeout: ?*const struct_timeval) c_int;
pub extern fn amqp_get_rpc_timeout(state: amqp_connection_state_t) ?*struct_timeval;
pub extern fn amqp_set_rpc_timeout(state: amqp_connection_state_t, timeout: ?*const struct_timeval) c_int;
pub const union_amqp_publisher_confirm_payload_t_ = extern union {
    ack: amqp_basic_ack_t,
    nack: amqp_basic_nack_t,
    reject: amqp_basic_reject_t,
};
pub const amqp_publisher_confirm_payload_t = union_amqp_publisher_confirm_payload_t_;
pub const struct_amqp_publisher_confirm_t_ = extern struct {
    payload: amqp_publisher_confirm_payload_t = std.mem.zeroes(amqp_publisher_confirm_payload_t),
    channel: amqp_channel_t = std.mem.zeroes(amqp_channel_t),
    method: amqp_method_number_t = std.mem.zeroes(amqp_method_number_t),
};
pub const amqp_publisher_confirm_t = struct_amqp_publisher_confirm_t_;
pub extern fn amqp_publisher_confirm_wait(state: amqp_connection_state_t, timeout: ?*const struct_timeval, result: [*c]amqp_publisher_confirm_t) amqp_rpc_reply_t;
pub extern fn amqp_tcp_socket_new(state: amqp_connection_state_t) ?*amqp_socket_t;
pub extern fn amqp_tcp_socket_set_sockfd(self: ?*amqp_socket_t, sockfd: c_int) void;
pub extern fn amqp_ssl_socket_new(state: amqp_connection_state_t) ?*amqp_socket_t;
pub extern fn amqp_ssl_socket_get_context(self: ?*amqp_socket_t) ?*anyopaque;
pub extern fn amqp_ssl_socket_enable_default_verify_paths(self: ?*amqp_socket_t) c_int;
pub extern fn amqp_ssl_socket_set_cacert(self: ?*amqp_socket_t, cacert: [*c]const u8) c_int;
pub extern fn amqp_ssl_socket_set_key_passwd(self: ?*amqp_socket_t, passwd: [*c]const u8) void;
pub extern fn amqp_ssl_socket_set_key(self: ?*amqp_socket_t, cert: [*c]const u8, key: [*c]const u8) c_int;
pub extern fn amqp_ssl_socket_set_key_engine(self: ?*amqp_socket_t, cert: [*c]const u8, key: [*c]const u8) c_int;
pub extern fn amqp_ssl_socket_set_key_buffer(self: ?*amqp_socket_t, cert: [*c]const u8, key: ?*const anyopaque, n: usize) c_int;
pub extern fn amqp_ssl_socket_set_verify(self: ?*amqp_socket_t, verify: amqp_boolean_t) void;
pub extern fn amqp_ssl_socket_set_verify_peer(self: ?*amqp_socket_t, verify: amqp_boolean_t) void;
pub extern fn amqp_ssl_socket_set_verify_hostname(self: ?*amqp_socket_t, verify: amqp_boolean_t) void;
pub const AMQP_TLSv1: c_int = 1;
pub const AMQP_TLSv1_1: c_int = 2;
pub const AMQP_TLSv1_2: c_int = 3;
pub const AMQP_TLSv1_3: c_int = 4;
pub const AMQP_TLSvLATEST: c_int = 65535;
pub const amqp_tls_version_t = c_uint;
pub extern fn amqp_ssl_socket_set_ssl_versions(self: ?*amqp_socket_t, min: amqp_tls_version_t, max: amqp_tls_version_t) c_int;
pub extern fn amqp_set_initialize_ssl_library(do_initialize: amqp_boolean_t) void;
pub extern fn amqp_initialize_ssl_library() c_int;
pub extern fn amqp_set_ssl_engine(engine: [*c]const u8) c_int;
pub extern fn amqp_uninitialize_ssl_library() c_int;
pub const __llvm__ = @as(c_int, 1);
pub const __clang__ = @as(c_int, 1);
pub const __clang_major__ = @as(c_int, 18);
pub const __clang_minor__ = @as(c_int, 1);
pub const __clang_patchlevel__ = @as(c_int, 6);
pub const __clang_version__ = "18.1.6 (https://github.com/ziglang/zig-bootstrap 98bc6bf4fc4009888d33941daf6b600d20a42a56)";
pub const __GNUC__ = @as(c_int, 4);
pub const __GNUC_MINOR__ = @as(c_int, 2);
pub const __GNUC_PATCHLEVEL__ = @as(c_int, 1);
pub const __GXX_ABI_VERSION = @as(c_int, 1002);
pub const __ATOMIC_RELAXED = @as(c_int, 0);
pub const __ATOMIC_CONSUME = @as(c_int, 1);
pub const __ATOMIC_ACQUIRE = @as(c_int, 2);
pub const __ATOMIC_RELEASE = @as(c_int, 3);
pub const __ATOMIC_ACQ_REL = @as(c_int, 4);
pub const __ATOMIC_SEQ_CST = @as(c_int, 5);
pub const __MEMORY_SCOPE_SYSTEM = @as(c_int, 0);
pub const __MEMORY_SCOPE_DEVICE = @as(c_int, 1);
pub const __MEMORY_SCOPE_WRKGRP = @as(c_int, 2);
pub const __MEMORY_SCOPE_WVFRNT = @as(c_int, 3);
pub const __MEMORY_SCOPE_SINGLE = @as(c_int, 4);
pub const __OPENCL_MEMORY_SCOPE_WORK_ITEM = @as(c_int, 0);
pub const __OPENCL_MEMORY_SCOPE_WORK_GROUP = @as(c_int, 1);
pub const __OPENCL_MEMORY_SCOPE_DEVICE = @as(c_int, 2);
pub const __OPENCL_MEMORY_SCOPE_ALL_SVM_DEVICES = @as(c_int, 3);
pub const __OPENCL_MEMORY_SCOPE_SUB_GROUP = @as(c_int, 4);
pub const __FPCLASS_SNAN = @as(c_int, 0x0001);
pub const __FPCLASS_QNAN = @as(c_int, 0x0002);
pub const __FPCLASS_NEGINF = @as(c_int, 0x0004);
pub const __FPCLASS_NEGNORMAL = @as(c_int, 0x0008);
pub const __FPCLASS_NEGSUBNORMAL = @as(c_int, 0x0010);
pub const __FPCLASS_NEGZERO = @as(c_int, 0x0020);
pub const __FPCLASS_POSZERO = @as(c_int, 0x0040);
pub const __FPCLASS_POSSUBNORMAL = @as(c_int, 0x0080);
pub const __FPCLASS_POSNORMAL = @as(c_int, 0x0100);
pub const __FPCLASS_POSINF = @as(c_int, 0x0200);
pub const __PRAGMA_REDEFINE_EXTNAME = @as(c_int, 1);
pub const __VERSION__ = "Clang 18.1.6 (https://github.com/ziglang/zig-bootstrap 98bc6bf4fc4009888d33941daf6b600d20a42a56)";
pub const __OBJC_BOOL_IS_BOOL = @as(c_int, 0);
pub const __CONSTANT_CFSTRINGS__ = @as(c_int, 1);
pub const __SEH__ = @as(c_int, 1);
pub const __clang_literal_encoding__ = "UTF-8";
pub const __clang_wide_literal_encoding__ = "UTF-16";
pub const __ORDER_LITTLE_ENDIAN__ = @as(c_int, 1234);
pub const __ORDER_BIG_ENDIAN__ = @as(c_int, 4321);
pub const __ORDER_PDP_ENDIAN__ = @as(c_int, 3412);
pub const __BYTE_ORDER__ = __ORDER_LITTLE_ENDIAN__;
pub const __LITTLE_ENDIAN__ = @as(c_int, 1);
pub const __CHAR_BIT__ = @as(c_int, 8);
pub const __BOOL_WIDTH__ = @as(c_int, 8);
pub const __SHRT_WIDTH__ = @as(c_int, 16);
pub const __INT_WIDTH__ = @as(c_int, 32);
pub const __LONG_WIDTH__ = @as(c_int, 32);
pub const __LLONG_WIDTH__ = @as(c_int, 64);
pub const __BITINT_MAXWIDTH__ = std.zig.c_translation.promoteIntLiteral(c_int, 8388608, .decimal);
pub const __SCHAR_MAX__ = @as(c_int, 127);
pub const __SHRT_MAX__ = @as(c_int, 32767);
pub const __INT_MAX__ = std.zig.c_translation.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __LONG_MAX__ = @as(c_long, 2147483647);
pub const __LONG_LONG_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __WCHAR_MAX__ = std.zig.c_translation.promoteIntLiteral(c_int, 65535, .decimal);
pub const __WCHAR_WIDTH__ = @as(c_int, 16);
pub const __WINT_MAX__ = std.zig.c_translation.promoteIntLiteral(c_int, 65535, .decimal);
pub const __WINT_WIDTH__ = @as(c_int, 16);
pub const __INTMAX_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INTMAX_WIDTH__ = @as(c_int, 64);
pub const __SIZE_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const __SIZE_WIDTH__ = @as(c_int, 64);
pub const __UINTMAX_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const __UINTMAX_WIDTH__ = @as(c_int, 64);
pub const __PTRDIFF_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __PTRDIFF_WIDTH__ = @as(c_int, 64);
pub const __INTPTR_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INTPTR_WIDTH__ = @as(c_int, 64);
pub const __UINTPTR_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const __UINTPTR_WIDTH__ = @as(c_int, 64);
pub const __SIZEOF_DOUBLE__ = @as(c_int, 8);
pub const __SIZEOF_FLOAT__ = @as(c_int, 4);
pub const __SIZEOF_INT__ = @as(c_int, 4);
pub const __SIZEOF_LONG__ = @as(c_int, 4);
pub const __SIZEOF_LONG_DOUBLE__ = @as(c_int, 16);
pub const __SIZEOF_LONG_LONG__ = @as(c_int, 8);
pub const __SIZEOF_POINTER__ = @as(c_int, 8);
pub const __SIZEOF_SHORT__ = @as(c_int, 2);
pub const __SIZEOF_PTRDIFF_T__ = @as(c_int, 8);
pub const __SIZEOF_SIZE_T__ = @as(c_int, 8);
pub const __SIZEOF_WCHAR_T__ = @as(c_int, 2);
pub const __SIZEOF_WINT_T__ = @as(c_int, 2);
pub const __SIZEOF_INT128__ = @as(c_int, 16);
pub const __INTMAX_TYPE__ = c_longlong;
pub const __INTMAX_FMTd__ = "lld";
pub const __INTMAX_FMTi__ = "lli";
pub const __INTMAX_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `LL`");
// (no file):94:9
pub const __UINTMAX_TYPE__ = c_ulonglong;
pub const __UINTMAX_FMTo__ = "llo";
pub const __UINTMAX_FMTu__ = "llu";
pub const __UINTMAX_FMTx__ = "llx";
pub const __UINTMAX_FMTX__ = "llX";
pub const __UINTMAX_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `ULL`");
// (no file):100:9
pub const __PTRDIFF_TYPE__ = c_longlong;
pub const __PTRDIFF_FMTd__ = "lld";
pub const __PTRDIFF_FMTi__ = "lli";
pub const __INTPTR_TYPE__ = c_longlong;
pub const __INTPTR_FMTd__ = "lld";
pub const __INTPTR_FMTi__ = "lli";
pub const __SIZE_TYPE__ = c_ulonglong;
pub const __SIZE_FMTo__ = "llo";
pub const __SIZE_FMTu__ = "llu";
pub const __SIZE_FMTx__ = "llx";
pub const __SIZE_FMTX__ = "llX";
pub const __WCHAR_TYPE__ = c_ushort;
pub const __WINT_TYPE__ = c_ushort;
pub const __SIG_ATOMIC_MAX__ = std.zig.c_translation.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __SIG_ATOMIC_WIDTH__ = @as(c_int, 32);
pub const __CHAR16_TYPE__ = c_ushort;
pub const __CHAR32_TYPE__ = c_uint;
pub const __UINTPTR_TYPE__ = c_ulonglong;
pub const __UINTPTR_FMTo__ = "llo";
pub const __UINTPTR_FMTu__ = "llu";
pub const __UINTPTR_FMTx__ = "llx";
pub const __UINTPTR_FMTX__ = "llX";
pub const __FLT16_DENORM_MIN__ = @as(f16, 5.9604644775390625e-8);
pub const __FLT16_HAS_DENORM__ = @as(c_int, 1);
pub const __FLT16_DIG__ = @as(c_int, 3);
pub const __FLT16_DECIMAL_DIG__ = @as(c_int, 5);
pub const __FLT16_EPSILON__ = @as(f16, 9.765625e-4);
pub const __FLT16_HAS_INFINITY__ = @as(c_int, 1);
pub const __FLT16_HAS_QUIET_NAN__ = @as(c_int, 1);
pub const __FLT16_MANT_DIG__ = @as(c_int, 11);
pub const __FLT16_MAX_10_EXP__ = @as(c_int, 4);
pub const __FLT16_MAX_EXP__ = @as(c_int, 16);
pub const __FLT16_MAX__ = @as(f16, 6.5504e+4);
pub const __FLT16_MIN_10_EXP__ = -@as(c_int, 4);
pub const __FLT16_MIN_EXP__ = -@as(c_int, 13);
pub const __FLT16_MIN__ = @as(f16, 6.103515625e-5);
pub const __FLT_DENORM_MIN__ = @as(f32, 1.40129846e-45);
pub const __FLT_HAS_DENORM__ = @as(c_int, 1);
pub const __FLT_DIG__ = @as(c_int, 6);
pub const __FLT_DECIMAL_DIG__ = @as(c_int, 9);
pub const __FLT_EPSILON__ = @as(f32, 1.19209290e-7);
pub const __FLT_HAS_INFINITY__ = @as(c_int, 1);
pub const __FLT_HAS_QUIET_NAN__ = @as(c_int, 1);
pub const __FLT_MANT_DIG__ = @as(c_int, 24);
pub const __FLT_MAX_10_EXP__ = @as(c_int, 38);
pub const __FLT_MAX_EXP__ = @as(c_int, 128);
pub const __FLT_MAX__ = @as(f32, 3.40282347e+38);
pub const __FLT_MIN_10_EXP__ = -@as(c_int, 37);
pub const __FLT_MIN_EXP__ = -@as(c_int, 125);
pub const __FLT_MIN__ = @as(f32, 1.17549435e-38);
pub const __DBL_DENORM_MIN__ = @as(f64, 4.9406564584124654e-324);
pub const __DBL_HAS_DENORM__ = @as(c_int, 1);
pub const __DBL_DIG__ = @as(c_int, 15);
pub const __DBL_DECIMAL_DIG__ = @as(c_int, 17);
pub const __DBL_EPSILON__ = @as(f64, 2.2204460492503131e-16);
pub const __DBL_HAS_INFINITY__ = @as(c_int, 1);
pub const __DBL_HAS_QUIET_NAN__ = @as(c_int, 1);
pub const __DBL_MANT_DIG__ = @as(c_int, 53);
pub const __DBL_MAX_10_EXP__ = @as(c_int, 308);
pub const __DBL_MAX_EXP__ = @as(c_int, 1024);
pub const __DBL_MAX__ = @as(f64, 1.7976931348623157e+308);
pub const __DBL_MIN_10_EXP__ = -@as(c_int, 307);
pub const __DBL_MIN_EXP__ = -@as(c_int, 1021);
pub const __DBL_MIN__ = @as(f64, 2.2250738585072014e-308);
pub const __LDBL_DENORM_MIN__ = @as(c_longdouble, 3.64519953188247460253e-4951);
pub const __LDBL_HAS_DENORM__ = @as(c_int, 1);
pub const __LDBL_DIG__ = @as(c_int, 18);
pub const __LDBL_DECIMAL_DIG__ = @as(c_int, 21);
pub const __LDBL_EPSILON__ = @as(c_longdouble, 1.08420217248550443401e-19);
pub const __LDBL_HAS_INFINITY__ = @as(c_int, 1);
pub const __LDBL_HAS_QUIET_NAN__ = @as(c_int, 1);
pub const __LDBL_MANT_DIG__ = @as(c_int, 64);
pub const __LDBL_MAX_10_EXP__ = @as(c_int, 4932);
pub const __LDBL_MAX_EXP__ = @as(c_int, 16384);
pub const __LDBL_MAX__ = @as(c_longdouble, 1.18973149535723176502e+4932);
pub const __LDBL_MIN_10_EXP__ = -@as(c_int, 4931);
pub const __LDBL_MIN_EXP__ = -@as(c_int, 16381);
pub const __LDBL_MIN__ = @as(c_longdouble, 3.36210314311209350626e-4932);
pub const __POINTER_WIDTH__ = @as(c_int, 64);
pub const __BIGGEST_ALIGNMENT__ = @as(c_int, 16);
pub const __WCHAR_UNSIGNED__ = @as(c_int, 1);
pub const __WINT_UNSIGNED__ = @as(c_int, 1);
pub const __INT8_TYPE__ = i8;
pub const __INT8_FMTd__ = "hhd";
pub const __INT8_FMTi__ = "hhi";
pub const __INT8_C_SUFFIX__ = "";
pub const __INT16_TYPE__ = c_short;
pub const __INT16_FMTd__ = "hd";
pub const __INT16_FMTi__ = "hi";
pub const __INT16_C_SUFFIX__ = "";
pub const __INT32_TYPE__ = c_int;
pub const __INT32_FMTd__ = "d";
pub const __INT32_FMTi__ = "i";
pub const __INT32_C_SUFFIX__ = "";
pub const __INT64_TYPE__ = c_longlong;
pub const __INT64_FMTd__ = "lld";
pub const __INT64_FMTi__ = "lli";
pub const __INT64_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `LL`");
// (no file):198:9
pub const __UINT8_TYPE__ = u8;
pub const __UINT8_FMTo__ = "hho";
pub const __UINT8_FMTu__ = "hhu";
pub const __UINT8_FMTx__ = "hhx";
pub const __UINT8_FMTX__ = "hhX";
pub const __UINT8_C_SUFFIX__ = "";
pub const __UINT8_MAX__ = @as(c_int, 255);
pub const __INT8_MAX__ = @as(c_int, 127);
pub const __UINT16_TYPE__ = c_ushort;
pub const __UINT16_FMTo__ = "ho";
pub const __UINT16_FMTu__ = "hu";
pub const __UINT16_FMTx__ = "hx";
pub const __UINT16_FMTX__ = "hX";
pub const __UINT16_C_SUFFIX__ = "";
pub const __UINT16_MAX__ = std.zig.c_translation.promoteIntLiteral(c_int, 65535, .decimal);
pub const __INT16_MAX__ = @as(c_int, 32767);
pub const __UINT32_TYPE__ = c_uint;
pub const __UINT32_FMTo__ = "o";
pub const __UINT32_FMTu__ = "u";
pub const __UINT32_FMTx__ = "x";
pub const __UINT32_FMTX__ = "X";
pub const __UINT32_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `U`");
// (no file):220:9
pub const __UINT32_MAX__ = std.zig.c_translation.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const __INT32_MAX__ = std.zig.c_translation.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __UINT64_TYPE__ = c_ulonglong;
pub const __UINT64_FMTo__ = "llo";
pub const __UINT64_FMTu__ = "llu";
pub const __UINT64_FMTx__ = "llx";
pub const __UINT64_FMTX__ = "llX";
pub const __UINT64_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `ULL`");
// (no file):228:9
pub const __UINT64_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const __INT64_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INT_LEAST8_TYPE__ = i8;
pub const __INT_LEAST8_MAX__ = @as(c_int, 127);
pub const __INT_LEAST8_WIDTH__ = @as(c_int, 8);
pub const __INT_LEAST8_FMTd__ = "hhd";
pub const __INT_LEAST8_FMTi__ = "hhi";
pub const __UINT_LEAST8_TYPE__ = u8;
pub const __UINT_LEAST8_MAX__ = @as(c_int, 255);
pub const __UINT_LEAST8_FMTo__ = "hho";
pub const __UINT_LEAST8_FMTu__ = "hhu";
pub const __UINT_LEAST8_FMTx__ = "hhx";
pub const __UINT_LEAST8_FMTX__ = "hhX";
pub const __INT_LEAST16_TYPE__ = c_short;
pub const __INT_LEAST16_MAX__ = @as(c_int, 32767);
pub const __INT_LEAST16_WIDTH__ = @as(c_int, 16);
pub const __INT_LEAST16_FMTd__ = "hd";
pub const __INT_LEAST16_FMTi__ = "hi";
pub const __UINT_LEAST16_TYPE__ = c_ushort;
pub const __UINT_LEAST16_MAX__ = std.zig.c_translation.promoteIntLiteral(c_int, 65535, .decimal);
pub const __UINT_LEAST16_FMTo__ = "ho";
pub const __UINT_LEAST16_FMTu__ = "hu";
pub const __UINT_LEAST16_FMTx__ = "hx";
pub const __UINT_LEAST16_FMTX__ = "hX";
pub const __INT_LEAST32_TYPE__ = c_int;
pub const __INT_LEAST32_MAX__ = std.zig.c_translation.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __INT_LEAST32_WIDTH__ = @as(c_int, 32);
pub const __INT_LEAST32_FMTd__ = "d";
pub const __INT_LEAST32_FMTi__ = "i";
pub const __UINT_LEAST32_TYPE__ = c_uint;
pub const __UINT_LEAST32_MAX__ = std.zig.c_translation.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const __UINT_LEAST32_FMTo__ = "o";
pub const __UINT_LEAST32_FMTu__ = "u";
pub const __UINT_LEAST32_FMTx__ = "x";
pub const __UINT_LEAST32_FMTX__ = "X";
pub const __INT_LEAST64_TYPE__ = c_longlong;
pub const __INT_LEAST64_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INT_LEAST64_WIDTH__ = @as(c_int, 64);
pub const __INT_LEAST64_FMTd__ = "lld";
pub const __INT_LEAST64_FMTi__ = "lli";
pub const __UINT_LEAST64_TYPE__ = c_ulonglong;
pub const __UINT_LEAST64_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const __UINT_LEAST64_FMTo__ = "llo";
pub const __UINT_LEAST64_FMTu__ = "llu";
pub const __UINT_LEAST64_FMTx__ = "llx";
pub const __UINT_LEAST64_FMTX__ = "llX";
pub const __INT_FAST8_TYPE__ = i8;
pub const __INT_FAST8_MAX__ = @as(c_int, 127);
pub const __INT_FAST8_WIDTH__ = @as(c_int, 8);
pub const __INT_FAST8_FMTd__ = "hhd";
pub const __INT_FAST8_FMTi__ = "hhi";
pub const __UINT_FAST8_TYPE__ = u8;
pub const __UINT_FAST8_MAX__ = @as(c_int, 255);
pub const __UINT_FAST8_FMTo__ = "hho";
pub const __UINT_FAST8_FMTu__ = "hhu";
pub const __UINT_FAST8_FMTx__ = "hhx";
pub const __UINT_FAST8_FMTX__ = "hhX";
pub const __INT_FAST16_TYPE__ = c_short;
pub const __INT_FAST16_MAX__ = @as(c_int, 32767);
pub const __INT_FAST16_WIDTH__ = @as(c_int, 16);
pub const __INT_FAST16_FMTd__ = "hd";
pub const __INT_FAST16_FMTi__ = "hi";
pub const __UINT_FAST16_TYPE__ = c_ushort;
pub const __UINT_FAST16_MAX__ = std.zig.c_translation.promoteIntLiteral(c_int, 65535, .decimal);
pub const __UINT_FAST16_FMTo__ = "ho";
pub const __UINT_FAST16_FMTu__ = "hu";
pub const __UINT_FAST16_FMTx__ = "hx";
pub const __UINT_FAST16_FMTX__ = "hX";
pub const __INT_FAST32_TYPE__ = c_int;
pub const __INT_FAST32_MAX__ = std.zig.c_translation.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __INT_FAST32_WIDTH__ = @as(c_int, 32);
pub const __INT_FAST32_FMTd__ = "d";
pub const __INT_FAST32_FMTi__ = "i";
pub const __UINT_FAST32_TYPE__ = c_uint;
pub const __UINT_FAST32_MAX__ = std.zig.c_translation.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const __UINT_FAST32_FMTo__ = "o";
pub const __UINT_FAST32_FMTu__ = "u";
pub const __UINT_FAST32_FMTx__ = "x";
pub const __UINT_FAST32_FMTX__ = "X";
pub const __INT_FAST64_TYPE__ = c_longlong;
pub const __INT_FAST64_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INT_FAST64_WIDTH__ = @as(c_int, 64);
pub const __INT_FAST64_FMTd__ = "lld";
pub const __INT_FAST64_FMTi__ = "lli";
pub const __UINT_FAST64_TYPE__ = c_ulonglong;
pub const __UINT_FAST64_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const __UINT_FAST64_FMTo__ = "llo";
pub const __UINT_FAST64_FMTu__ = "llu";
pub const __UINT_FAST64_FMTx__ = "llx";
pub const __UINT_FAST64_FMTX__ = "llX";
pub const __USER_LABEL_PREFIX__ = "";
pub const __FINITE_MATH_ONLY__ = @as(c_int, 0);
pub const __GNUC_STDC_INLINE__ = @as(c_int, 1);
pub const __GCC_ATOMIC_TEST_AND_SET_TRUEVAL = @as(c_int, 1);
pub const __CLANG_ATOMIC_BOOL_LOCK_FREE = @as(c_int, 2);
pub const __CLANG_ATOMIC_CHAR_LOCK_FREE = @as(c_int, 2);
pub const __CLANG_ATOMIC_CHAR16_T_LOCK_FREE = @as(c_int, 2);
pub const __CLANG_ATOMIC_CHAR32_T_LOCK_FREE = @as(c_int, 2);
pub const __CLANG_ATOMIC_WCHAR_T_LOCK_FREE = @as(c_int, 2);
pub const __CLANG_ATOMIC_SHORT_LOCK_FREE = @as(c_int, 2);
pub const __CLANG_ATOMIC_INT_LOCK_FREE = @as(c_int, 2);
pub const __CLANG_ATOMIC_LONG_LOCK_FREE = @as(c_int, 2);
pub const __CLANG_ATOMIC_LLONG_LOCK_FREE = @as(c_int, 2);
pub const __CLANG_ATOMIC_POINTER_LOCK_FREE = @as(c_int, 2);
pub const __GCC_ATOMIC_BOOL_LOCK_FREE = @as(c_int, 2);
pub const __GCC_ATOMIC_CHAR_LOCK_FREE = @as(c_int, 2);
pub const __GCC_ATOMIC_CHAR16_T_LOCK_FREE = @as(c_int, 2);
pub const __GCC_ATOMIC_CHAR32_T_LOCK_FREE = @as(c_int, 2);
pub const __GCC_ATOMIC_WCHAR_T_LOCK_FREE = @as(c_int, 2);
pub const __GCC_ATOMIC_SHORT_LOCK_FREE = @as(c_int, 2);
pub const __GCC_ATOMIC_INT_LOCK_FREE = @as(c_int, 2);
pub const __GCC_ATOMIC_LONG_LOCK_FREE = @as(c_int, 2);
pub const __GCC_ATOMIC_LLONG_LOCK_FREE = @as(c_int, 2);
pub const __GCC_ATOMIC_POINTER_LOCK_FREE = @as(c_int, 2);
pub const __NO_INLINE__ = @as(c_int, 1);
pub const __PIC__ = @as(c_int, 2);
pub const __pic__ = @as(c_int, 2);
pub const __FLT_RADIX__ = @as(c_int, 2);
pub const __DECIMAL_DIG__ = __LDBL_DECIMAL_DIG__;
pub const __GCC_ASM_FLAG_OUTPUTS__ = @as(c_int, 1);
pub const __code_model_small__ = @as(c_int, 1);
pub const __amd64__ = @as(c_int, 1);
pub const __amd64 = @as(c_int, 1);
pub const __x86_64 = @as(c_int, 1);
pub const __x86_64__ = @as(c_int, 1);
pub const __SEG_GS = @as(c_int, 1);
pub const __SEG_FS = @as(c_int, 1);
pub const __seg_gs = @compileError("unable to translate macro: undefined identifier `address_space`");
// (no file):356:9
pub const __seg_fs = @compileError("unable to translate macro: undefined identifier `address_space`");
// (no file):357:9
pub const __k8 = @as(c_int, 1);
pub const __k8__ = @as(c_int, 1);
pub const __tune_k8__ = @as(c_int, 1);
pub const __REGISTER_PREFIX__ = "";
pub const __NO_MATH_INLINES = @as(c_int, 1);
pub const __AES__ = @as(c_int, 1);
pub const __VAES__ = @as(c_int, 1);
pub const __PCLMUL__ = @as(c_int, 1);
pub const __VPCLMULQDQ__ = @as(c_int, 1);
pub const __LAHF_SAHF__ = @as(c_int, 1);
pub const __LZCNT__ = @as(c_int, 1);
pub const __RDRND__ = @as(c_int, 1);
pub const __FSGSBASE__ = @as(c_int, 1);
pub const __BMI__ = @as(c_int, 1);
pub const __BMI2__ = @as(c_int, 1);
pub const __POPCNT__ = @as(c_int, 1);
pub const __PRFCHW__ = @as(c_int, 1);
pub const __RDSEED__ = @as(c_int, 1);
pub const __ADX__ = @as(c_int, 1);
pub const __MOVBE__ = @as(c_int, 1);
pub const __FMA__ = @as(c_int, 1);
pub const __F16C__ = @as(c_int, 1);
pub const __GFNI__ = @as(c_int, 1);
pub const __SHA__ = @as(c_int, 1);
pub const __FXSR__ = @as(c_int, 1);
pub const __XSAVE__ = @as(c_int, 1);
pub const __XSAVEOPT__ = @as(c_int, 1);
pub const __XSAVEC__ = @as(c_int, 1);
pub const __XSAVES__ = @as(c_int, 1);
pub const __CLFLUSHOPT__ = @as(c_int, 1);
pub const __CLWB__ = @as(c_int, 1);
pub const __SHSTK__ = @as(c_int, 1);
pub const __RDPID__ = @as(c_int, 1);
pub const __WAITPKG__ = @as(c_int, 1);
pub const __MOVDIRI__ = @as(c_int, 1);
pub const __MOVDIR64B__ = @as(c_int, 1);
pub const __PTWRITE__ = @as(c_int, 1);
pub const __INVPCID__ = @as(c_int, 1);
pub const __AVX2__ = @as(c_int, 1);
pub const __AVX__ = @as(c_int, 1);
pub const __SSE4_2__ = @as(c_int, 1);
pub const __SSE4_1__ = @as(c_int, 1);
pub const __SSSE3__ = @as(c_int, 1);
pub const __SSE3__ = @as(c_int, 1);
pub const __SSE2__ = @as(c_int, 1);
pub const __SSE2_MATH__ = @as(c_int, 1);
pub const __SSE__ = @as(c_int, 1);
pub const __SSE_MATH__ = @as(c_int, 1);
pub const __MMX__ = @as(c_int, 1);
pub const __GCC_HAVE_SYNC_COMPARE_AND_SWAP_1 = @as(c_int, 1);
pub const __GCC_HAVE_SYNC_COMPARE_AND_SWAP_2 = @as(c_int, 1);
pub const __GCC_HAVE_SYNC_COMPARE_AND_SWAP_4 = @as(c_int, 1);
pub const __GCC_HAVE_SYNC_COMPARE_AND_SWAP_8 = @as(c_int, 1);
pub const __GCC_HAVE_SYNC_COMPARE_AND_SWAP_16 = @as(c_int, 1);
pub const __SIZEOF_FLOAT128__ = @as(c_int, 16);
pub const _WIN32 = @as(c_int, 1);
pub const _WIN64 = @as(c_int, 1);
pub const WIN32 = @as(c_int, 1);
pub const __WIN32 = @as(c_int, 1);
pub const __WIN32__ = @as(c_int, 1);
pub const WINNT = @as(c_int, 1);
pub const __WINNT = @as(c_int, 1);
pub const __WINNT__ = @as(c_int, 1);
pub const WIN64 = @as(c_int, 1);
pub const __WIN64 = @as(c_int, 1);
pub const __WIN64__ = @as(c_int, 1);
pub const __MINGW64__ = @as(c_int, 1);
pub const __MSVCRT__ = @as(c_int, 1);
pub const __MINGW32__ = @as(c_int, 1);
pub const __declspec = @compileError("unable to translate C expr: unexpected token '__attribute__'");
// (no file):427:9
pub const _cdecl = @compileError("unable to translate macro: undefined identifier `__cdecl__`");
// (no file):428:9
pub const __cdecl = @compileError("unable to translate macro: undefined identifier `__cdecl__`");
// (no file):429:9
pub const _stdcall = @compileError("unable to translate macro: undefined identifier `__stdcall__`");
// (no file):430:9
pub const __stdcall = @compileError("unable to translate macro: undefined identifier `__stdcall__`");
// (no file):431:9
pub const _fastcall = @compileError("unable to translate macro: undefined identifier `__fastcall__`");
// (no file):432:9
pub const __fastcall = @compileError("unable to translate macro: undefined identifier `__fastcall__`");
// (no file):433:9
pub const _thiscall = @compileError("unable to translate macro: undefined identifier `__thiscall__`");
// (no file):434:9
pub const __thiscall = @compileError("unable to translate macro: undefined identifier `__thiscall__`");
// (no file):435:9
pub const _pascal = @compileError("unable to translate macro: undefined identifier `__pascal__`");
// (no file):436:9
pub const __pascal = @compileError("unable to translate macro: undefined identifier `__pascal__`");
// (no file):437:9
pub const __STDC__ = @as(c_int, 1);
pub const __STDC_HOSTED__ = @as(c_int, 1);
pub const __STDC_VERSION__ = @as(c_long, 201710);
pub const __STDC_UTF_16__ = @as(c_int, 1);
pub const __STDC_UTF_32__ = @as(c_int, 1);
pub const _DEBUG = @as(c_int, 1);
pub const RABBITMQ_C_EXPORT_H = "";
pub const AMQP_EXPORT = @compileError("unable to translate macro: undefined identifier `dllimport`");
// ./export.h:15:15
pub const AMQP_NO_EXPORT = "";
pub const AMQP_DEPRECATED = @compileError("unable to translate macro: undefined identifier `deprecated`");
// ./export.h:25:11
pub const AMQP_DEPRECATED_EXPORT = AMQP_EXPORT ++ AMQP_DEPRECATED;
pub const AMQP_DEPRECATED_NO_EXPORT = AMQP_DEPRECATED;
pub const RABBITMQ_C_RABBITMQ_C_H = "";
pub const AMQP_BEGIN_DECLS = "";
pub const AMQP_END_DECLS = "";
pub const AMQP_CALL = __cdecl;
pub const _W64 = "";
pub const uint32_t = c_uint;
pub const int32_t = c_int;
pub const uint64_t = c_ulonglong;
pub const int64_t = c_longlong;
pub const uint16_t = c_ushort;
pub const uint8_t = @compileError("unable to translate: invalid numeric type");
// amqp.h:57:9
pub const int8_t = @compileError("unable to translate: invalid numeric type");
// amqp.h:58:9
pub const int16_t = c_short;
pub const __STDDEF_H = "";
pub const __need_ptrdiff_t = "";
pub const __need_size_t = "";
pub const __need_wchar_t = "";
pub const __need_NULL = "";
pub const __need_STDDEF_H_misc = "";
pub const _PTRDIFF_T = "";
pub const _SIZE_T = "";
pub const _WCHAR_T = "";
pub const NULL = std.zig.c_translation.cast(?*anyopaque, @as(c_int, 0));
pub const __CLANG_MAX_ALIGN_T_DEFINED = "";
pub const offsetof = @compileError("unable to translate C expr: unexpected token 'an identifier'");
// E:/HardLinks/Microsoft Visual Studio/2022/Professional/VC/Tools/Llvm/x64/lib/clang/17/include/stddef.h:116:9
pub const __CLANG_STDINT_H = "";
pub const AMQP_VERSION_MAJOR = @as(c_int, 0);
pub const AMQP_VERSION_MINOR = @as(c_int, 15);
pub const AMQP_VERSION_PATCH = @as(c_int, 0);
pub const AMQP_VERSION_IS_RELEASE = @as(c_int, 1);
pub inline fn AMQP_VERSION_CODE(major: anytype, minor: anytype, patch: anytype, release: anytype) @TypeOf((((major << @as(c_int, 24)) | (minor << @as(c_int, 16))) | (patch << @as(c_int, 8))) | release) {
    _ = &major;
    _ = &minor;
    _ = &patch;
    _ = &release;
    return (((major << @as(c_int, 24)) | (minor << @as(c_int, 16))) | (patch << @as(c_int, 8))) | release;
}
pub const AMQP_VERSION = AMQP_VERSION_CODE(AMQP_VERSION_MAJOR, AMQP_VERSION_MINOR, AMQP_VERSION_PATCH, AMQP_VERSION_IS_RELEASE);
pub inline fn AMQ_STRINGIFY(s: anytype) @TypeOf(AMQ_STRINGIFY_HELPER(s)) {
    _ = &s;
    return AMQ_STRINGIFY_HELPER(s);
}
pub const AMQ_STRINGIFY_HELPER = @compileError("unable to translate C expr: unexpected token '#'");
// amqp.h:170:9
pub const AMQ_VERSION_STRING = AMQ_STRINGIFY(AMQP_VERSION_MAJOR) ++ "." ++ AMQ_STRINGIFY(AMQP_VERSION_MINOR) ++ "." ++ AMQ_STRINGIFY(AMQP_VERSION_PATCH);
pub const AMQP_VERSION_STRING = AMQ_VERSION_STRING;
pub const AMQP_DEFAULT_FRAME_SIZE = std.zig.c_translation.promoteIntLiteral(c_int, 131072, .decimal);
pub const AMQP_DEFAULT_MAX_CHANNELS = @as(c_int, 2047);
pub const AMQP_DEFAULT_HEARTBEAT = @as(c_int, 0);
pub const AMQP_DEFAULT_VHOST = "/";
pub const RABBITMQ_C_FRAMING_H = "";
pub const AMQP_PROTOCOL_VERSION_MAJOR = @as(c_int, 0);
pub const AMQP_PROTOCOL_VERSION_MINOR = @as(c_int, 9);
pub const AMQP_PROTOCOL_VERSION_REVISION = @as(c_int, 1);
pub const AMQP_PROTOCOL_PORT = @as(c_int, 5672);
pub const AMQP_FRAME_METHOD = @as(c_int, 1);
pub const AMQP_FRAME_HEADER = @as(c_int, 2);
pub const AMQP_FRAME_BODY = @as(c_int, 3);
pub const AMQP_FRAME_HEARTBEAT = @as(c_int, 8);
pub const AMQP_FRAME_MIN_SIZE = @as(c_int, 4096);
pub const AMQP_FRAME_END = @as(c_int, 206);
pub const AMQP_REPLY_SUCCESS = @as(c_int, 200);
pub const AMQP_CONTENT_TOO_LARGE = @as(c_int, 311);
pub const AMQP_NO_ROUTE = @as(c_int, 312);
pub const AMQP_NO_CONSUMERS = @as(c_int, 313);
pub const AMQP_ACCESS_REFUSED = @as(c_int, 403);
pub const AMQP_NOT_FOUND = @as(c_int, 404);
pub const AMQP_RESOURCE_LOCKED = @as(c_int, 405);
pub const AMQP_PRECONDITION_FAILED = @as(c_int, 406);
pub const AMQP_CONNECTION_FORCED = @as(c_int, 320);
pub const AMQP_INVALID_PATH = @as(c_int, 402);
pub const AMQP_FRAME_ERROR = @as(c_int, 501);
pub const AMQP_SYNTAX_ERROR = @as(c_int, 502);
pub const AMQP_COMMAND_INVALID = @as(c_int, 503);
pub const AMQP_CHANNEL_ERROR = @as(c_int, 504);
pub const AMQP_UNEXPECTED_FRAME = @as(c_int, 505);
pub const AMQP_RESOURCE_ERROR = @as(c_int, 506);
pub const AMQP_NOT_ALLOWED = @as(c_int, 530);
pub const AMQP_NOT_IMPLEMENTED = @as(c_int, 540);
pub const AMQP_INTERNAL_ERROR = @as(c_int, 541);
pub const AMQP_CONNECTION_START_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x000A000A, .hex));
pub const AMQP_CONNECTION_START_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x000A000B, .hex));
pub const AMQP_CONNECTION_SECURE_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x000A0014, .hex));
pub const AMQP_CONNECTION_SECURE_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x000A0015, .hex));
pub const AMQP_CONNECTION_TUNE_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x000A001E, .hex));
pub const AMQP_CONNECTION_TUNE_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x000A001F, .hex));
pub const AMQP_CONNECTION_OPEN_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x000A0028, .hex));
pub const AMQP_CONNECTION_OPEN_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x000A0029, .hex));
pub const AMQP_CONNECTION_CLOSE_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x000A0032, .hex));
pub const AMQP_CONNECTION_CLOSE_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x000A0033, .hex));
pub const AMQP_CONNECTION_BLOCKED_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x000A003C, .hex));
pub const AMQP_CONNECTION_UNBLOCKED_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x000A003D, .hex));
pub const AMQP_CONNECTION_UPDATE_SECRET_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x000A0046, .hex));
pub const AMQP_CONNECTION_UPDATE_SECRET_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x000A0047, .hex));
pub const AMQP_CHANNEL_OPEN_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x0014000A, .hex));
pub const AMQP_CHANNEL_OPEN_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x0014000B, .hex));
pub const AMQP_CHANNEL_FLOW_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x00140014, .hex));
pub const AMQP_CHANNEL_FLOW_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x00140015, .hex));
pub const AMQP_CHANNEL_CLOSE_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x00140028, .hex));
pub const AMQP_CHANNEL_CLOSE_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x00140029, .hex));
pub const AMQP_ACCESS_REQUEST_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x001E000A, .hex));
pub const AMQP_ACCESS_REQUEST_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x001E000B, .hex));
pub const AMQP_EXCHANGE_DECLARE_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x0028000A, .hex));
pub const AMQP_EXCHANGE_DECLARE_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x0028000B, .hex));
pub const AMQP_EXCHANGE_DELETE_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x00280014, .hex));
pub const AMQP_EXCHANGE_DELETE_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x00280015, .hex));
pub const AMQP_EXCHANGE_BIND_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x0028001E, .hex));
pub const AMQP_EXCHANGE_BIND_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x0028001F, .hex));
pub const AMQP_EXCHANGE_UNBIND_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x00280028, .hex));
pub const AMQP_EXCHANGE_UNBIND_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x00280033, .hex));
pub const AMQP_QUEUE_DECLARE_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x0032000A, .hex));
pub const AMQP_QUEUE_DECLARE_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x0032000B, .hex));
pub const AMQP_QUEUE_BIND_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x00320014, .hex));
pub const AMQP_QUEUE_BIND_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x00320015, .hex));
pub const AMQP_QUEUE_PURGE_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x0032001E, .hex));
pub const AMQP_QUEUE_PURGE_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x0032001F, .hex));
pub const AMQP_QUEUE_DELETE_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x00320028, .hex));
pub const AMQP_QUEUE_DELETE_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x00320029, .hex));
pub const AMQP_QUEUE_UNBIND_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x00320032, .hex));
pub const AMQP_QUEUE_UNBIND_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x00320033, .hex));
pub const AMQP_BASIC_QOS_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x003C000A, .hex));
pub const AMQP_BASIC_QOS_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x003C000B, .hex));
pub const AMQP_BASIC_CONSUME_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x003C0014, .hex));
pub const AMQP_BASIC_CONSUME_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x003C0015, .hex));
pub const AMQP_BASIC_CANCEL_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x003C001E, .hex));
pub const AMQP_BASIC_CANCEL_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x003C001F, .hex));
pub const AMQP_BASIC_PUBLISH_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x003C0028, .hex));
pub const AMQP_BASIC_RETURN_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x003C0032, .hex));
pub const AMQP_BASIC_DELIVER_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x003C003C, .hex));
pub const AMQP_BASIC_GET_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x003C0046, .hex));
pub const AMQP_BASIC_GET_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x003C0047, .hex));
pub const AMQP_BASIC_GET_EMPTY_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x003C0048, .hex));
pub const AMQP_BASIC_ACK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x003C0050, .hex));
pub const AMQP_BASIC_REJECT_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x003C005A, .hex));
pub const AMQP_BASIC_RECOVER_ASYNC_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x003C0064, .hex));
pub const AMQP_BASIC_RECOVER_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x003C006E, .hex));
pub const AMQP_BASIC_RECOVER_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x003C006F, .hex));
pub const AMQP_BASIC_NACK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x003C0078, .hex));
pub const AMQP_TX_SELECT_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x005A000A, .hex));
pub const AMQP_TX_SELECT_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x005A000B, .hex));
pub const AMQP_TX_COMMIT_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x005A0014, .hex));
pub const AMQP_TX_COMMIT_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x005A0015, .hex));
pub const AMQP_TX_ROLLBACK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x005A001E, .hex));
pub const AMQP_TX_ROLLBACK_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x005A001F, .hex));
pub const AMQP_CONFIRM_SELECT_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x0055000A, .hex));
pub const AMQP_CONFIRM_SELECT_OK_METHOD = std.zig.c_translation.cast(amqp_method_number_t, std.zig.c_translation.promoteIntLiteral(c_int, 0x0055000B, .hex));
pub const AMQP_CONNECTION_CLASS = @as(c_int, 0x000A);
pub const AMQP_CHANNEL_CLASS = @as(c_int, 0x0014);
pub const AMQP_ACCESS_CLASS = @as(c_int, 0x001E);
pub const AMQP_EXCHANGE_CLASS = @as(c_int, 0x0028);
pub const AMQP_QUEUE_CLASS = @as(c_int, 0x0032);
pub const AMQP_BASIC_CLASS = @as(c_int, 0x003C);
pub const AMQP_BASIC_CONTENT_TYPE_FLAG = @as(c_int, 1) << @as(c_int, 15);
pub const AMQP_BASIC_CONTENT_ENCODING_FLAG = @as(c_int, 1) << @as(c_int, 14);
pub const AMQP_BASIC_HEADERS_FLAG = @as(c_int, 1) << @as(c_int, 13);
pub const AMQP_BASIC_DELIVERY_MODE_FLAG = @as(c_int, 1) << @as(c_int, 12);
pub const AMQP_BASIC_PRIORITY_FLAG = @as(c_int, 1) << @as(c_int, 11);
pub const AMQP_BASIC_CORRELATION_ID_FLAG = @as(c_int, 1) << @as(c_int, 10);
pub const AMQP_BASIC_REPLY_TO_FLAG = @as(c_int, 1) << @as(c_int, 9);
pub const AMQP_BASIC_EXPIRATION_FLAG = @as(c_int, 1) << @as(c_int, 8);
pub const AMQP_BASIC_MESSAGE_ID_FLAG = @as(c_int, 1) << @as(c_int, 7);
pub const AMQP_BASIC_TIMESTAMP_FLAG = @as(c_int, 1) << @as(c_int, 6);
pub const AMQP_BASIC_TYPE_FLAG = @as(c_int, 1) << @as(c_int, 5);
pub const AMQP_BASIC_USER_ID_FLAG = @as(c_int, 1) << @as(c_int, 4);
pub const AMQP_BASIC_APP_ID_FLAG = @as(c_int, 1) << @as(c_int, 3);
pub const AMQP_BASIC_CLUSTER_ID_FLAG = @as(c_int, 1) << @as(c_int, 2);
pub const AMQP_TX_CLASS = @as(c_int, 0x005A);
pub const AMQP_CONFIRM_CLASS = @as(c_int, 0x0055);
pub const AMQP_EMPTY_BYTES = amqp_empty_bytes;
pub const AMQP_EMPTY_TABLE = amqp_empty_table;
pub const AMQP_EMPTY_ARRAY = amqp_empty_array;
pub inline fn amqp_literal_bytes(str: anytype) amqp_bytes_t {
    _ = &str;
    return std.mem.zeroInit(amqp_bytes_t, .{ std.zig.c_translation.sizeof(str) - @as(c_int, 1), str });
}
pub const timeval = struct_timeval;
pub const amqp_bytes_t_ = struct_amqp_bytes_t_;
pub const amqp_decimal_t_ = struct_amqp_decimal_t_;
pub const amqp_array_t_ = struct_amqp_array_t_;
pub const amqp_field_value_t_ = struct_amqp_field_value_t_;
pub const amqp_table_entry_t_ = struct_amqp_table_entry_t_;
pub const amqp_table_t_ = struct_amqp_table_t_;
pub const amqp_pool_blocklist_t_ = struct_amqp_pool_blocklist_t_;
pub const amqp_pool_t_ = struct_amqp_pool_t_;
pub const amqp_method_t_ = struct_amqp_method_t_;
pub const amqp_frame_t_ = struct_amqp_frame_t_;
pub const amqp_response_type_enum_ = enum_amqp_response_type_enum_;
pub const amqp_rpc_reply_t_ = struct_amqp_rpc_reply_t_;
pub const amqp_sasl_method_enum_ = enum_amqp_sasl_method_enum_;
pub const amqp_connection_state_t_ = struct_amqp_connection_state_t_;
pub const amqp_socket_t_ = struct_amqp_socket_t_;
pub const amqp_status_enum_ = enum_amqp_status_enum_;
pub const amqp_connection_start_t_ = struct_amqp_connection_start_t_;
pub const amqp_connection_start_ok_t_ = struct_amqp_connection_start_ok_t_;
pub const amqp_connection_secure_t_ = struct_amqp_connection_secure_t_;
pub const amqp_connection_secure_ok_t_ = struct_amqp_connection_secure_ok_t_;
pub const amqp_connection_tune_t_ = struct_amqp_connection_tune_t_;
pub const amqp_connection_tune_ok_t_ = struct_amqp_connection_tune_ok_t_;
pub const amqp_connection_open_t_ = struct_amqp_connection_open_t_;
pub const amqp_connection_open_ok_t_ = struct_amqp_connection_open_ok_t_;
pub const amqp_connection_close_t_ = struct_amqp_connection_close_t_;
pub const amqp_connection_close_ok_t_ = struct_amqp_connection_close_ok_t_;
pub const amqp_connection_blocked_t_ = struct_amqp_connection_blocked_t_;
pub const amqp_connection_unblocked_t_ = struct_amqp_connection_unblocked_t_;
pub const amqp_connection_update_secret_t_ = struct_amqp_connection_update_secret_t_;
pub const amqp_connection_update_secret_ok_t_ = struct_amqp_connection_update_secret_ok_t_;
pub const amqp_channel_open_t_ = struct_amqp_channel_open_t_;
pub const amqp_channel_open_ok_t_ = struct_amqp_channel_open_ok_t_;
pub const amqp_channel_flow_t_ = struct_amqp_channel_flow_t_;
pub const amqp_channel_flow_ok_t_ = struct_amqp_channel_flow_ok_t_;
pub const amqp_channel_close_t_ = struct_amqp_channel_close_t_;
pub const amqp_channel_close_ok_t_ = struct_amqp_channel_close_ok_t_;
pub const amqp_access_request_t_ = struct_amqp_access_request_t_;
pub const amqp_access_request_ok_t_ = struct_amqp_access_request_ok_t_;
pub const amqp_exchange_declare_t_ = struct_amqp_exchange_declare_t_;
pub const amqp_exchange_declare_ok_t_ = struct_amqp_exchange_declare_ok_t_;
pub const amqp_exchange_delete_t_ = struct_amqp_exchange_delete_t_;
pub const amqp_exchange_delete_ok_t_ = struct_amqp_exchange_delete_ok_t_;
pub const amqp_exchange_bind_t_ = struct_amqp_exchange_bind_t_;
pub const amqp_exchange_bind_ok_t_ = struct_amqp_exchange_bind_ok_t_;
pub const amqp_exchange_unbind_t_ = struct_amqp_exchange_unbind_t_;
pub const amqp_exchange_unbind_ok_t_ = struct_amqp_exchange_unbind_ok_t_;
pub const amqp_queue_declare_t_ = struct_amqp_queue_declare_t_;
pub const amqp_queue_declare_ok_t_ = struct_amqp_queue_declare_ok_t_;
pub const amqp_queue_bind_t_ = struct_amqp_queue_bind_t_;
pub const amqp_queue_bind_ok_t_ = struct_amqp_queue_bind_ok_t_;
pub const amqp_queue_purge_t_ = struct_amqp_queue_purge_t_;
pub const amqp_queue_purge_ok_t_ = struct_amqp_queue_purge_ok_t_;
pub const amqp_queue_delete_t_ = struct_amqp_queue_delete_t_;
pub const amqp_queue_delete_ok_t_ = struct_amqp_queue_delete_ok_t_;
pub const amqp_queue_unbind_t_ = struct_amqp_queue_unbind_t_;
pub const amqp_queue_unbind_ok_t_ = struct_amqp_queue_unbind_ok_t_;
pub const amqp_basic_qos_t_ = struct_amqp_basic_qos_t_;
pub const amqp_basic_qos_ok_t_ = struct_amqp_basic_qos_ok_t_;
pub const amqp_basic_consume_t_ = struct_amqp_basic_consume_t_;
pub const amqp_basic_consume_ok_t_ = struct_amqp_basic_consume_ok_t_;
pub const amqp_basic_cancel_t_ = struct_amqp_basic_cancel_t_;
pub const amqp_basic_cancel_ok_t_ = struct_amqp_basic_cancel_ok_t_;
pub const amqp_basic_publish_t_ = struct_amqp_basic_publish_t_;
pub const amqp_basic_return_t_ = struct_amqp_basic_return_t_;
pub const amqp_basic_deliver_t_ = struct_amqp_basic_deliver_t_;
pub const amqp_basic_get_t_ = struct_amqp_basic_get_t_;
pub const amqp_basic_get_ok_t_ = struct_amqp_basic_get_ok_t_;
pub const amqp_basic_get_empty_t_ = struct_amqp_basic_get_empty_t_;
pub const amqp_basic_ack_t_ = struct_amqp_basic_ack_t_;
pub const amqp_basic_reject_t_ = struct_amqp_basic_reject_t_;
pub const amqp_basic_recover_async_t_ = struct_amqp_basic_recover_async_t_;
pub const amqp_basic_recover_t_ = struct_amqp_basic_recover_t_;
pub const amqp_basic_recover_ok_t_ = struct_amqp_basic_recover_ok_t_;
pub const amqp_basic_nack_t_ = struct_amqp_basic_nack_t_;
pub const amqp_tx_select_t_ = struct_amqp_tx_select_t_;
pub const amqp_tx_select_ok_t_ = struct_amqp_tx_select_ok_t_;
pub const amqp_tx_commit_t_ = struct_amqp_tx_commit_t_;
pub const amqp_tx_commit_ok_t_ = struct_amqp_tx_commit_ok_t_;
pub const amqp_tx_rollback_t_ = struct_amqp_tx_rollback_t_;
pub const amqp_tx_rollback_ok_t_ = struct_amqp_tx_rollback_ok_t_;
pub const amqp_confirm_select_t_ = struct_amqp_confirm_select_t_;
pub const amqp_confirm_select_ok_t_ = struct_amqp_confirm_select_ok_t_;
pub const amqp_connection_properties_t_ = struct_amqp_connection_properties_t_;
pub const amqp_channel_properties_t_ = struct_amqp_channel_properties_t_;
pub const amqp_access_properties_t_ = struct_amqp_access_properties_t_;
pub const amqp_exchange_properties_t_ = struct_amqp_exchange_properties_t_;
pub const amqp_queue_properties_t_ = struct_amqp_queue_properties_t_;
pub const amqp_basic_properties_t_ = struct_amqp_basic_properties_t_;
pub const amqp_tx_properties_t_ = struct_amqp_tx_properties_t_;
pub const amqp_confirm_properties_t_ = struct_amqp_confirm_properties_t_;
pub const amqp_message_t_ = struct_amqp_message_t_;
pub const amqp_envelope_t_ = struct_amqp_envelope_t_;
pub const amqp_connection_info = struct_amqp_connection_info;
pub const amqp_publisher_confirm_payload_t_ = union_amqp_publisher_confirm_payload_t_;
pub const amqp_publisher_confirm_t_ = struct_amqp_publisher_confirm_t_;
