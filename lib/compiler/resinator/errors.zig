const std = @import("std");
const assert = std.debug.assert;
const Token = @import("lex.zig").Token;
const SourceMappings = @import("source_mapping.zig").SourceMappings;
const utils = @import("utils.zig");
const rc = @import("rc.zig");
const res = @import("res.zig");
const ico = @import("ico.zig");
const bmp = @import("bmp.zig");
const parse = @import("parse.zig");
const lang = @import("lang.zig");
const code_pages = @import("code_pages.zig");
const SupportedCodePage = code_pages.SupportedCodePage;
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

pub const Diagnostics = struct {
    errors: std.ArrayListUnmanaged(ErrorDetails) = .empty,
    /// Append-only, cannot handle removing strings.
    /// Expects to own all strings within the list.
    strings: std.ArrayListUnmanaged([]const u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Diagnostics {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Diagnostics) void {
        self.errors.deinit(self.allocator);
        for (self.strings.items) |str| {
            self.allocator.free(str);
        }
        self.strings.deinit(self.allocator);
    }

    pub fn append(self: *Diagnostics, error_details: ErrorDetails) !void {
        try self.errors.append(self.allocator, error_details);
    }

    const SmallestStringIndexType = std.meta.Int(.unsigned, @min(
        @bitSizeOf(ErrorDetails.FileOpenError.FilenameStringIndex),
        @min(
            @bitSizeOf(ErrorDetails.IconReadError.FilenameStringIndex),
            @bitSizeOf(ErrorDetails.BitmapReadError.FilenameStringIndex),
        ),
    ));

    /// Returns the index of the added string as the SmallestStringIndexType
    /// in order to avoid needing to `@intCast` it at callsites of putString.
    /// Instead, this function will error if the index would ever exceed the
    /// smallest FilenameStringIndex of an ErrorDetails type.
    pub fn putString(self: *Diagnostics, str: []const u8) !SmallestStringIndexType {
        if (self.strings.items.len >= std.math.maxInt(SmallestStringIndexType)) {
            return error.OutOfMemory; // ran out of string indexes
        }
        const dupe = try self.allocator.dupe(u8, str);
        const index = self.strings.items.len;
        try self.strings.append(self.allocator, dupe);
        return @intCast(index);
    }

    pub fn renderToStdErr(self: *Diagnostics, cwd: std.fs.Dir, source: []const u8, tty_config: std.io.tty.Config, source_mappings: ?SourceMappings) void {
        const stderr = std.debug.lockStderrWriter(&.{});
        defer std.debug.unlockStderrWriter();
        for (self.errors.items) |err_details| {
            renderErrorMessage(stderr, tty_config, cwd, err_details, source, self.strings.items, source_mappings) catch return;
        }
    }

    pub fn renderToStdErrDetectTTY(self: *Diagnostics, cwd: std.fs.Dir, source: []const u8, source_mappings: ?SourceMappings) void {
        const tty_config = std.io.tty.detectConfig(std.fs.File.stderr());
        return self.renderToStdErr(cwd, source, tty_config, source_mappings);
    }

    pub fn contains(self: *const Diagnostics, err: ErrorDetails.Error) bool {
        for (self.errors.items) |details| {
            if (details.err == err) return true;
        }
        return false;
    }

    pub fn containsAny(self: *const Diagnostics, errors: []const ErrorDetails.Error) bool {
        for (self.errors.items) |details| {
            for (errors) |err| {
                if (details.err == err) return true;
            }
        }
        return false;
    }
};

/// Contains enough context to append errors/warnings/notes etc
pub const DiagnosticsContext = struct {
    diagnostics: *Diagnostics,
    token: Token,
    /// Code page of the source file at the token location
    code_page: SupportedCodePage,
};

pub const ErrorDetails = struct {
    err: Error,
    token: Token,
    /// Code page of the source file at the token location
    code_page: SupportedCodePage,
    /// If non-null, should be before `token`. If null, `token` is assumed to be the start.
    token_span_start: ?Token = null,
    /// If non-null, should be after `token`. If null, `token` is assumed to be the end.
    token_span_end: ?Token = null,
    type: Type = .err,
    print_source_line: bool = true,
    extra: Extra = .{ .none = {} },

    pub const Type = enum {
        /// Fatal error, stops compilation
        err,
        /// Warning that does not affect compilation result
        warning,
        /// A note that typically provides further context for a warning/error
        note,
        /// An invisible diagnostic that is not printed to stderr but can
        /// provide information useful when comparing the behavior of different
        /// implementations. For example, a hint is emitted when a FONTDIR resource
        /// was included in the .RES file which is significant because rc.exe
        /// does something different than us, but ultimately it's not important
        /// enough to be a warning/note.
        hint,
    };

    pub const Extra = union {
        none: void,
        expected: Token.Id,
        number: u32,
        expected_types: ExpectedTypes,
        resource: rc.ResourceType,
        string_and_language: StringAndLanguage,
        file_open_error: FileOpenError,
        icon_read_error: IconReadError,
        icon_dir: IconDirContext,
        bmp_read_error: BitmapReadError,
        accelerator_error: AcceleratorError,
        statement_with_u16_param: StatementWithU16Param,
        menu_or_class: enum { class, menu },
    };

    comptime {
        // all fields in the extra union should be 32 bits or less
        for (std.meta.fields(Extra)) |field| {
            std.debug.assert(@bitSizeOf(field.type) <= 32);
        }
    }

    pub const StatementWithU16Param = enum(u32) {
        fileversion,
        productversion,
        language,
    };

    pub const StringAndLanguage = packed struct(u32) {
        id: u16,
        language: res.Language,
    };

    pub const FileOpenError = packed struct(u32) {
        err: FileOpenErrorEnum,
        filename_string_index: FilenameStringIndex,

        pub const FilenameStringIndex = std.meta.Int(.unsigned, 32 - @bitSizeOf(FileOpenErrorEnum));
        pub const FileOpenErrorEnum = std.meta.FieldEnum(std.fs.File.OpenError);

        pub fn enumFromError(err: std.fs.File.OpenError) FileOpenErrorEnum {
            return switch (err) {
                inline else => |e| @field(ErrorDetails.FileOpenError.FileOpenErrorEnum, @errorName(e)),
            };
        }
    };

    pub const IconReadError = packed struct(u32) {
        err: IconReadErrorEnum,
        icon_type: enum(u1) { cursor, icon },
        filename_string_index: FilenameStringIndex,

        pub const FilenameStringIndex = std.meta.Int(.unsigned, 32 - @bitSizeOf(IconReadErrorEnum) - 1);
        pub const IconReadErrorEnum = std.meta.FieldEnum(ico.ReadError);

        pub fn enumFromError(err: ico.ReadError) IconReadErrorEnum {
            return switch (err) {
                inline else => |e| @field(ErrorDetails.IconReadError.IconReadErrorEnum, @errorName(e)),
            };
        }
    };

    pub const IconDirContext = packed struct(u32) {
        icon_type: enum(u1) { cursor, icon },
        icon_format: ico.ImageFormat,
        index: u16,
        bitmap_version: ico.BitmapHeader.Version = .unknown,
        _: Padding = 0,

        pub const Padding = std.meta.Int(.unsigned, 15 - @bitSizeOf(ico.BitmapHeader.Version) - @bitSizeOf(ico.ImageFormat));
    };

    pub const BitmapReadError = packed struct(u32) {
        err: BitmapReadErrorEnum,
        filename_string_index: FilenameStringIndex,

        pub const FilenameStringIndex = std.meta.Int(.unsigned, 32 - @bitSizeOf(BitmapReadErrorEnum));
        pub const BitmapReadErrorEnum = std.meta.FieldEnum(bmp.ReadError);

        pub fn enumFromError(err: bmp.ReadError) BitmapReadErrorEnum {
            return switch (err) {
                inline else => |e| @field(ErrorDetails.BitmapReadError.BitmapReadErrorEnum, @errorName(e)),
            };
        }
    };

    pub const BitmapUnsupportedDIB = packed struct(u32) {
        dib_version: ico.BitmapHeader.Version,
        filename_string_index: FilenameStringIndex,

        pub const FilenameStringIndex = std.meta.Int(.unsigned, 32 - @bitSizeOf(ico.BitmapHeader.Version));
    };

    pub const AcceleratorError = packed struct(u32) {
        err: AcceleratorErrorEnum,
        _: Padding = 0,

        pub const Padding = std.meta.Int(.unsigned, 32 - @bitSizeOf(AcceleratorErrorEnum));
        pub const AcceleratorErrorEnum = std.meta.FieldEnum(res.ParseAcceleratorKeyStringError);

        pub fn enumFromError(err: res.ParseAcceleratorKeyStringError) AcceleratorErrorEnum {
            return switch (err) {
                inline else => |e| @field(ErrorDetails.AcceleratorError.AcceleratorErrorEnum, @errorName(e)),
            };
        }
    };

    pub const ExpectedTypes = packed struct(u32) {
        number: bool = false,
        number_expression: bool = false,
        string_literal: bool = false,
        accelerator_type_or_option: bool = false,
        control_class: bool = false,
        literal: bool = false,
        // Note: This being 0 instead of undefined is arbitrary and something of a workaround,
        //       see https://github.com/ziglang/zig/issues/15395
        _: u26 = 0,

        pub const strings = std.StaticStringMap([]const u8).initComptime(.{
            .{ "number", "number" },
            .{ "number_expression", "number expression" },
            .{ "string_literal", "quoted string literal" },
            .{ "accelerator_type_or_option", "accelerator type or option [ASCII, VIRTKEY, etc]" },
            .{ "control_class", "control class [BUTTON, EDIT, etc]" },
            .{ "literal", "unquoted literal" },
        });

        pub fn writeCommaSeparated(self: ExpectedTypes, writer: anytype) !void {
            const struct_info = @typeInfo(ExpectedTypes).@"struct";
            const num_real_fields = struct_info.fields.len - 1;
            const num_padding_bits = @bitSizeOf(ExpectedTypes) - num_real_fields;
            const mask = std.math.maxInt(struct_info.backing_integer.?) >> num_padding_bits;
            const relevant_bits_only = @as(struct_info.backing_integer.?, @bitCast(self)) & mask;
            const num_set_bits = @popCount(relevant_bits_only);

            var i: usize = 0;
            inline for (struct_info.fields) |field_info| {
                if (field_info.type != bool) continue;
                if (i == num_set_bits) return;
                if (@field(self, field_info.name)) {
                    try writer.writeAll(strings.get(field_info.name).?);
                    i += 1;
                    if (num_set_bits > 2 and i != num_set_bits) {
                        try writer.writeAll(", ");
                    } else if (i != num_set_bits) {
                        try writer.writeByte(' ');
                    }
                    if (num_set_bits > 1 and i == num_set_bits - 1) {
                        try writer.writeAll("or ");
                    }
                }
            }
        }
    };

    pub const Error = enum {
        // Lexer
        unfinished_string_literal,
        string_literal_too_long,
        invalid_number_with_exponent,
        invalid_digit_character_in_number_literal,
        illegal_byte,
        illegal_byte_outside_string_literals,
        illegal_codepoint_outside_string_literals,
        illegal_byte_order_mark,
        illegal_private_use_character,
        found_c_style_escaped_quote,
        code_page_pragma_missing_left_paren,
        code_page_pragma_missing_right_paren,
        code_page_pragma_invalid_code_page,
        code_page_pragma_not_integer,
        code_page_pragma_overflow,
        code_page_pragma_unsupported_code_page,

        // Parser
        unfinished_raw_data_block,
        unfinished_string_table_block,
        /// `expected` is populated.
        expected_token,
        /// `expected_types` is populated
        expected_something_else,
        /// `resource` is populated
        resource_type_cant_use_raw_data,
        /// `resource` is populated
        id_must_be_ordinal,
        /// `resource` is populated
        name_or_id_not_allowed,
        string_resource_as_numeric_type,
        ascii_character_not_equivalent_to_virtual_key_code,
        empty_menu_not_allowed,
        rc_would_miscompile_version_value_padding,
        rc_would_miscompile_version_value_byte_count,
        code_page_pragma_in_included_file,
        nested_resource_level_exceeds_max,
        too_many_dialog_controls_or_toolbar_buttons,
        nested_expression_level_exceeds_max,
        close_paren_expression,
        unary_plus_expression,
        rc_could_miscompile_control_params,
        dangling_literal_at_eof,
        disjoint_code_page,

        // Compiler
        /// `string_and_language` is populated
        string_already_defined,
        font_id_already_defined,
        /// `file_open_error` is populated
        file_open_error,
        /// `accelerator_error` is populated
        invalid_accelerator_key,
        accelerator_type_required,
        accelerator_shift_or_control_without_virtkey,
        rc_would_miscompile_control_padding,
        rc_would_miscompile_control_class_ordinal,
        /// `icon_dir` is populated
        rc_would_error_on_icon_dir,
        /// `icon_dir` is populated
        format_not_supported_in_icon_dir,
        /// `resource` is populated and contains the expected type
        icon_dir_and_resource_type_mismatch,
        /// `icon_read_error` is populated
        icon_read_error,
        /// `icon_dir` is populated
        rc_would_error_on_bitmap_version,
        /// `icon_dir` is populated
        max_icon_ids_exhausted,
        /// `bmp_read_error` is populated
        bmp_read_error,
        /// `number` is populated and contains a string index for which the string contains
        /// the bytes of a `u64` (native endian). The `u64` contains the number of ignored bytes.
        bmp_ignored_palette_bytes,
        /// `number` is populated and contains a string index for which the string contains
        /// the bytes of a `u64` (native endian). The `u64` contains the number of missing bytes.
        bmp_missing_palette_bytes,
        /// `number` is populated and contains a string index for which the string contains
        /// the bytes of a `u64` (native endian). The `u64` contains the number of miscompiled bytes.
        rc_would_miscompile_bmp_palette_padding,
        resource_header_size_exceeds_max,
        resource_data_size_exceeds_max,
        control_extra_data_size_exceeds_max,
        version_node_size_exceeds_max,
        fontdir_size_exceeds_max,
        /// `number` is populated and contains a string index for the filename
        number_expression_as_filename,
        /// `number` is populated and contains the control ID that is a duplicate
        control_id_already_defined,
        /// `number` is populated and contains the disallowed codepoint
        invalid_filename,
        /// `statement_with_u16_param` is populated
        rc_would_error_u16_with_l_suffix,
        result_contains_fontdir,
        /// `number` is populated and contains the ordinal value that the id would be miscompiled to
        rc_would_miscompile_dialog_menu_id,
        /// `number` is populated and contains the ordinal value that the value would be miscompiled to
        rc_would_miscompile_dialog_class,
        /// `menu_or_class` is populated and contains the type of the parameter statement
        rc_would_miscompile_dialog_menu_or_class_id_forced_ordinal,
        rc_would_miscompile_dialog_menu_id_starts_with_digit,
        dialog_menu_id_was_uppercased,
        duplicate_optional_statement_skipped,
        invalid_digit_character_in_ordinal,

        // Literals
        /// `number` is populated
        rc_would_miscompile_codepoint_whitespace,
        /// `number` is populated
        rc_would_miscompile_codepoint_skip,
        /// `number` is populated
        rc_would_miscompile_codepoint_bom,
        tab_converted_to_spaces,

        // General (used in various places)
        /// `number` is populated and contains the value that the ordinal would have in the Win32 RC compiler implementation
        win32_non_ascii_ordinal,

        // Initialization
        /// `file_open_error` is populated, but `filename_string_index` is not
        failed_to_open_cwd,
    };

    fn formatToken(ctx: TokenFormatContext, writer: *std.io.Writer) std.io.Writer.Error!void {
        switch (ctx.token.id) {
            .eof => return writer.writeAll(ctx.token.id.nameForErrorDisplay()),
            else => {},
        }

        const slice = ctx.token.slice(ctx.source);
        var src_i: usize = 0;
        while (src_i < slice.len) {
            const codepoint = ctx.code_page.codepointAt(src_i, slice) orelse break;
            defer src_i += codepoint.byte_len;
            const display_codepoint = codepointForDisplay(codepoint) orelse continue;
            var buf: [4]u8 = undefined;
            const utf8_len = std.unicode.utf8Encode(display_codepoint, &buf) catch unreachable;
            try writer.writeAll(buf[0..utf8_len]);
        }
    }

    const TokenFormatContext = struct {
        token: Token,
        source: []const u8,
        code_page: SupportedCodePage,
    };

    fn fmtToken(self: ErrorDetails, source: []const u8) std.fmt.Formatter(TokenFormatContext, formatToken) {
        return .{ .data = .{
            .token = self.token,
            .code_page = self.code_page,
            .source = source,
        } };
    }

    pub fn render(self: ErrorDetails, writer: anytype, source: []const u8, strings: []const []const u8) !void {
        switch (self.err) {
            .unfinished_string_literal => {
                return writer.print("unfinished string literal at '{f}', expected closing '\"'", .{self.fmtToken(source)});
            },
            .string_literal_too_long => {
                return writer.print("string literal too long (max is currently {} characters)", .{self.extra.number});
            },
            .invalid_number_with_exponent => {
                return writer.print("base 10 number literal with exponent is not allowed: {s}", .{self.token.slice(source)});
            },
            .invalid_digit_character_in_number_literal => switch (self.type) {
                .err, .warning => return writer.writeAll("non-ASCII digit characters are not allowed in number literals"),
                .note => return writer.writeAll("the Win32 RC compiler allows non-ASCII digit characters, but will miscompile them"),
                .hint => return,
            },
            .illegal_byte => {
                return writer.print("character '{f}' is not allowed", .{
                    std.ascii.hexEscape(self.token.slice(source), .upper),
                });
            },
            .illegal_byte_outside_string_literals => {
                return writer.print("character '{f}' is not allowed outside of string literals", .{
                    std.ascii.hexEscape(self.token.slice(source), .upper),
                });
            },
            .illegal_codepoint_outside_string_literals => {
                // This is somewhat hacky, but we know that:
                //  - This error is only possible with codepoints outside of the Windows-1252 character range
                //  - So, the only supported code page that could generate this error is UTF-8
                // Therefore, we just assume the token bytes are UTF-8 and decode them to get the illegal
                // codepoint.
                //
                // FIXME: Support other code pages if they become relevant
                const bytes = self.token.slice(source);
                const codepoint = std.unicode.utf8Decode(bytes) catch unreachable;
                return writer.print("codepoint <U+{X:0>4}> is not allowed outside of string literals", .{codepoint});
            },
            .illegal_byte_order_mark => {
                return writer.writeAll("byte order mark <U+FEFF> is not allowed");
            },
            .illegal_private_use_character => {
                return writer.writeAll("private use character <U+E000> is not allowed");
            },
            .found_c_style_escaped_quote => {
                return writer.writeAll("escaping quotes with \\\" is not allowed (use \"\" instead)");
            },
            .code_page_pragma_missing_left_paren => {
                return writer.writeAll("expected left parenthesis after 'code_page' in #pragma code_page");
            },
            .code_page_pragma_missing_right_paren => {
                return writer.writeAll("expected right parenthesis after '<number>' in #pragma code_page");
            },
            .code_page_pragma_invalid_code_page => {
                return writer.writeAll("invalid or unknown code page in #pragma code_page");
            },
            .code_page_pragma_not_integer => {
                return writer.writeAll("code page is not a valid integer in #pragma code_page");
            },
            .code_page_pragma_overflow => {
                return writer.writeAll("code page too large in #pragma code_page");
            },
            .code_page_pragma_unsupported_code_page => {
                // We know that the token slice is a well-formed #pragma code_page(N), so
                // we can skip to the first ( and then get the number that follows
                const token_slice = self.token.slice(source);
                var number_start = std.mem.indexOfScalar(u8, token_slice, '(').? + 1;
                while (std.ascii.isWhitespace(token_slice[number_start])) {
                    number_start += 1;
                }
                var number_slice = token_slice[number_start..number_start];
                while (std.ascii.isDigit(token_slice[number_start + number_slice.len])) {
                    number_slice.len += 1;
                }
                const number = std.fmt.parseUnsigned(u16, number_slice, 10) catch unreachable;
                const code_page = code_pages.getByIdentifier(number) catch unreachable;
                // TODO: Improve or maybe add a note making it more clear that the code page
                //       is valid and that the code page is unsupported purely due to a limitation
                //       in this compiler.
                return writer.print("unsupported code page '{s} (id={})' in #pragma code_page", .{ @tagName(code_page), number });
            },
            .unfinished_raw_data_block => {
                return writer.print("unfinished raw data block at '{f}', expected closing '}}' or 'END'", .{self.fmtToken(source)});
            },
            .unfinished_string_table_block => {
                return writer.print("unfinished STRINGTABLE block at '{f}', expected closing '}}' or 'END'", .{self.fmtToken(source)});
            },
            .expected_token => {
                return writer.print("expected '{s}', got '{f}'", .{ self.extra.expected.nameForErrorDisplay(), self.fmtToken(source) });
            },
            .expected_something_else => {
                try writer.writeAll("expected ");
                try self.extra.expected_types.writeCommaSeparated(writer);
                return writer.print("; got '{f}'", .{self.fmtToken(source)});
            },
            .resource_type_cant_use_raw_data => switch (self.type) {
                .err, .warning => try writer.print("expected '<filename>', found '{f}' (resource type '{s}' can't use raw data)", .{ self.fmtToken(source), self.extra.resource.nameForErrorDisplay() }),
                .note => try writer.print("if '{f}' is intended to be a filename, it must be specified as a quoted string literal", .{self.fmtToken(source)}),
                .hint => return,
            },
            .id_must_be_ordinal => {
                try writer.print("id of resource type '{s}' must be an ordinal (u16), got '{f}'", .{ self.extra.resource.nameForErrorDisplay(), self.fmtToken(source) });
            },
            .name_or_id_not_allowed => {
                try writer.print("name or id is not allowed for resource type '{s}'", .{self.extra.resource.nameForErrorDisplay()});
            },
            .string_resource_as_numeric_type => switch (self.type) {
                .err, .warning => try writer.writeAll("the number 6 (RT_STRING) cannot be used as a resource type"),
                .note => try writer.writeAll("using RT_STRING directly likely results in an invalid .res file, use a STRINGTABLE instead"),
                .hint => return,
            },
            .ascii_character_not_equivalent_to_virtual_key_code => {
                // TODO: Better wording? This is what the Win32 RC compiler emits.
                //       This occurs when VIRTKEY and a control code is specified ("^c", etc)
                try writer.writeAll("ASCII character not equivalent to virtual key code");
            },
            .empty_menu_not_allowed => {
                try writer.print("empty menu of type '{f}' not allowed", .{self.fmtToken(source)});
            },
            .rc_would_miscompile_version_value_padding => switch (self.type) {
                .err, .warning => return writer.print("the padding before this quoted string value would be miscompiled by the Win32 RC compiler", .{}),
                .note => return writer.print("to avoid the potential miscompilation, consider adding a comma between the key and the quoted string", .{}),
                .hint => return,
            },
            .rc_would_miscompile_version_value_byte_count => switch (self.type) {
                .err, .warning => return writer.print("the byte count of this value would be miscompiled by the Win32 RC compiler", .{}),
                .note => return writer.print("to avoid the potential miscompilation, do not mix numbers and strings within a value", .{}),
                .hint => return,
            },
            .code_page_pragma_in_included_file => {
                try writer.print("#pragma code_page is not supported in an included resource file", .{});
            },
            .nested_resource_level_exceeds_max => switch (self.type) {
                .err, .warning => {
                    const max = switch (self.extra.resource) {
                        .versioninfo => parse.max_nested_version_level,
                        .menu, .menuex => parse.max_nested_menu_level,
                        else => unreachable,
                    };
                    return writer.print("{s} contains too many nested children (max is {})", .{ self.extra.resource.nameForErrorDisplay(), max });
                },
                .note => return writer.print("max {s} nesting level exceeded here", .{self.extra.resource.nameForErrorDisplay()}),
                .hint => return,
            },
            .too_many_dialog_controls_or_toolbar_buttons => switch (self.type) {
                .err, .warning => return writer.print("{s} contains too many {s} (max is {})", .{ self.extra.resource.nameForErrorDisplay(), switch (self.extra.resource) {
                    .toolbar => "buttons",
                    else => "controls",
                }, std.math.maxInt(u16) }),
                .note => return writer.print("maximum number of {s} exceeded here", .{switch (self.extra.resource) {
                    .toolbar => "buttons",
                    else => "controls",
                }}),
                .hint => return,
            },
            .nested_expression_level_exceeds_max => switch (self.type) {
                .err, .warning => return writer.print("expression contains too many syntax levels (max is {})", .{parse.max_nested_expression_level}),
                .note => return writer.print("maximum expression level exceeded here", .{}),
                .hint => return,
            },
            .close_paren_expression => {
                try writer.writeAll("the Win32 RC compiler would accept ')' as a valid expression, but it would be skipped over and potentially lead to unexpected outcomes");
            },
            .unary_plus_expression => {
                try writer.writeAll("the Win32 RC compiler may accept '+' as a unary operator here, but it is not supported in this implementation; consider omitting the unary +");
            },
            .rc_could_miscompile_control_params => switch (self.type) {
                .err, .warning => return writer.print("this token could be erroneously skipped over by the Win32 RC compiler", .{}),
                .note => return writer.print("to avoid the potential miscompilation, consider adding a comma after the style parameter", .{}),
                .hint => return,
            },
            .dangling_literal_at_eof => {
                try writer.writeAll("dangling literal at end-of-file; this is not a problem, but it is likely a mistake");
            },
            .disjoint_code_page => switch (self.type) {
                .err, .warning => return writer.print("#pragma code_page as the first thing in the .rc script can cause the input and output code pages to become out-of-sync", .{}),
                .note => return writer.print("to avoid unexpected behavior, add a comment (or anything else) above the #pragma code_page line", .{}),
                .hint => return,
            },
            .string_already_defined => switch (self.type) {
                .err, .warning => {
                    const language = self.extra.string_and_language.language;
                    return writer.print("string with id {d} (0x{X}) already defined for language {f}", .{ self.extra.string_and_language.id, self.extra.string_and_language.id, language });
                },
                .note => return writer.print("previous definition of string with id {d} (0x{X}) here", .{ self.extra.string_and_language.id, self.extra.string_and_language.id }),
                .hint => return,
            },
            .font_id_already_defined => switch (self.type) {
                .err => return writer.print("font with id {d} already defined", .{self.extra.number}),
                .warning => return writer.print("skipped duplicate font with id {d}", .{self.extra.number}),
                .note => return writer.print("previous definition of font with id {d} here", .{self.extra.number}),
                .hint => return,
            },
            .file_open_error => {
                try writer.print("unable to open file '{s}': {s}", .{ strings[self.extra.file_open_error.filename_string_index], @tagName(self.extra.file_open_error.err) });
            },
            .invalid_accelerator_key => {
                try writer.print("invalid accelerator key '{f}': {s}", .{ self.fmtToken(source), @tagName(self.extra.accelerator_error.err) });
            },
            .accelerator_type_required => {
                try writer.writeAll("accelerator type [ASCII or VIRTKEY] required when key is an integer");
            },
            .accelerator_shift_or_control_without_virtkey => {
                try writer.writeAll("SHIFT or CONTROL used without VIRTKEY");
            },
            .rc_would_miscompile_control_padding => switch (self.type) {
                .err, .warning => return writer.print("the padding before this control would be miscompiled by the Win32 RC compiler (it would insert 2 extra bytes of padding)", .{}),
                .note => return writer.print("to avoid the potential miscompilation, consider adding one more byte to the control data of the control preceding this one", .{}),
                .hint => return,
            },
            .rc_would_miscompile_control_class_ordinal => switch (self.type) {
                .err, .warning => return writer.print("the control class of this CONTROL would be miscompiled by the Win32 RC compiler", .{}),
                .note => return writer.print("to avoid the potential miscompilation, consider specifying the control class using a string (BUTTON, EDIT, etc) instead of a number", .{}),
                .hint => return,
            },
            .rc_would_error_on_icon_dir => switch (self.type) {
                .err, .warning => return writer.print("the resource at index {} of this {s} has the format '{s}'; this would be an error in the Win32 RC compiler", .{ self.extra.icon_dir.index, @tagName(self.extra.icon_dir.icon_type), @tagName(self.extra.icon_dir.icon_format) }),
                .note => {
                    // The only note supported is one specific to exactly this combination
                    if (!(self.extra.icon_dir.icon_type == .icon and self.extra.icon_dir.icon_format == .riff)) unreachable;
                    try writer.print("animated RIFF icons within resource groups may not be well supported, consider using an animated icon file (.ani) instead", .{});
                },
                .hint => return,
            },
            .format_not_supported_in_icon_dir => {
                try writer.print("resource with format '{s}' (at index {}) is not allowed in {s} resource groups", .{ @tagName(self.extra.icon_dir.icon_format), self.extra.icon_dir.index, @tagName(self.extra.icon_dir.icon_type) });
            },
            .icon_dir_and_resource_type_mismatch => {
                const unexpected_type: rc.ResourceType = if (self.extra.resource == .icon) .cursor else .icon;
                // TODO: Better wording
                try writer.print("resource type '{s}' does not match type '{s}' specified in the file", .{ self.extra.resource.nameForErrorDisplay(), unexpected_type.nameForErrorDisplay() });
            },
            .icon_read_error => {
                try writer.print("unable to read {s} file '{s}': {s}", .{ @tagName(self.extra.icon_read_error.icon_type), strings[self.extra.icon_read_error.filename_string_index], @tagName(self.extra.icon_read_error.err) });
            },
            .rc_would_error_on_bitmap_version => switch (self.type) {
                .err => try writer.print("the DIB at index {} of this {s} is of version '{s}'; this version is no longer allowed and should be upgraded to '{s}'", .{
                    self.extra.icon_dir.index,
                    @tagName(self.extra.icon_dir.icon_type),
                    self.extra.icon_dir.bitmap_version.nameForErrorDisplay(),
                    ico.BitmapHeader.Version.@"nt3.1".nameForErrorDisplay(),
                }),
                .warning => try writer.print("the DIB at index {} of this {s} is of version '{s}'; this would be an error in the Win32 RC compiler", .{
                    self.extra.icon_dir.index,
                    @tagName(self.extra.icon_dir.icon_type),
                    self.extra.icon_dir.bitmap_version.nameForErrorDisplay(),
                }),
                .note => unreachable,
                .hint => return,
            },
            .max_icon_ids_exhausted => switch (self.type) {
                .err, .warning => try writer.print("maximum global icon/cursor ids exhausted (max is {})", .{std.math.maxInt(u16) - 1}),
                .note => try writer.print("maximum icon/cursor id exceeded at index {} of this {s}", .{ self.extra.icon_dir.index, @tagName(self.extra.icon_dir.icon_type) }),
                .hint => return,
            },
            .bmp_read_error => {
                try writer.print("invalid bitmap file '{s}': {s}", .{ strings[self.extra.bmp_read_error.filename_string_index], @tagName(self.extra.bmp_read_error.err) });
            },
            .bmp_ignored_palette_bytes => {
                const bytes = strings[self.extra.number];
                const ignored_bytes = std.mem.readInt(u64, bytes[0..8], native_endian);
                try writer.print("bitmap has {d} extra bytes preceding the pixel data which will be ignored", .{ignored_bytes});
            },
            .bmp_missing_palette_bytes => {
                const bytes = strings[self.extra.number];
                const missing_bytes = std.mem.readInt(u64, bytes[0..8], native_endian);
                try writer.print("bitmap has {d} missing color palette bytes", .{missing_bytes});
            },
            .rc_would_miscompile_bmp_palette_padding => {
                try writer.writeAll("the Win32 RC compiler would erroneously pad out the missing bytes");
                if (self.extra.number != 0) {
                    const bytes = strings[self.extra.number];
                    const miscompiled_bytes = std.mem.readInt(u64, bytes[0..8], native_endian);
                    try writer.print(" (and the added padding bytes would include {d} bytes of the pixel data)", .{miscompiled_bytes});
                }
            },
            .resource_header_size_exceeds_max => {
                try writer.print("resource's header length exceeds maximum of {} bytes", .{std.math.maxInt(u32)});
            },
            .resource_data_size_exceeds_max => switch (self.type) {
                .err, .warning => return writer.print("resource's data length exceeds maximum of {} bytes", .{std.math.maxInt(u32)}),
                .note => return writer.print("maximum data length exceeded here", .{}),
                .hint => return,
            },
            .control_extra_data_size_exceeds_max => switch (self.type) {
                .err, .warning => try writer.print("control data length exceeds maximum of {} bytes", .{std.math.maxInt(u16)}),
                .note => return writer.print("maximum control data length exceeded here", .{}),
                .hint => return,
            },
            .version_node_size_exceeds_max => switch (self.type) {
                .err, .warning => return writer.print("version node tree size exceeds maximum of {} bytes", .{std.math.maxInt(u16)}),
                .note => return writer.print("maximum tree size exceeded while writing this child", .{}),
                .hint => return,
            },
            .fontdir_size_exceeds_max => switch (self.type) {
                .err, .warning => return writer.print("FONTDIR data length exceeds maximum of {} bytes", .{std.math.maxInt(u32)}),
                .note => return writer.writeAll("this is likely due to the size of the combined lengths of the device/face names of all FONT resources"),
                .hint => return,
            },
            .number_expression_as_filename => switch (self.type) {
                .err, .warning => return writer.writeAll("filename cannot be specified using a number expression, consider using a quoted string instead"),
                .note => return writer.print("the Win32 RC compiler would evaluate this number expression as the filename '{s}'", .{strings[self.extra.number]}),
                .hint => return,
            },
            .control_id_already_defined => switch (self.type) {
                .err, .warning => return writer.print("control with id {d} already defined for this dialog", .{self.extra.number}),
                .note => return writer.print("previous definition of control with id {d} here", .{self.extra.number}),
                .hint => return,
            },
            .invalid_filename => {
                const disallowed_codepoint = self.extra.number;
                if (disallowed_codepoint < 128 and std.ascii.isPrint(@intCast(disallowed_codepoint))) {
                    try writer.print("evaluated filename contains a disallowed character: '{c}'", .{@as(u8, @intCast(disallowed_codepoint))});
                } else {
                    try writer.print("evaluated filename contains a disallowed codepoint: <U+{X:0>4}>", .{disallowed_codepoint});
                }
            },
            .rc_would_error_u16_with_l_suffix => switch (self.type) {
                .err, .warning => return writer.print("this {s} parameter would be an error in the Win32 RC compiler", .{@tagName(self.extra.statement_with_u16_param)}),
                .note => return writer.writeAll("to avoid the error, remove any L suffixes from numbers within the parameter"),
                .hint => return,
            },
            .result_contains_fontdir => return,
            .rc_would_miscompile_dialog_menu_id => switch (self.type) {
                .err, .warning => return writer.print("the id of this menu would be miscompiled by the Win32 RC compiler", .{}),
                .note => return writer.print("the Win32 RC compiler would evaluate the id as the ordinal/number value {d}", .{self.extra.number}),
                .hint => return,
            },
            .rc_would_miscompile_dialog_class => switch (self.type) {
                .err, .warning => return writer.print("this class would be miscompiled by the Win32 RC compiler", .{}),
                .note => return writer.print("the Win32 RC compiler would evaluate it as the ordinal/number value {d}", .{self.extra.number}),
                .hint => return,
            },
            .rc_would_miscompile_dialog_menu_or_class_id_forced_ordinal => switch (self.type) {
                .err, .warning => return,
                .note => return writer.print("to avoid the potential miscompilation, only specify one {s} per dialog resource", .{@tagName(self.extra.menu_or_class)}),
                .hint => return,
            },
            .rc_would_miscompile_dialog_menu_id_starts_with_digit => switch (self.type) {
                .err, .warning => return,
                .note => return writer.writeAll("to avoid the potential miscompilation, the first character of the id should not be a digit"),
                .hint => return,
            },
            .dialog_menu_id_was_uppercased => return,
            .duplicate_optional_statement_skipped => {
                return writer.writeAll("this statement was ignored; when multiple statements of the same type are specified, only the last takes precedence");
            },
            .invalid_digit_character_in_ordinal => {
                return writer.writeAll("non-ASCII digit characters are not allowed in ordinal (number) values");
            },
            .rc_would_miscompile_codepoint_whitespace => {
                const treated_as = self.extra.number >> 8;
                return writer.print("codepoint U+{X:0>4} within a string literal would be miscompiled by the Win32 RC compiler (it would get treated as U+{X:0>4})", .{ self.extra.number, treated_as });
            },
            .rc_would_miscompile_codepoint_skip => {
                return writer.print("codepoint U+{X:0>4} within a string literal would be miscompiled by the Win32 RC compiler (the codepoint would be missing from the compiled resource)", .{self.extra.number});
            },
            .rc_would_miscompile_codepoint_bom => switch (self.type) {
                .err, .warning => return writer.print("codepoint U+{X:0>4} within a string literal would cause the entire file to be miscompiled by the Win32 RC compiler", .{self.extra.number}),
                .note => return writer.writeAll("the presence of this codepoint causes all non-ASCII codepoints to be byteswapped by the Win32 RC preprocessor"),
                .hint => return,
            },
            .tab_converted_to_spaces => switch (self.type) {
                .err, .warning => return writer.writeAll("the tab character(s) in this string will be converted into a variable number of spaces (determined by the column of the tab character in the .rc file)"),
                .note => return writer.writeAll("to include the tab character itself in a string, the escape sequence \\t should be used"),
                .hint => return,
            },
            .win32_non_ascii_ordinal => switch (self.type) {
                .err, .warning => unreachable,
                .note => return writer.print("the Win32 RC compiler would accept this as an ordinal but its value would be {}", .{self.extra.number}),
                .hint => return,
            },
            .failed_to_open_cwd => {
                try writer.print("failed to open CWD for compilation: {s}", .{@tagName(self.extra.file_open_error.err)});
            },
        }
    }

    pub const VisualTokenInfo = struct {
        before_len: usize,
        point_offset: usize,
        after_len: usize,
    };

    pub fn visualTokenInfo(self: ErrorDetails, source_line_start: usize, source_line_end: usize, source: []const u8) VisualTokenInfo {
        return switch (self.err) {
            // These can technically be more than 1 byte depending on encoding,
            // but they always refer to one visual character/grapheme.
            .illegal_byte,
            .illegal_byte_outside_string_literals,
            .illegal_codepoint_outside_string_literals,
            .illegal_byte_order_mark,
            .illegal_private_use_character,
            => .{
                .before_len = 0,
                .point_offset = cellCount(self.code_page, source, source_line_start, self.token.start),
                .after_len = 0,
            },
            else => .{
                .before_len = before: {
                    const start = @max(source_line_start, if (self.token_span_start) |span_start| span_start.start else self.token.start);
                    break :before cellCount(self.code_page, source, start, self.token.start);
                },
                .point_offset = cellCount(self.code_page, source, source_line_start, self.token.start),
                .after_len = after: {
                    const end = @min(source_line_end, if (self.token_span_end) |span_end| span_end.end else self.token.end);
                    // end may be less than start when pointing to EOF
                    if (end <= self.token.start) break :after 0;
                    break :after cellCount(self.code_page, source, self.token.start, end) - 1;
                },
            },
        };
    }
};

/// Convenience struct only useful when the code page can be inferred from the token
pub const ErrorDetailsWithoutCodePage = blk: {
    const details_info = @typeInfo(ErrorDetails);
    const fields = details_info.@"struct".fields;
    var fields_without_codepage: [fields.len - 1]std.builtin.Type.StructField = undefined;
    var i: usize = 0;
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, "code_page")) continue;
        fields_without_codepage[i] = field;
        i += 1;
    }
    std.debug.assert(i == fields_without_codepage.len);
    break :blk @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields_without_codepage,
        .decls = &.{},
        .is_tuple = false,
    } });
};

