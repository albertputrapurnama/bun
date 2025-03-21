const ExternalStringList = @import("./install.zig").ExternalStringList;
const Semver = @import("./semver.zig");
const ExternalString = Semver.ExternalString;
const String = Semver.String;
const std = @import("std");
const strings = @import("strings");
const Environment = @import("../env.zig");
const Path = @import("../resolver/resolve_path.zig");
const C = @import("../c.zig");
const Fs = @import("../fs.zig");
const stringZ = @import("../global.zig").stringZ;
const Resolution = @import("./resolution.zig").Resolution;
const bun = @import("../global.zig");
/// Normalized `bin` field in [package.json](https://docs.npmjs.com/cli/v8/configuring-npm/package-json#bin)
/// Can be a:
/// - file path (relative to the package root)
/// - directory (relative to the package root)
/// - map where keys are names of the binaries and values are file paths to the binaries
pub const Bin = extern struct {
    tag: Tag = Tag.none,
    value: Value = Value{ .none = .{} },

    pub fn count(this: Bin, buf: []const u8, extern_strings: []const ExternalString, comptime StringBuilder: type, builder: StringBuilder) u32 {
        switch (this.tag) {
            .file => builder.count(this.value.file.slice(buf)),
            .named_file => {
                builder.count(this.value.named_file[0].slice(buf));
                builder.count(this.value.named_file[1].slice(buf));
            },
            .dir => builder.count(this.value.dir.slice(buf)),
            .map => {
                for (this.value.map.get(extern_strings)) |extern_string| {
                    builder.count(extern_string.slice(buf));
                }
                return this.value.map.len;
            },
            else => {},
        }

        return 0;
    }

    pub fn clone(this: Bin, buf: []const u8, prev_external_strings: []const ExternalString, all_extern_strings: []ExternalString, extern_strings_slice: []ExternalString, comptime StringBuilder: type, builder: StringBuilder) Bin {
        return switch (this.tag) {
            .none => Bin{ .tag = .none, .value = .{ .none = .{} } },
            .file => Bin{
                .tag = .file,
                .value = .{ .file = builder.append(String, this.value.file.slice(buf)) },
            },
            .named_file => Bin{
                .tag = .named_file,
                .value = .{
                    .named_file = [2]String{
                        builder.append(String, this.value.named_file[0].slice(buf)),
                        builder.append(String, this.value.named_file[1].slice(buf)),
                    },
                },
            },
            .dir => Bin{
                .tag = .dir,
                .value = .{ .dir = builder.append(String, this.value.dir.slice(buf)) },
            },
            .map => {
                for (this.value.map.get(prev_external_strings)) |extern_string, i| {
                    extern_strings_slice[i] = builder.append(ExternalString, extern_string.slice(buf));
                }

                return .{
                    .tag = .map,
                    .value = .{ .map = ExternalStringList.init(all_extern_strings, extern_strings_slice) },
                };
            },
        };
    }

    pub const Value = extern union {
        /// no "bin", or empty "bin"
        none: void,

        /// "bin" is a string
        /// ```
        /// "bin": "./bin/foo",
        /// ```
        file: String,

        // Single-entry map
        ///```
        /// "bin": {
        ///     "babel": "./cli.js",
        /// }
        ///```
        named_file: [2]String,

        /// "bin" is a directory
        ///```
        /// "dirs": {
        ///     "bin": "./bin",
        /// }
        ///```
        dir: String,
        // "bin" is a map
        ///```
        /// "bin": {
        ///     "babel": "./cli.js",
        ///     "babel-cli": "./cli.js",
        /// }
        ///```
        map: ExternalStringList,
    };

    pub const Tag = enum(u8) {
        /// no bin field
        none = 0,
        /// "bin" is a string
        /// ```
        /// "bin": "./bin/foo",
        /// ```
        file = 1,

        // Single-entry map
        ///```
        /// "bin": {
        ///     "babel": "./cli.js",
        /// }
        ///```
        named_file = 2,
        /// "bin" is a directory
        ///```
        /// "dirs": {
        ///     "bin": "./bin",
        /// }
        ///```
        dir = 3,
        // "bin" is a map of more than one
        ///```
        /// "bin": {
        ///     "babel": "./cli.js",
        ///     "babel-cli": "./cli.js",
        ///     "webpack-dev-server": "./cli.js",
        /// }
        ///```
        map = 4,
    };

    pub const NamesIterator = struct {
        bin: Bin,
        i: usize = 0,
        done: bool = false,
        dir_iterator: ?std.fs.Dir.Iterator = null,
        package_name: String,
        package_installed_node_modules: std.fs.Dir = std.fs.Dir{ .fd = std.math.maxInt(std.os.fd_t) },
        buf: [bun.MAX_PATH_BYTES]u8 = undefined,
        string_buffer: []const u8,
        extern_string_buf: []const ExternalString,

        fn nextInDir(this: *NamesIterator) !?[]const u8 {
            if (this.done) return null;
            if (this.dir_iterator == null) {
                var target = this.bin.value.dir.slice(this.string_buffer);
                if (strings.hasPrefix(target, "./")) {
                    target = target[2..];
                }
                var parts = [_][]const u8{ this.package_name.slice(this.string_buffer), target };

                var dir = this.package_installed_node_modules;

                var joined = Path.joinStringBuf(&this.buf, &parts, .auto);
                this.buf[joined.len] = 0;
                var joined_: [:0]u8 = this.buf[0..joined.len :0];
                var child_dir = try dir.openDirZ(joined_, .{ .iterate = true });
                this.dir_iterator = child_dir.iterate();
            }

            var iter = &this.dir_iterator.?;
            if (iter.next() catch null) |entry| {
                this.i += 1;
                return entry.name;
            } else {
                this.done = true;
                this.dir_iterator.?.dir.close();
                this.dir_iterator = null;
                return null;
            }
        }

        /// next filename, e.g. "babel" instead of "cli.js"
        pub fn next(this: *NamesIterator) !?[]const u8 {
            switch (this.bin.tag) {
                .file => {
                    if (this.i > 0) return null;
                    this.i += 1;
                    this.done = true;
                    const base = std.fs.path.basename(this.package_name.slice(this.string_buffer));
                    if (strings.hasPrefix(base, "./")) return base[2..];
                    return base;
                },
                .named_file => {
                    if (this.i > 0) return null;
                    this.i += 1;
                    this.done = true;
                    const base = std.fs.path.basename(this.bin.value.named_file[0].slice(this.string_buffer));
                    if (strings.hasPrefix(base, "./")) return base[2..];
                    return base;
                },

                .dir => return try this.nextInDir(),
                .map => {
                    if (this.i >= this.bin.value.map.len) return null;
                    const index = this.i;
                    this.i += 2;
                    this.done = this.i >= this.bin.value.map.len;
                    const base = std.fs.path.basename(
                        this.bin.value.map.get(
                            this.extern_string_buf,
                        )[index].slice(
                            this.string_buffer,
                        ),
                    );
                    if (strings.hasPrefix(base, "./")) return base[2..];
                    return base;
                },
                else => return null,
            }
        }
    };

    pub const Linker = struct {
        bin: Bin,

        package_installed_node_modules: std.os.fd_t = std.math.maxInt(std.os.fd_t),
        root_node_modules_folder: std.os.fd_t = std.math.maxInt(std.os.fd_t),

        /// Used for generating relative paths
        package_name: strings.StringOrTinyString,

        global_bin_dir: std.fs.Dir,
        global_bin_path: stringZ = "",

        string_buf: []const u8,
        extern_string_buf: []const ExternalString,

        err: ?anyerror = null,

        pub var umask: std.os.mode_t = 0;

        pub const Error = error{
            NotImplementedYet,
        } || std.os.SymLinkError || std.os.OpenError || std.os.RealPathError;

        fn unscopedPackageName(name: []const u8) []const u8 {
            if (name[0] != '@') return name;
            var name_ = name;
            name_ = name[1..];
            return name_[(std.mem.indexOfScalar(u8, name_, '/') orelse return name) + 1 ..];
        }

        fn setPermissions(this: *const Linker, target: [:0]const u8) void {
            // we use fchmodat to avoid any issues with current working directory
            _ = C.fchmodat(this.root_node_modules_folder, target, umask | 0o777, 0);
        }

        // It is important that we use symlinkat(2) with relative paths instead of symlink()
        // That way, if you move your node_modules folder around, the symlinks in .bin still work
        // If we used absolute paths for the symlinks, you'd end up with broken symlinks
        pub fn link(this: *Linker, link_global: bool) void {
            var target_buf: [bun.MAX_PATH_BYTES]u8 = undefined;
            var dest_buf: [bun.MAX_PATH_BYTES]u8 = undefined;
            var from_remain: []u8 = &target_buf;
            var remain: []u8 = &dest_buf;

            if (!link_global) {
                target_buf[0..".bin/".len].* = ".bin/".*;
                from_remain = target_buf[".bin/".len..];
                dest_buf[0.."../".len].* = "../".*;
                remain = dest_buf["../".len..];
            } else {
                if (this.global_bin_dir.fd >= std.math.maxInt(std.os.fd_t)) {
                    this.err = error.MissingGlobalBinDir;
                    return;
                }

                @memcpy(&target_buf, this.global_bin_path.ptr, this.global_bin_path.len);
                from_remain = target_buf[this.global_bin_path.len..];
                from_remain[0] = std.fs.path.sep;
                from_remain = from_remain[1..];
                const abs = std.os.getFdPath(this.root_node_modules_folder, &dest_buf) catch |err| {
                    this.err = err;
                    return;
                };
                remain = remain[abs.len..];
                remain[0] = std.fs.path.sep;
                remain = remain[1..];

                this.root_node_modules_folder = this.global_bin_dir.fd;
            }

            const name = this.package_name.slice();
            std.mem.copy(u8, remain, name);
            remain = remain[name.len..];
            remain[0] = std.fs.path.sep;
            remain = remain[1..];

            if (comptime Environment.isWindows) {
                @compileError("Bin.Linker.link() needs to be updated to generate .cmd files on Windows");
            }

            switch (this.bin.tag) {
                .none => {
                    if (comptime Environment.isDebug) {
                        unreachable;
                    }
                },
                .file => {
                    var target = this.bin.value.file.slice(this.string_buf);

                    if (strings.hasPrefix(target, "./")) {
                        target = target[2..];
                    }
                    std.mem.copy(u8, remain, target);
                    remain = remain[target.len..];
                    remain[0] = 0;
                    const target_len = @ptrToInt(remain.ptr) - @ptrToInt(&dest_buf);
                    remain = remain[1..];

                    var target_path: [:0]u8 = dest_buf[0..target_len :0];
                    // we need to use the unscoped package name here
                    // this is why @babel/parser would fail to link
                    const unscoped_name = unscopedPackageName(name);
                    std.mem.copy(u8, from_remain, unscoped_name);
                    from_remain = from_remain[unscoped_name.len..];
                    from_remain[0] = 0;
                    var dest_path: [:0]u8 = target_buf[0 .. @ptrToInt(from_remain.ptr) - @ptrToInt(&target_buf) :0];

                    std.os.symlinkatZ(target_path, this.root_node_modules_folder, dest_path) catch |err| {
                        // Silently ignore PathAlreadyExists
                        // Most likely, the symlink was already created by another package
                        if (err == error.PathAlreadyExists) {
                            this.setPermissions(dest_path);
                            return;
                        }

                        this.err = err;
                    };
                    this.setPermissions(dest_path);
                },
                .named_file => {
                    var target = this.bin.value.named_file[1].slice(this.string_buf);
                    if (strings.hasPrefix(target, "./")) {
                        target = target[2..];
                    }
                    std.mem.copy(u8, remain, target);
                    remain = remain[target.len..];
                    remain[0] = 0;
                    const target_len = @ptrToInt(remain.ptr) - @ptrToInt(&dest_buf);
                    remain = remain[1..];

                    var target_path: [:0]u8 = dest_buf[0..target_len :0];
                    var name_to_use = this.bin.value.named_file[0].slice(this.string_buf);
                    std.mem.copy(u8, from_remain, name_to_use);
                    from_remain = from_remain[name_to_use.len..];
                    from_remain[0] = 0;
                    var dest_path: [:0]u8 = target_buf[0 .. @ptrToInt(from_remain.ptr) - @ptrToInt(&target_buf) :0];

                    std.os.symlinkatZ(target_path, this.root_node_modules_folder, dest_path) catch |err| {
                        // Silently ignore PathAlreadyExists
                        // Most likely, the symlink was already created by another package
                        if (err == error.PathAlreadyExists) {
                            this.setPermissions(dest_path);
                            return;
                        }

                        this.err = err;
                    };
                    this.setPermissions(dest_path);
                },
                .map => {
                    var extern_string_i: u32 = this.bin.value.map.off;
                    const end = this.bin.value.map.len + extern_string_i;
                    const _from_remain = from_remain;
                    const _remain = remain;
                    while (extern_string_i < end) : (extern_string_i += 2) {
                        from_remain = _from_remain;
                        remain = _remain;
                        const name_in_terminal = this.extern_string_buf[extern_string_i];
                        const name_in_filesystem = this.extern_string_buf[extern_string_i + 1];

                        var target = name_in_filesystem.slice(this.string_buf);
                        if (strings.hasPrefix(target, "./")) {
                            target = target[2..];
                        }
                        std.mem.copy(u8, remain, target);
                        remain = remain[target.len..];
                        remain[0] = 0;
                        const target_len = @ptrToInt(remain.ptr) - @ptrToInt(&dest_buf);
                        remain = remain[1..];

                        var target_path: [:0]u8 = dest_buf[0..target_len :0];
                        var name_to_use = name_in_terminal.slice(this.string_buf);
                        std.mem.copy(u8, from_remain, name_to_use);
                        from_remain = from_remain[name_to_use.len..];
                        from_remain[0] = 0;
                        var dest_path: [:0]u8 = target_buf[0 .. @ptrToInt(from_remain.ptr) - @ptrToInt(&target_buf) :0];

                        std.os.symlinkatZ(target_path, this.root_node_modules_folder, dest_path) catch |err| {
                            // Silently ignore PathAlreadyExists
                            // Most likely, the symlink was already created by another package
                            if (err == error.PathAlreadyExists) {
                                this.setPermissions(dest_path);
                                continue;
                            }

                            this.err = err;
                        };
                        this.setPermissions(dest_path);
                    }
                },
                .dir => {
                    var target = this.bin.value.dir.slice(this.string_buf);
                    if (strings.hasPrefix(target, "./")) {
                        target = target[2..];
                    }

                    var parts = [_][]const u8{ name, target };

                    std.mem.copy(u8, remain, target);
                    remain = remain[target.len..];

                    var dir = std.fs.Dir{ .fd = this.package_installed_node_modules };

                    var joined = Path.joinStringBuf(&target_buf, &parts, .auto);
                    @intToPtr([*]u8, @ptrToInt(joined.ptr))[joined.len] = 0;
                    var joined_: [:0]const u8 = joined.ptr[0..joined.len :0];
                    var child_dir = dir.openDirZ(joined_, .{ .iterate = true }) catch |err| {
                        this.err = err;
                        return;
                    };
                    defer child_dir.close();

                    var iter = child_dir.iterate();

                    var basedir_path = std.os.getFdPath(child_dir.fd, &target_buf) catch |err| {
                        this.err = err;
                        return;
                    };
                    target_buf[basedir_path.len] = std.fs.path.sep;
                    var target_buf_remain = target_buf[basedir_path.len + 1 ..];
                    var prev_target_buf_remain = target_buf_remain;

                    while (iter.next() catch null) |entry_| {
                        const entry: std.fs.Dir.Entry = entry_;
                        switch (entry.kind) {
                            std.fs.Dir.Entry.Kind.SymLink, std.fs.Dir.Entry.Kind.File => {
                                target_buf_remain = prev_target_buf_remain;
                                std.mem.copy(u8, target_buf_remain, entry.name);
                                target_buf_remain = target_buf_remain[entry.name.len..];
                                target_buf_remain[0] = 0;
                                var from_path: [:0]u8 = target_buf[0 .. @ptrToInt(target_buf_remain.ptr) - @ptrToInt(&target_buf) :0];
                                var to_path = if (!link_global)
                                    std.fmt.bufPrintZ(&dest_buf, ".bin/{s}", .{entry.name}) catch continue
                                else
                                    std.fmt.bufPrintZ(&dest_buf, "{s}", .{entry.name}) catch continue;

                                std.os.symlinkatZ(
                                    from_path,
                                    this.root_node_modules_folder,
                                    to_path,
                                ) catch |err| {

                                    // Silently ignore PathAlreadyExists
                                    // Most likely, the symlink was already created by another package
                                    if (err == error.PathAlreadyExists) {
                                        this.setPermissions(to_path);
                                        continue;
                                    }

                                    this.err = err;
                                    continue;
                                };
                                this.setPermissions(to_path);
                            },
                            else => {},
                        }
                    }
                },
            }
        }

        pub fn unlink(this: *Linker, link_global: bool) void {
            var target_buf: [bun.MAX_PATH_BYTES]u8 = undefined;
            var dest_buf: [bun.MAX_PATH_BYTES]u8 = undefined;
            var from_remain: []u8 = &target_buf;
            var remain: []u8 = &dest_buf;

            if (!link_global) {
                target_buf[0..".bin/".len].* = ".bin/".*;
                from_remain = target_buf[".bin/".len..];
                dest_buf[0.."../".len].* = "../".*;
                remain = dest_buf["../".len..];
            } else {
                if (this.global_bin_dir.fd >= std.math.maxInt(std.os.fd_t)) {
                    this.err = error.MissingGlobalBinDir;
                    return;
                }

                @memcpy(&target_buf, this.global_bin_path.ptr, this.global_bin_path.len);
                from_remain = target_buf[this.global_bin_path.len..];
                from_remain[0] = std.fs.path.sep;
                from_remain = from_remain[1..];
                const abs = std.os.getFdPath(this.root_node_modules_folder, &dest_buf) catch |err| {
                    this.err = err;
                    return;
                };
                remain = remain[abs.len..];
                remain[0] = std.fs.path.sep;
                remain = remain[1..];

                this.root_node_modules_folder = this.global_bin_dir.fd;
            }

            const name = this.package_name.slice();
            std.mem.copy(u8, remain, name);
            remain = remain[name.len..];
            remain[0] = std.fs.path.sep;
            remain = remain[1..];

            if (comptime Environment.isWindows) {
                @compileError("Bin.Linker.unlink() needs to be updated to generate .cmd files on Windows");
            }

            switch (this.bin.tag) {
                .none => {
                    if (comptime Environment.isDebug) {
                        unreachable;
                    }
                },
                .file => {
                    // we need to use the unscoped package name here
                    // this is why @babel/parser would fail to link
                    const unscoped_name = unscopedPackageName(name);
                    std.mem.copy(u8, from_remain, unscoped_name);
                    from_remain = from_remain[unscoped_name.len..];
                    from_remain[0] = 0;
                    var dest_path: [:0]u8 = target_buf[0 .. @ptrToInt(from_remain.ptr) - @ptrToInt(&target_buf) :0];

                    std.os.unlinkatZ(this.root_node_modules_folder, dest_path, 0) catch {};
                },
                .named_file => {
                    var name_to_use = this.bin.value.named_file[0].slice(this.string_buf);
                    std.mem.copy(u8, from_remain, name_to_use);
                    from_remain = from_remain[name_to_use.len..];
                    from_remain[0] = 0;
                    var dest_path: [:0]u8 = target_buf[0 .. @ptrToInt(from_remain.ptr) - @ptrToInt(&target_buf) :0];

                    std.os.unlinkatZ(this.root_node_modules_folder, dest_path, 0) catch {};
                },
                .map => {
                    var extern_string_i: u32 = this.bin.value.map.off;
                    const end = this.bin.value.map.len + extern_string_i;
                    const _from_remain = from_remain;
                    const _remain = remain;
                    while (extern_string_i < end) : (extern_string_i += 2) {
                        from_remain = _from_remain;
                        remain = _remain;
                        const name_in_terminal = this.extern_string_buf[extern_string_i];
                        const name_in_filesystem = this.extern_string_buf[extern_string_i + 1];

                        var target = name_in_filesystem.slice(this.string_buf);
                        if (strings.hasPrefix(target, "./")) {
                            target = target[2..];
                        }
                        std.mem.copy(u8, remain, target);
                        remain = remain[target.len..];
                        remain[0] = 0;
                        remain = remain[1..];

                        var name_to_use = name_in_terminal.slice(this.string_buf);
                        std.mem.copy(u8, from_remain, name_to_use);
                        from_remain = from_remain[name_to_use.len..];
                        from_remain[0] = 0;
                        var dest_path: [:0]u8 = target_buf[0 .. @ptrToInt(from_remain.ptr) - @ptrToInt(&target_buf) :0];

                        std.os.unlinkatZ(this.root_node_modules_folder, dest_path, 0) catch {};
                    }
                },
                .dir => {
                    var target = this.bin.value.dir.slice(this.string_buf);
                    if (strings.hasPrefix(target, "./")) {
                        target = target[2..];
                    }

                    var parts = [_][]const u8{ name, target };

                    std.mem.copy(u8, remain, target);
                    remain = remain[target.len..];

                    var dir = std.fs.Dir{ .fd = this.package_installed_node_modules };

                    var joined = Path.joinStringBuf(&target_buf, &parts, .auto);
                    @intToPtr([*]u8, @ptrToInt(joined.ptr))[joined.len] = 0;
                    var joined_: [:0]const u8 = joined.ptr[0..joined.len :0];
                    var child_dir = dir.openDirZ(joined_, .{ .iterate = true }) catch |err| {
                        this.err = err;
                        return;
                    };
                    defer child_dir.close();

                    var iter = child_dir.iterate();

                    var basedir_path = std.os.getFdPath(child_dir.fd, &target_buf) catch |err| {
                        this.err = err;
                        return;
                    };
                    target_buf[basedir_path.len] = std.fs.path.sep;
                    var target_buf_remain = target_buf[basedir_path.len + 1 ..];
                    var prev_target_buf_remain = target_buf_remain;

                    while (iter.next() catch null) |entry_| {
                        const entry: std.fs.Dir.Entry = entry_;
                        switch (entry.kind) {
                            std.fs.Dir.Entry.Kind.SymLink, std.fs.Dir.Entry.Kind.File => {
                                target_buf_remain = prev_target_buf_remain;
                                std.mem.copy(u8, target_buf_remain, entry.name);
                                target_buf_remain = target_buf_remain[entry.name.len..];
                                target_buf_remain[0] = 0;
                                var to_path = if (!link_global)
                                    std.fmt.bufPrintZ(&dest_buf, ".bin/{s}", .{entry.name}) catch continue
                                else
                                    std.fmt.bufPrintZ(&dest_buf, "{s}", .{entry.name}) catch continue;

                                std.os.unlinkatZ(
                                    this.root_node_modules_folder,
                                    to_path,
                                    0,
                                ) catch continue;
                            },
                            else => {},
                        }
                    }
                },
            }
        }
    };
};
