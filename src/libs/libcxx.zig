const std = @import("std");
const path = std.fs.path;
const assert = std.debug.assert;

const target_util = @import("../target.zig");
const Compilation = @import("../Compilation.zig");
const build_options = @import("build_options");
const trace = @import("../tracy.zig").trace;
const Module = @import("../Package/Module.zig");

const libcxxabi_files = [_][]const u8{
    "src/abort_message.cpp",
    "src/cxa_aux_runtime.cpp",
    "src/cxa_default_handlers.cpp",
    "src/cxa_demangle.cpp",
    "src/cxa_exception.cpp",
    "src/cxa_exception_storage.cpp",
    "src/cxa_guard.cpp",
    "src/cxa_handlers.cpp",
    "src/cxa_noexception.cpp",
    "src/cxa_personality.cpp",
    "src/cxa_thread_atexit.cpp",
    "src/cxa_vector.cpp",
    "src/cxa_virtual.cpp",
    "src/fallback_malloc.cpp",
    "src/private_typeinfo.cpp",
    "src/stdlib_exception.cpp",
    "src/stdlib_new_delete.cpp",
    "src/stdlib_stdexcept.cpp",
    "src/stdlib_typeinfo.cpp",
};

const libcxx_base_files = [_][]const u8{
    "src/algorithm.cpp",
    "src/any.cpp",
    "src/bind.cpp",
    "src/call_once.cpp",
    "src/charconv.cpp",
    "src/chrono.cpp",
    "src/error_category.cpp",
    "src/exception.cpp",
    "src/expected.cpp",
    "src/filesystem/directory_entry.cpp",
    "src/filesystem/directory_iterator.cpp",
    "src/filesystem/filesystem_clock.cpp",
    "src/filesystem/filesystem_error.cpp",
    // omit int128_builtins.cpp because it provides __muloti4 which is already provided
    // by compiler_rt and crashes on Windows x86_64: https://github.com/ziglang/zig/issues/10719
    //"src/filesystem/int128_builtins.cpp",
    "src/filesystem/operations.cpp",
    "src/filesystem/path.cpp",
    "src/fstream.cpp",
    "src/functional.cpp",
    "src/hash.cpp",
    "src/ios.cpp",
    "src/ios.instantiations.cpp",
    "src/iostream.cpp",
    "src/locale.cpp",
    "src/memory.cpp",
    "src/memory_resource.cpp",
    "src/new.cpp",
    "src/new_handler.cpp",
    "src/new_helpers.cpp",
    "src/optional.cpp",
    "src/ostream.cpp",
    "src/print.cpp",
    //"src/pstl/libdispatch.cpp",
    "src/random.cpp",
    "src/random_shuffle.cpp",
    "src/regex.cpp",
    "src/ryu/d2fixed.cpp",
    "src/ryu/d2s.cpp",
    "src/ryu/f2s.cpp",
    "src/stdexcept.cpp",
    "src/string.cpp",
    "src/strstream.cpp",
    "src/support/ibm/mbsnrtowcs.cpp",
    "src/support/ibm/wcsnrtombs.cpp",
    "src/support/ibm/xlocale_zos.cpp",
    "src/support/win32/locale_win32.cpp",
    "src/support/win32/support.cpp",
    "src/system_error.cpp",
    "src/typeinfo.cpp",
    "src/valarray.cpp",
    "src/variant.cpp",
    "src/vector.cpp",
    "src/verbose_abort.cpp",
};

const libcxx_thread_files = [_][]const u8{
    "src/atomic.cpp",
    "src/barrier.cpp",
    "src/condition_variable.cpp",
    "src/condition_variable_destructor.cpp",
    "src/future.cpp",
    "src/mutex.cpp",
    "src/mutex_destructor.cpp",
    "src/shared_mutex.cpp",
    "src/support/win32/thread_win32.cpp",
    "src/thread.cpp",
};

pub const BuildError = error{
    OutOfMemory,
    SubCompilationFailed,
    ZigCompilerNotBuiltWithLLVMExtensions,
};