fn cellCount(code_page: SupportedCodePage, source: []const u8, start_index: usize, end_index: usize) usize {
    // Note: This is an imperfect solution. A proper implementation here would
    //       involve full grapheme cluster awareness + grapheme width data, but oh well.
    var codepoint_count: usize = 0;
    var index: usize = start_index;
    while (index < end_index) {
        const codepoint = code_page.codepointAt(index, source) orelse break;
        defer index += codepoint.byte_len;
        _ = codepointForDisplay(codepoint) orelse continue;
        codepoint_count += 1;
        // no need to count more than we will display
        if (codepoint_count >= max_source_line_codepoints + truncated_str.len) break;
    }
    return codepoint_count;
}

const truncated_str = "<...truncated...>";

pub fn renderErrorMessage(writer: *std.io.Writer, tty_config: std.io.tty.Config, cwd: std.fs.Dir, err_details: ErrorDetails, source: []const u8, strings: []const []const u8, source_mappings: ?SourceMappings) !void {
    if (err_details.type == .hint) return;

    const source_line_start = err_details.token.getLineStartForErrorDisplay(source);
    // Treat tab stops as 1 column wide for error display purposes,
    // and add one to get a 1-based column
    const column = err_details.token.calculateColumn(source, 1, source_line_start) + 1;

    const corresponding_span: ?SourceMappings.CorrespondingSpan = if (source_mappings) |mappings|
        mappings.getCorrespondingSpan(err_details.token.line_number)
    else
        null;
    const corresponding_file: ?[]const u8 = if (source_mappings != null and corresponding_span != null)
        source_mappings.?.files.get(corresponding_span.?.filename_offset)
    else
        null;

    const err_line = if (corresponding_span) |span| span.start_line else err_details.token.line_number;

    try tty_config.setColor(writer, .bold);
    if (corresponding_file) |file| {
        try writer.writeAll(file);
    } else {
        try tty_config.setColor(writer, .dim);
        try writer.writeAll("<after preprocessor>");
        try tty_config.setColor(writer, .reset);
        try tty_config.setColor(writer, .bold);
    }
    try writer.print(":{d}:{d}: ", .{ err_line, column });
    switch (err_details.type) {
        .err => {
            try tty_config.setColor(writer, .red);
            try writer.writeAll("error: ");
        },
        .warning => {
            try tty_config.setColor(writer, .yellow);
            try writer.writeAll("warning: ");
        },
        .note => {
            try tty_config.setColor(writer, .cyan);
            try writer.writeAll("note: ");
        },
        .hint => unreachable,
    }
    try tty_config.setColor(writer, .reset);
    try tty_config.setColor(writer, .bold);
    try err_details.render(writer, source, strings);
    try writer.writeByte('\n');
    try tty_config.setColor(writer, .reset);

    if (!err_details.print_source_line) {
        try writer.writeByte('\n');
        return;
    }

    const source_line = err_details.token.getLineForErrorDisplay(source, source_line_start);
    const visual_info = err_details.visualTokenInfo(source_line_start, source_line_start + source_line.len, source);
    const truncated_visual_info = ErrorDetails.VisualTokenInfo{
        .before_len = if (visual_info.point_offset > max_source_line_codepoints and visual_info.before_len > 0)
            (visual_info.before_len + 1) -| (visual_info.point_offset - max_source_line_codepoints)
        else
            visual_info.before_len,
        .point_offset = @min(max_source_line_codepoints + 1, visual_info.point_offset),
        .after_len = if (visual_info.point_offset > max_source_line_codepoints)
            @min(truncated_str.len - 3, visual_info.after_len)
        else
            @min(max_source_line_codepoints - visual_info.point_offset + (truncated_str.len - 2), visual_info.after_len),
    };

    // Need this to determine if the 'line originated from' note is worth printing
    var source_line_for_display_buf: [max_source_line_bytes]u8 = undefined;
    const source_line_for_display = writeSourceSlice(&source_line_for_display_buf, source_line, err_details.code_page);

    try writer.writeAll(source_line_for_display.line);
    if (source_line_for_display.truncated) {
        try tty_config.setColor(writer, .dim);
        try writer.writeAll(truncated_str);
        try tty_config.setColor(writer, .reset);
    }
    try writer.writeByte('\n');

    try tty_config.setColor(writer, .green);
    const num_spaces = truncated_visual_info.point_offset - truncated_visual_info.before_len;
    try writer.splatByteAll(' ', num_spaces);
    try writer.splatByteAll('~', truncated_visual_info.before_len);
    try writer.writeByte('^');
    try writer.splatByteAll('~', truncated_visual_info.after_len);
    try writer.writeByte('\n');
    try tty_config.setColor(writer, .reset);

    if (corresponding_span != null and corresponding_file != null) {
        var worth_printing_lines: bool = true;
        var initial_lines_err: ?anyerror = null;
        var corresponding_lines: ?CorrespondingLines = CorrespondingLines.init(
            cwd,
            err_details,
            source_line_for_display.line,
            corresponding_span.?,
            corresponding_file.?,
        ) catch |err| switch (err) {
            error.NotWorthPrintingLines => blk: {
                worth_printing_lines = false;
                break :blk null;
            },
            error.NotWorthPrintingNote => return,
            else => |e| blk: {
                initial_lines_err = e;
                break :blk null;
            },
        };
        defer if (corresponding_lines) |*cl| cl.deinit();

        try tty_config.setColor(writer, .bold);
        if (corresponding_file) |file| {
            try writer.writeAll(file);
        } else {
            try tty_config.setColor(writer, .dim);
            try writer.writeAll("<after preprocessor>");
            try tty_config.setColor(writer, .reset);
            try tty_config.setColor(writer, .bold);
        }
        try writer.print(":{d}:{d}: ", .{ err_line, column });
        try tty_config.setColor(writer, .cyan);
        try writer.writeAll("note: ");
        try tty_config.setColor(writer, .reset);
        try tty_config.setColor(writer, .bold);
        try writer.writeAll("this line originated from line");
        if (corresponding_span.?.start_line != corresponding_span.?.end_line) {
            try writer.print("s {}-{}", .{ corresponding_span.?.start_line, corresponding_span.?.end_line });
        } else {
            try writer.print(" {}", .{corresponding_span.?.start_line});
        }
        try writer.print(" of file '{s}'\n", .{corresponding_file.?});
        try tty_config.setColor(writer, .reset);

        if (!worth_printing_lines) return;

        const write_lines_err: ?anyerror = write_lines: {
            if (initial_lines_err) |err| break :write_lines err;
            while (corresponding_lines.?.next() catch |err| {
                break :write_lines err;
            }) |display_line| {
                try writer.writeAll(display_line.line);
                if (display_line.truncated) {
                    try tty_config.setColor(writer, .dim);
                    try writer.writeAll(truncated_str);
                    try tty_config.setColor(writer, .reset);
                }
                try writer.writeByte('\n');
            }
            break :write_lines null;
        };
        if (write_lines_err) |err| {
            try tty_config.setColor(writer, .red);
            try writer.writeAll(" | ");
            try tty_config.setColor(writer, .reset);
            try tty_config.setColor(writer, .dim);
            try writer.print("unable to print line(s) from file: {s}\n", .{@errorName(err)});
            try tty_config.setColor(writer, .reset);
        }
        try writer.writeByte('\n');
    }
}

const VisualLine = struct {
    line: []u8,
    truncated: bool,
};

const CorrespondingLines = struct {
    // enough room for one more codepoint, just so that we don't have to keep
    // track of this being truncated, since the extra codepoint will ensure
    // the visual line will need to truncate in that case.
    line_buf: [max_source_line_bytes + 4]u8 = undefined,
    line_len: usize = 0,
    visual_line_buf: [max_source_line_bytes]u8 = undefined,
    visual_line_len: usize = 0,
    truncated: bool = false,
    line_num: usize = 1,
    initial_line: bool = true,
    last_byte: u8 = 0,
    at_eof: bool = false,
    span: SourceMappings.CorrespondingSpan,
    file: std.fs.File,
    buffered_reader: BufferedReaderType,
    code_page: SupportedCodePage,

    const BufferedReaderType = std.io.BufferedReader(512, std.fs.File.DeprecatedReader);

    pub fn init(cwd: std.fs.Dir, err_details: ErrorDetails, line_for_comparison: []const u8, corresponding_span: SourceMappings.CorrespondingSpan, corresponding_file: []const u8) !CorrespondingLines {
        // We don't do line comparison for this error, so don't print the note if the line
        // number is different
        if (err_details.err == .string_literal_too_long and err_details.token.line_number != corresponding_span.start_line) {
            return error.NotWorthPrintingNote;
        }

        // Don't print the originating line for this error, we know it's really long
        if (err_details.err == .string_literal_too_long) {
            return error.NotWorthPrintingLines;
        }

        var corresponding_lines = CorrespondingLines{
            .span = corresponding_span,
            .file = try utils.openFileNotDir(cwd, corresponding_file, .{}),
            .buffered_reader = undefined,
            .code_page = err_details.code_page,
        };
        corresponding_lines.buffered_reader = BufferedReaderType{
            .unbuffered_reader = corresponding_lines.file.deprecatedReader(),
        };
        errdefer corresponding_lines.deinit();

        var fbs = std.io.fixedBufferStream(&corresponding_lines.line_buf);
        const writer = fbs.writer();

        try corresponding_lines.writeLineFromStreamVerbatim(
            writer,
            corresponding_lines.buffered_reader.reader(),
            corresponding_span.start_line,
        );

        const visual_line = writeSourceSlice(
            &corresponding_lines.visual_line_buf,
            corresponding_lines.line_buf[0..corresponding_lines.line_len],
            err_details.code_page,
        );
        corresponding_lines.visual_line_len = visual_line.line.len;
        corresponding_lines.truncated = visual_line.truncated;

        // If the lines are the same as they were before preprocessing, skip printing the note entirely
        if (corresponding_span.start_line == corresponding_span.end_line and std.mem.eql(
            u8,
            line_for_comparison,
            corresponding_lines.visual_line_buf[0..corresponding_lines.visual_line_len],
        )) {
            return error.NotWorthPrintingNote;
        }

        return corresponding_lines;
    }

    pub fn next(self: *CorrespondingLines) !?VisualLine {
        if (self.initial_line) {
            self.initial_line = false;
            return .{
                .line = self.visual_line_buf[0..self.visual_line_len],
                .truncated = self.truncated,
            };
        }
        if (self.line_num > self.span.end_line) return null;
        if (self.at_eof) return error.LinesNotFound;

        self.line_len = 0;
        self.visual_line_len = 0;

        var fbs = std.io.fixedBufferStream(&self.line_buf);
        const writer = fbs.writer();

        try self.writeLineFromStreamVerbatim(
            writer,
            self.buffered_reader.reader(),
            self.line_num,
        );

        const visual_line = writeSourceSlice(
            &self.visual_line_buf,
            self.line_buf[0..self.line_len],
            self.code_page,
        );
        self.visual_line_len = visual_line.line.len;

        return visual_line;
    }

    fn writeLineFromStreamVerbatim(self: *CorrespondingLines, writer: anytype, input: anytype, line_num: usize) !void {
        while (try readByteOrEof(input)) |byte| {
            switch (byte) {
                '\n', '\r' => {
                    if (!utils.isLineEndingPair(self.last_byte, byte)) {
                        const line_complete = self.line_num == line_num;
                        self.line_num += 1;
                        if (line_complete) {
                            self.last_byte = byte;
                            return;
                        }
                    } else {
                        // reset last_byte to a non-line ending so that
                        // consecutive CRLF pairs don't get treated as one
                        // long line ending 'pair'
                        self.last_byte = 0;
                        continue;
                    }
                },
                else => {
                    if (self.line_num == line_num) {
                        if (writer.writeByte(byte)) {
                            self.line_len += 1;
                        } else |err| switch (err) {
                            error.NoSpaceLeft => {},
                            else => |e| return e,
                        }
                    }
                },
            }
            self.last_byte = byte;
        }
        self.at_eof = true;
        // hacky way to get next to return null
        self.line_num += 1;
    }

    fn readByteOrEof(reader: anytype) !?u8 {
        return reader.readByte() catch |err| switch (err) {
            error.EndOfStream => return null,
            else => |e| return e,
        };
    }

    pub fn deinit(self: *CorrespondingLines) void {
        self.file.close();
    }
};