pub fn buildLibCxx(comp: *Compilation, prog_node: std.Progress.Node) BuildError!void {
    if (!build_options.have_llvm) {
        return error.ZigCompilerNotBuiltWithLLVMExtensions;
    }

    const tracy = trace(@src());
    defer tracy.end();

    var arena_allocator = std.heap.ArenaAllocator.init(comp.gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const root_name = "c++";
    const output_mode = .Lib;
    const link_mode = .static;
    const target = &comp.root_mod.resolved_target.result;

    const cxxabi_include_path = try comp.dirs.zig_lib.join(arena, &.{ "libcxxabi", "include" });
    const cxx_include_path = try comp.dirs.zig_lib.join(arena, &.{ "libcxx", "include" });
    const cxx_src_include_path = try comp.dirs.zig_lib.join(arena, &.{ "libcxx", "src" });
    const cxx_libc_include_path = try comp.dirs.zig_lib.join(arena, &.{ "libcxx", "libc" });

    const optimize_mode = comp.compilerRtOptMode();
    const strip = comp.compilerRtStrip();

    const config = Compilation.Config.resolve(.{
        .output_mode = output_mode,
        .link_mode = link_mode,
        .resolved_target = comp.root_mod.resolved_target,
        .is_test = false,
        .have_zcu = false,
        .emit_bin = true,
        .root_optimize_mode = optimize_mode,
        .root_strip = strip,
        .link_libc = true,
        .lto = comp.config.lto,
        .any_sanitize_thread = comp.config.any_sanitize_thread,
    }) catch |err| {
        comp.setMiscFailure(
            .libcxx,
            "unable to build libc++: resolving configuration failed: {s}",
            .{@errorName(err)},
        );
        return error.SubCompilationFailed;
    };

    const root_mod = Module.create(arena, .{
        .paths = .{
            .root = .zig_lib_root,
            .root_src_path = "",
        },
        .fully_qualified_name = "root",
        .inherited = .{
            .resolved_target = comp.root_mod.resolved_target,
            .strip = strip,
            .stack_check = false,
            .stack_protector = 0,
            .sanitize_c = .off,
            .sanitize_thread = comp.config.any_sanitize_thread,
            .red_zone = comp.root_mod.red_zone,
            .omit_frame_pointer = comp.root_mod.omit_frame_pointer,
            .valgrind = false,
            .optimize_mode = optimize_mode,
            .structured_cfg = comp.root_mod.structured_cfg,
            .pic = if (target_util.supports_fpic(target)) true else null,
            .code_model = comp.root_mod.code_model,
        },
        .global = config,
        .cc_argv = &.{},
        .parent = null,
    }) catch |err| {
        comp.setMiscFailure(
            .libcxx,
            "unable to build libc++: creating module failed: {s}",
            .{@errorName(err)},
        );
        return error.SubCompilationFailed;
    };

    const libcxx_files = if (comp.config.any_non_single_threaded)
        &(libcxx_base_files ++ libcxx_thread_files)
    else
        &libcxx_base_files;

    var c_source_files = try std.ArrayList(Compilation.CSourceFile).initCapacity(arena, libcxx_files.len);

    for (libcxx_files) |cxx_src| {
        // These don't compile on WASI due to e.g. `fchmod` usage.
        if (std.mem.startsWith(u8, cxx_src, "src/filesystem/") and target.os.tag == .wasi)
            continue;
        if (std.mem.startsWith(u8, cxx_src, "src/support/win32/") and target.os.tag != .windows)
            continue;
        if (std.mem.startsWith(u8, cxx_src, "src/support/ibm/") and target.os.tag != .zos)
            continue;

        var cflags = std.ArrayList([]const u8).init(arena);

        try addCxxArgs(comp, arena, &cflags);

        try cflags.append("-DNDEBUG");
        try cflags.append("-DLIBC_NAMESPACE=__llvm_libc_common_utils");
        try cflags.append("-D_LIBCPP_BUILDING_LIBRARY");
        try cflags.append("-DLIBCXX_BUILDING_LIBCXXABI");
        try cflags.append("-D_LIBCPP_HAS_NO_PRAGMA_SYSTEM_HEADER");

        if (target.os.tag == .wasi) {
            try cflags.append("-fno-exceptions");
        }

        try cflags.append("-fvisibility=hidden");
        try cflags.append("-fvisibility-inlines-hidden");

        if (target.os.tag == .zos) {
            try cflags.append("-fno-aligned-allocation");
        } else {
            try cflags.append("-faligned-allocation");
        }

        try cflags.append("-nostdinc++");
        try cflags.append("-std=c++23");
        try cflags.append("-Wno-user-defined-literals");
        try cflags.append("-Wno-covered-switch-default");
        try cflags.append("-Wno-suggest-override");

        // These depend on only the zig lib directory file path, which is
        // purposefully either in the cache or not in the cache. The decision
        // should not be overridden here.
        var cache_exempt_flags = std.ArrayList([]const u8).init(arena);

        try cache_exempt_flags.append("-I");
        try cache_exempt_flags.append(cxx_include_path);

        try cache_exempt_flags.append("-I");
        try cache_exempt_flags.append(cxxabi_include_path);

        try cache_exempt_flags.append("-I");
        try cache_exempt_flags.append(cxx_src_include_path);

        try cache_exempt_flags.append("-I");
        try cache_exempt_flags.append(cxx_libc_include_path);

        c_source_files.appendAssumeCapacity(.{
            .src_path = try comp.dirs.zig_lib.join(arena, &.{ "libcxx", cxx_src }),
            .extra_flags = cflags.items,
            .cache_exempt_flags = cache_exempt_flags.items,
            .owner = root_mod,
        });
    }

    const sub_compilation = Compilation.create(comp.gpa, arena, .{
        .dirs = comp.dirs.withoutLocalCache(),
        .self_exe_path = comp.self_exe_path,
        .cache_mode = .whole,
        .config = config,
        .root_mod = root_mod,
        .root_name = root_name,
        .thread_pool = comp.thread_pool,
        .libc_installation = comp.libc_installation,
        .emit_bin = .yes_cache,
        .c_source_files = c_source_files.items,
        .verbose_cc = comp.verbose_cc,
        .verbose_link = comp.verbose_link,
        .verbose_air = comp.verbose_air,
        .verbose_llvm_ir = comp.verbose_llvm_ir,
        .verbose_llvm_bc = comp.verbose_llvm_bc,
        .verbose_cimport = comp.verbose_cimport,
        .verbose_llvm_cpu_features = comp.verbose_llvm_cpu_features,
        .clang_passthrough_mode = comp.clang_passthrough_mode,
        .skip_linker_dependencies = true,
    }) catch |err| {
        comp.setMiscFailure(
            .libcxx,
            "unable to build libc++: create compilation failed: {s}",
            .{@errorName(err)},
        );
        return error.SubCompilationFailed;
    };
    defer sub_compilation.destroy();

    comp.updateSubCompilation(sub_compilation, .libcxx, prog_node) catch |err| switch (err) {
        error.SubCompilationFailed => return error.SubCompilationFailed,
        else => |e| {
            comp.setMiscFailure(
                .libcxx,
                "unable to build libc++: compilation failed: {s}",
                .{@errorName(e)},
            );
            return error.SubCompilationFailed;
        },
    };

    assert(comp.libcxx_static_lib == null);
    const crt_file = try sub_compilation.toCrtFile();
    comp.libcxx_static_lib = crt_file;
    comp.queuePrelinkTaskMode(crt_file.full_object_path, &config);
}

pub fn buildLibCxxAbi(comp: *Compilation, prog_node: std.Progress.Node) BuildError!void {
    if (!build_options.have_llvm) {
        return error.ZigCompilerNotBuiltWithLLVMExtensions;
    }

    const tracy = trace(@src());
    defer tracy.end();

    var arena_allocator = std.heap.ArenaAllocator.init(comp.gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const root_name = "c++abi";
    const output_mode = .Lib;
    const link_mode = .static;
    const target = &comp.root_mod.resolved_target.result;

    const cxxabi_include_path = try comp.dirs.zig_lib.join(arena, &.{ "libcxxabi", "include" });
    const cxx_include_path = try comp.dirs.zig_lib.join(arena, &.{ "libcxx", "include" });
    const cxx_src_include_path = try comp.dirs.zig_lib.join(arena, &.{ "libcxx", "src" });

    const optimize_mode = comp.compilerRtOptMode();
    const strip = comp.compilerRtStrip();
    // See the `-fno-exceptions` logic for WASI.
    // The old 32-bit x86 variant of SEH doesn't use tables.
    const unwind_tables: std.builtin.UnwindTables =
        if (target.os.tag == .wasi or (target.cpu.arch == .x86 and target.os.tag == .windows)) .none else .async;

    const config = Compilation.Config.resolve(.{
        .output_mode = output_mode,
        .link_mode = link_mode,
        .resolved_target = comp.root_mod.resolved_target,
        .is_test = false,
        .have_zcu = false,
        .emit_bin = true,
        .root_optimize_mode = optimize_mode,
        .root_strip = strip,
        .link_libc = true,
        .any_unwind_tables = unwind_tables != .none,
        .lto = comp.config.lto,
        .any_sanitize_thread = comp.config.any_sanitize_thread,
    }) catch |err| {
        comp.setMiscFailure(
            .libcxxabi,
            "unable to build libc++abi: resolving configuration failed: {s}",
            .{@errorName(err)},
        );
        return error.SubCompilationFailed;
    };

    const root_mod = Module.create(arena, .{
        .paths = .{
            .root = .zig_lib_root,
            .root_src_path = "",
        },
        .fully_qualified_name = "root",
        .inherited = .{
            .resolved_target = comp.root_mod.resolved_target,
            .strip = strip,
            .stack_check = false,
            .stack_protector = 0,
            .sanitize_c = .off,
            .sanitize_thread = comp.config.any_sanitize_thread,
            .red_zone = comp.root_mod.red_zone,
            .omit_frame_pointer = comp.root_mod.omit_frame_pointer,
            .valgrind = false,
            .optimize_mode = optimize_mode,
            .structured_cfg = comp.root_mod.structured_cfg,
            .unwind_tables = unwind_tables,
            .pic = if (target_util.supports_fpic(target)) true else null,
            .code_model = comp.root_mod.code_model,
        },
        .global = config,
        .cc_argv = &.{},
        .parent = null,
    }) catch |err| {
        comp.setMiscFailure(
            .libcxxabi,
            "unable to build libc++abi: creating module failed: {s}",
            .{@errorName(err)},
        );
        return error.SubCompilationFailed;
    };

    var c_source_files = try std.ArrayList(Compilation.CSourceFile).initCapacity(arena, libcxxabi_files.len);

    for (libcxxabi_files) |cxxabi_src| {
        if (!comp.config.any_non_single_threaded and std.mem.startsWith(u8, cxxabi_src, "src/cxa_thread_atexit.cpp"))
            continue;
        if (target.os.tag == .wasi and
            (std.mem.eql(u8, cxxabi_src, "src/cxa_exception.cpp") or std.mem.eql(u8, cxxabi_src, "src/cxa_personality.cpp")))
            continue;

        var cflags = std.ArrayList([]const u8).init(arena);

        try addCxxArgs(comp, arena, &cflags);

        try cflags.append("-DNDEBUG");
        try cflags.append("-D_LIBCXXABI_BUILDING_LIBRARY");
        if (!comp.config.any_non_single_threaded) {
            try cflags.append("-D_LIBCXXABI_HAS_NO_THREADS");
        }
        if (target.abi.isGnu()) {
            if (target.os.tag != .linux or !(target.os.versionRange().gnuLibCVersion().?.order(.{ .major = 2, .minor = 18, .patch = 0 }) == .lt))
                try cflags.append("-DHAVE___CXA_THREAD_ATEXIT_IMPL");
        }

        if (target.os.tag == .wasi) {
            try cflags.append("-fno-exceptions");
        }

        try cflags.append("-fvisibility=hidden");
        try cflags.append("-fvisibility-inlines-hidden");

        try cflags.append("-nostdinc++");
        try cflags.append("-fstrict-aliasing");
        try cflags.append("-std=c++23");
        try cflags.append("-Wno-user-defined-literals");
        try cflags.append("-Wno-covered-switch-default");
        try cflags.append("-Wno-suggest-override");

        // These depend on only the zig lib directory file path, which is
        // purposefully either in the cache or not in the cache. The decision
        // should not be overridden here.
        var cache_exempt_flags = std.ArrayList([]const u8).init(arena);

        try cache_exempt_flags.append("-I");
        try cache_exempt_flags.append(cxxabi_include_path);

        try cache_exempt_flags.append("-I");
        try cache_exempt_flags.append(cxx_include_path);

        try cache_exempt_flags.append("-I");
        try cache_exempt_flags.append(cxx_src_include_path);

        c_source_files.appendAssumeCapacity(.{
            .src_path = try comp.dirs.zig_lib.join(arena, &.{ "libcxxabi", cxxabi_src }),
            .extra_flags = cflags.items,
            .cache_exempt_flags = cache_exempt_flags.items,
            .owner = root_mod,
        });
    }

    const sub_compilation = Compilation.create(comp.gpa, arena, .{
        .dirs = comp.dirs.withoutLocalCache(),
        .self_exe_path = comp.self_exe_path,
        .cache_mode = .whole,
        .config = config,
        .root_mod = root_mod,
        .root_name = root_name,
        .thread_pool = comp.thread_pool,
        .libc_installation = comp.libc_installation,
        .emit_bin = .yes_cache,
        .c_source_files = c_source_files.items,
        .verbose_cc = comp.verbose_cc,
        .verbose_link = comp.verbose_link,
        .verbose_air = comp.verbose_air,
        .verbose_llvm_ir = comp.verbose_llvm_ir,
        .verbose_llvm_bc = comp.verbose_llvm_bc,
        .verbose_cimport = comp.verbose_cimport,
        .verbose_llvm_cpu_features = comp.verbose_llvm_cpu_features,
        .clang_passthrough_mode = comp.clang_passthrough_mode,
        .skip_linker_dependencies = true,
    }) catch |err| {
        comp.setMiscFailure(
            .libcxxabi,
            "unable to build libc++abi: create compilation failed: {s}",
            .{@errorName(err)},
        );
        return error.SubCompilationFailed;
    };
    defer sub_compilation.destroy();

    comp.updateSubCompilation(sub_compilation, .libcxxabi, prog_node) catch |err| switch (err) {
        error.SubCompilationFailed => return error.SubCompilationFailed,
        else => |e| {
            comp.setMiscFailure(
                .libcxxabi,
                "unable to build libc++abi: compilation failed: {s}",
                .{@errorName(e)},
            );
            return error.SubCompilationFailed;
        },
    };

    assert(comp.libcxxabi_static_lib == null);
    const crt_file = try sub_compilation.toCrtFile();
    comp.libcxxabi_static_lib = crt_file;
    comp.queuePrelinkTaskMode(crt_file.full_object_path, &config);
}

pub fn addCxxArgs(
    comp: *const Compilation,
    arena: std.mem.Allocator,
    cflags: *std.ArrayList([]const u8),
) error{OutOfMemory}!void {
    const target = comp.getTarget();
    const optimize_mode = comp.compilerRtOptMode();

    const abi_version: u2 = if (target.os.tag == .emscripten) 2 else 1;
    try cflags.append(try std.fmt.allocPrint(arena, "-D_LIBCPP_ABI_VERSION={d}", .{
        abi_version,
    }));
    try cflags.append(try std.fmt.allocPrint(arena, "-D_LIBCPP_ABI_NAMESPACE=__{d}", .{
        abi_version,
    }));
    try cflags.append(try std.fmt.allocPrint(arena, "-D_LIBCPP_HAS_{s}THREADS", .{
        if (!comp.config.any_non_single_threaded) "NO_" else "",
    }));
    try cflags.append("-D_LIBCPP_HAS_MONOTONIC_CLOCK");
    try cflags.append("-D_LIBCPP_HAS_TERMINAL");
    try cflags.append(try std.fmt.allocPrint(arena, "-D_LIBCPP_HAS_{s}MUSL_LIBC", .{
        if (!target.abi.isMusl()) "NO_" else "",
    }));
    try cflags.append("-D_LIBCXXABI_DISABLE_VISIBILITY_ANNOTATIONS");
    try cflags.append("-D_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS");
    try cflags.append("-D_LIBCPP_HAS_NO_VENDOR_AVAILABILITY_ANNOTATIONS");
    try cflags.append(try std.fmt.allocPrint(arena, "-D_LIBCPP_HAS_{s}FILESYSTEM", .{
        if (target.os.tag == .wasi) "NO_" else "",
    }));
    try cflags.append("-D_LIBCPP_HAS_RANDOM_DEVICE");
    try cflags.append("-D_LIBCPP_HAS_LOCALIZATION");
    try cflags.append("-D_LIBCPP_HAS_UNICODE");
    try cflags.append("-D_LIBCPP_HAS_WIDE_CHARACTERS");
    try cflags.append("-D_LIBCPP_HAS_NO_STD_MODULES");
    if (target.os.tag == .linux) {
        try cflags.append("-D_LIBCPP_HAS_TIME_ZONE_DATABASE");
    }
    // See libcxx/include/__algorithm/pstl_backends/cpu_backends/backend.h
    // for potentially enabling some fancy features here, which would
    // require corresponding changes in libcxx.zig, as well as
    // Compilation.addCCArgs. This option makes it use serial backend which
    // is simple and works everywhere.
    try cflags.append("-D_LIBCPP_PSTL_BACKEND_SERIAL");
    try cflags.append(switch (optimize_mode) {
        .Debug => "-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_DEBUG",
        .ReleaseFast, .ReleaseSmall => "-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_NONE",
        .ReleaseSafe => "-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST",
    });
    if (target.isGnuLibC()) {
        // glibc 2.16 introduced aligned_alloc
        if (target.os.versionRange().gnuLibCVersion().?.order(.{ .major = 2, .minor = 16, .patch = 0 }) == .lt) {
            try cflags.append("-D_LIBCPP_HAS_NO_LIBRARY_ALIGNED_ALLOCATION");
        }
    }
    try cflags.append("-D_LIBCPP_ENABLE_CXX17_REMOVED_UNEXPECTED_FUNCTIONS");
}