const max_source_line_codepoints = 120;
const max_source_line_bytes = max_source_line_codepoints * 4;

fn writeSourceSlice(buf: []u8, slice: []const u8, code_page: SupportedCodePage) VisualLine {
    var src_i: usize = 0;
    var dest_i: usize = 0;
    var codepoint_count: usize = 0;
    while (src_i < slice.len) {
        const codepoint = code_page.codepointAt(src_i, slice) orelse break;
        defer src_i += codepoint.byte_len;
        const display_codepoint = codepointForDisplay(codepoint) orelse continue;
        codepoint_count += 1;
        if (codepoint_count > max_source_line_codepoints) {
            return .{ .line = buf[0..dest_i], .truncated = true };
        }
        const utf8_len = std.unicode.utf8Encode(display_codepoint, buf[dest_i..]) catch unreachable;
        dest_i += utf8_len;
    }
    return .{ .line = buf[0..dest_i], .truncated = false };
}

fn codepointForDisplay(codepoint: code_pages.Codepoint) ?u21 {
    return switch (codepoint.value) {
        '\x00'...'\x08',
        '\x0E'...'\x1F',
        '\x7F',
        code_pages.Codepoint.invalid,
        => '�',
        // \r is seemingly ignored by the RC compiler so skipping it when printing source lines
        // could help avoid confusing output (e.g. RC\rDATA if printed verbatim would show up
        // in the console as DATA but the compiler reads it as RCDATA)
        //
        // NOTE: This is irrelevant when using the clang preprocessor, because unpaired \r
        //       characters get converted to \n, but may become relevant if another
        //       preprocessor is used instead.
        '\r' => null,
        '\t', '\x0B', '\x0C' => ' ',
        else => |v| v,
    };
}
