const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
    @cInclude("unistd.h");
    @cInclude("pwd.h");
    @cInclude("sys/stat.h");
});

const SCRIPT_NAME = "turkishvan-bsd";
const VERSION = "zig-0.12-v1";
const BEGIN_MARK = "# BEGIN turkishvan-bsd managed block";
const END_MARK = "# END turkishvan-bsd managed block";

const EXIT_SUCCESS: u8 = 0;
const EXIT_SUCCESS_REBOOT: u8 = 10;
const EXIT_USAGE: u8 = 20;
const EXIT_PLATFORM: u8 = 30;
const EXIT_PACKAGE: u8 = 40;
const EXIT_CONFIG: u8 = 50;
const EXIT_VALIDATION: u8 = 60;
const EXIT_LOCK: u8 = 70;
const EXIT_ROLLBACK: u8 = 80;
const EXIT_INTERNAL: u8 = 90;

const AppError = error{Fatal};

const Args = struct {
    username: []const u8,
    keyboard: []const u8,
    resume: bool = true,
    force: bool = false,
    verbose: bool = false,
    skip_upgrade: bool = false,
    immediate_xdm: bool = false,
};

const UserInfo = struct {
    uid: u32,
    gid: u32,
    home: []const u8,
};

const HardwarePlan = struct {
    gpu_plan: []const u8 = "unknown-generic",
    audio_profile: []const u8 = "no-detected-audio",
    audio_device_count: usize = 0,
    audio_selected_unit: []const u8 = "",
    audio_default_reason: []const u8 = "",
    backlight_manageable: bool = false,
};

const PackageSnapshot = struct {
    pkg_xorg: []const u8 = "",
    pkg_input_libinput: []const u8 = "",
    pkg_input_evdev: []const u8 = "",
    pkg_xdm: []const u8 = "",
    pkg_gnustep: []const u8 = "",
    pkg_gnustep_back: []const u8 = "",
    pkg_windowmaker: []const u8 = "",
    pkg_terminal: []const u8 = "",
    terminal_bin: []const u8 = "xterm",
    pkg_editor: []const u8 = "",
    pkg_browser: []const u8 = "",
    pkg_curl: []const u8 = "curl",
    pkg_wget: []const u8 = "wget",
    pkg_rsync: []const u8 = "rsync",
    pkg_git: []const u8 = "git",
    pkg_office: []const u8 = "",
    pkg_pdfview: []const u8 = "",
    pkg_filemgr: []const u8 = "",
    pkg_sysmon: []const u8 = "",
    pkg_zip: []const u8 = "zip",
    pkg_unzip: []const u8 = "unzip",
    pkg_p7zip: []const u8 = "p7zip",
    pkg_clip: []const u8 = "",
    pkg_fonts: []const u8 = "",
    pkg_video: []const u8 = "",
    pkg_audio: []const u8 = "",
    pkg_transcoder: []const u8 = "",
    pkg_audio_util: []const u8 = "",
    pkg_image: []const u8 = "",
    pkg_screenshot: []const u8 = "",
    timestamp: []const u8 = "",
};

const HardwareSnapshot = struct {
    snapshot_dir: []const u8 = "",
    discovery_utc: []const u8 = "",
    target_user: []const u8 = "",
    target_home: []const u8 = "",
    gpu_plan: []const u8 = "unknown-generic",
    audio_profile: []const u8 = "no-detected-audio",
    audio_device_count: usize = 0,
    audio_selected_unit: []const u8 = "",
    audio_default_reason: []const u8 = "",
    backlight_manageable: bool = false,
};

const Paths = struct {
    run_id: []const u8,
    base_log_dir: []const u8,
    base_state_dir: []const u8,
    base_backup_dir: []const u8,
    logfile: []const u8,
    lockfile: []const u8,
    checkpoint_file: []const u8,
    last_run_file: []const u8,
    package_snapshot: []const u8,
    hardware_snapshot: []const u8,
    invocation_file: []const u8,
    change_manifest: []const u8,
    rollback_manifest: []const u8,
    reboot_required: []const u8,
    final_summary: []const u8,
    discovery_dir: []const u8,

    fn init(alloc: std.mem.Allocator, rid: []const u8) !Paths {
        const base_log_dir = try alloc.dupe(u8, "/var/log/" ++ SCRIPT_NAME);
        const base_state_dir = try alloc.dupe(u8, "/var/db/" ++ SCRIPT_NAME);
        const base_backup_dir = try alloc.dupe(u8, "/var/backups/" ++ SCRIPT_NAME);
        return .{
            .run_id = rid,
            .base_log_dir = base_log_dir,
            .base_state_dir = base_state_dir,
            .base_backup_dir = base_backup_dir,
            .logfile = try std.fmt.allocPrint(alloc, "{s}/{s}.log", .{ base_log_dir, rid }),
            .lockfile = try std.fmt.allocPrint(alloc, "{s}/run.lock", .{base_state_dir}),
            .checkpoint_file = try std.fmt.allocPrint(alloc, "{s}/checkpoint.state", .{base_state_dir}),
            .last_run_file = try std.fmt.allocPrint(alloc, "{s}/last-run.json", .{base_state_dir}),
            .package_snapshot = try std.fmt.allocPrint(alloc, "{s}/package.snapshot.json", .{base_state_dir}),
            .hardware_snapshot = try std.fmt.allocPrint(alloc, "{s}/hardware.snapshot.json", .{base_state_dir}),
            .invocation_file = try std.fmt.allocPrint(alloc, "{s}/invocation.json", .{base_state_dir}),
            .change_manifest = try std.fmt.allocPrint(alloc, "{s}/change.manifest.jsonl", .{base_state_dir}),
            .rollback_manifest = try std.fmt.allocPrint(alloc, "{s}/rollback.manifest.jsonl", .{base_state_dir}),
            .reboot_required = try std.fmt.allocPrint(alloc, "{s}/reboot.required", .{base_state_dir}),
            .final_summary = try std.fmt.allocPrint(alloc, "{s}/final.summary.json", .{base_state_dir}),
            .discovery_dir = try std.fmt.allocPrint(alloc, "{s}/discovery", .{base_state_dir}),
        };
    }
};

const Logger = struct {
    alloc: std.mem.Allocator,
    logfile: []const u8,
    verbose: bool,

    fn log(self: *Logger, level: []const u8, phase: []const u8, step: []const u8, message: []const u8) !void {
        if (std.mem.eql(u8, level, "DEBUG") and !self.verbose) return;
        var ts_buf: [32]u8 = undefined;
        const ts = isoTimestamp(&ts_buf);
        const line = try std.fmt.allocPrint(self.alloc, "{s} {s} {s} {s} {s}\n", .{ ts, level, phase, step, message });

        var stdout_writer = std.io.getStdOut().writer();
        try stdout_writer.writeAll(line);

        var file = std.fs.openFileAbsolute(self.logfile, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try std.fs.createFileAbsolute(self.logfile, .{ .read = true, .truncate = false }),
            else => return err,
        };
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll(line);
        try file.sync();
    }
};

const RunLock = struct {
    path: []const u8,
    hostname: []const u8,
    acquired: bool = false,

    fn acquire(self: *RunLock, app: *App) !void {
        try ensureDir(std.fs.path.dirname(self.path).?);

        const payload = .{
            .pid = std.posix.getpid(),
            .timestamp = try app.alloc.dupe(u8, app.nowStamp()),
            .hostname = self.hostname,
        };

        while (true) {
            var file = std.fs.createFileAbsolute(self.path, .{ .read = true, .exclusive = true }) catch |err| switch (err) {
                error.PathAlreadyExists, error.FileAlreadyExists => {
                    const stale = try self.handleExisting(app);
                    if (stale) continue;
                    return app.fail(EXIT_LOCK, "lock", "active lock held; refusing concurrent execution", .{});
                },
                else => return err,
            };
            defer file.close();

            var list = std.ArrayList(u8).init(app.alloc);
            try std.json.stringify(payload, .{ .whitespace = .indent_2 }, list.writer());
            try list.writer().writeByte('\n');
            try file.writeAll(list.items);
            try file.sync();
            self.acquired = true;
            try app.logger.log("OK", "phase0", "lock", try std.fmt.allocPrint(app.alloc, "lock acquired at {s}", .{self.path}));
            return;
        }
    }

    fn handleExisting(self: *RunLock, app: *App) !bool {
        const text = app.readText(self.path) catch |err| switch (err) {
            error.FileNotFound => return true,
            else => return err,
        };

        var parsed = std.json.parseFromSlice(std.json.Value, app.alloc, text, .{}) catch {
            try app.logger.log("WARN", "phase0", "lock", try std.fmt.allocPrint(app.alloc, "stale lock detected at {s}; removing unreadable lock", .{self.path}));
            std.fs.deleteFileAbsolute(self.path) catch {};
            return true;
        };
        defer parsed.deinit();

        var pid: i32 = -1;
        var host: []const u8 = "";
        if (parsed.value == .object) {
            if (parsed.value.object.get("pid")) |v| {
                switch (v) {
                    .integer => |n| pid = @intCast(n),
                    .string => |s| pid = std.fmt.parseInt(i32, s, 10) catch -1,
                    else => {},
                }
            }
            if (parsed.value.object.get("hostname")) |v| {
                if (v == .string) host = v.string;
            }
        }

        var stale = true;
        if (pid > 0 and std.mem.eql(u8, host, self.hostname)) {
            if (c.kill(pid, 0) == 0) stale = false;
        }

        if (stale) {
            try app.logger.log("WARN", "phase0", "lock", try std.fmt.allocPrint(app.alloc, "stale lock detected at {s}; removing", .{self.path}));
            std.fs.deleteFileAbsolute(self.path) catch {};
            return true;
        }

        try app.logger.log("ERROR", "phase0", "lock", try std.fmt.allocPrint(app.alloc, "active lock held by pid {d} on {s}", .{ pid, host }));
        return false;
    }

    fn release(self: *RunLock) void {
        if (!self.acquired) return;
        std.fs.deleteFileAbsolute(self.path) catch {};
        self.acquired = false;
    }
};

const CommandResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    fn exitCode(self: CommandResult) i32 {
        return switch (self.term) {
            .Exited => |code| @intCast(code),
            else => 255,
        };
    }
};

const AudioDevice = struct {
    unit: []const u8,
    desc: []const u8,
    kind: []const u8,
    score: i32,
    reason: []const u8,
};

const App = struct {
    alloc: std.mem.Allocator,
    env_map: std.process.EnvMap,
    args: Args,
    paths: Paths,
    logger: Logger,
    lock: RunLock,
    hostname: []const u8,
    target_home: []const u8,
    target_uid: u32,
    target_gid: u32,
    need_relogin: bool,
    need_reboot: bool,
    group_changed: bool,
    xdm_mode: []const u8,
    hardware: HardwarePlan,
    packages: PackageSnapshot,
    deferred_keyboard_validate: bool,
    keyboard_validation_source: []const u8,
    completed_phase: u32,
    phase: []const u8,
    fatal_code: u8,
    fatal_step: []const u8,
    fatal_message: []const u8,

    fn init(alloc: std.mem.Allocator, args: Args) !App {
        const rid = try makeRunId(alloc);
        const paths = try Paths.init(alloc, rid);
        try ensureDir(paths.base_log_dir);
        try ensureDir(paths.base_state_dir);
        try ensureDir(paths.base_backup_dir);

        var env_map = try std.process.getEnvMap(alloc);
        const current_path = env_map.get("PATH") orelse "";
        const new_path = try std.fmt.allocPrint(alloc, "/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin:{s}", .{current_path});
        try env_map.put("PATH", new_path);

        const hostname = try getHostnameShort(alloc);
        const logger = Logger{ .alloc = alloc, .logfile = paths.logfile, .verbose = args.verbose };

        var app = App{
            .alloc = alloc,
            .env_map = env_map,
            .args = args,
            .paths = paths,
            .logger = logger,
            .lock = RunLock{ .path = paths.lockfile, .hostname = hostname },
            .hostname = hostname,
            .target_home = "/",
            .target_uid = 0,
            .target_gid = 0,
            .need_relogin = false,
            .need_reboot = false,
            .group_changed = false,
            .xdm_mode = "SUCCESS_PENDING_REBOOT",
            .hardware = .{},
            .packages = .{},
            .deferred_keyboard_validate = false,
            .keyboard_validation_source = "none",
            .completed_phase = 0,
            .phase = "bootstrap",
            .fatal_code = EXIT_INTERNAL,
            .fatal_step = "unexpected",
            .fatal_message = "unexpected internal error",
        };
        app.completed_phase = try app.loadCompletedPhase();
        return app;
    }

    fn run(self: *App) !u8 {
        self.phase = "phase0";
        try self.logger.log("INFO", self.phase, "bootstrap-logging", try std.fmt.allocPrint(self.alloc, "state directories ready; starting run {s}", .{self.paths.run_id}));
        try self.lock.acquire(self);
        try self.resetRunManifests();
        try self.writeJsonFile(self.paths.invocation_file, .{
            .run_id = self.paths.run_id,
            .timestamp = self.nowStamp(),
            .username = self.args.username,
            .keyboard = self.args.keyboard,
            .resume = self.args.resume,
            .force = self.args.force,
            .verbose = self.args.verbose,
            .skip_upgrade = self.args.skip_upgrade,
            .immediate_xdm = self.args.immediate_xdm,
        });
        try self.logger.log("INFO", self.phase, "checkpoint", try std.fmt.allocPrint(self.alloc, "last completed phase is {d}", .{self.completed_phase}));

        try self.phasePreflight();
        try self.phaseDiscovery();
        try self.phaseTuning();
        try self.phasePkgReady();
        try self.phaseHardwarePlan();
        try self.phasePackageResolution();
        try self.phaseSystemConfiguration();
        try self.phaseX11Configuration();
        try self.phaseUserProvisioning();
        try self.phaseAudioConfiguration();
        try self.phaseVideoDisplayConfiguration();
        try self.phaseXdmEnablement();
        try self.finalValidation();

        const code: u8 = if (self.need_reboot or self.need_relogin or self.group_changed or std.mem.eql(u8, self.xdm_mode, "SUCCESS_PENDING_REBOOT")) EXIT_SUCCESS_REBOOT else EXIT_SUCCESS;
        try self.logger.log("INFO", "final", "summary", try std.fmt.allocPrint(self.alloc, "run completed with exit code {d}; logfile {s}; xdm {s}; relogin {}; reboot {}", .{ code, self.paths.logfile, self.xdm_mode, self.need_relogin, self.need_reboot }));
        return code;
    }

    fn fail(self: *App, code: u8, step: []const u8, comptime fmt: []const u8, args: anytype) AppError {
        self.fatal_code = code;
        self.fatal_step = step;
        self.fatal_message = std.fmt.allocPrint(self.alloc, fmt, args) catch "fatal error";
        return error.Fatal;
    }

    fn nowStamp(self: *App) []const u8 {
        _ = self;
        var buf: [32]u8 = undefined;
        const ts = isoTimestamp(&buf);
        return self.alloc.dupe(u8, ts) catch ts;
    }

    fn loadCompletedPhase(self: *App) !u32 {
        const text = self.readText(self.paths.checkpoint_file) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        const Parsed = struct {
            phase: u32 = 0,
        };
        var parsed = std.json.parseFromSlice(Parsed, self.alloc, text, .{ .ignore_unknown_fields = true }) catch return 0;
        defer parsed.deinit();
        return parsed.value.phase;
    }

    fn saveCheckpoint(self: *App, phase_num: u32, name: []const u8) !void {
        try self.writeJsonFile(self.paths.checkpoint_file, .{
            .phase = phase_num,
            .name = name,
            .run_id = self.paths.run_id,
            .timestamp = self.nowStamp(),
        });
        self.completed_phase = phase_num;
    }

    fn resetRunManifests(self: *App) !void {
        try self.writeAtomicText(self.paths.change_manifest, "");
        try self.writeAtomicText(self.paths.rollback_manifest, "");
        std.fs.deleteFileAbsolute(self.paths.reboot_required) catch {};
    }

    fn shouldSkipByCheckpoint(self: *App, phase_num: u32) bool {
        return self.args.resume and self.completed_phase >= phase_num;
    }

    fn runCmd(self: *App, argv: []const []const u8) !CommandResult {
        if (self.args.verbose) {
            const joined = try std.mem.join(self.alloc, " ", argv);
            try self.logger.log("DEBUG", self.phase, "command", joined);
        }
        const result = try std.process.Child.run(.{
            .allocator = self.alloc,
            .argv = argv,
            .env_map = &self.env_map,
            .max_output_bytes = 64 * 1024 * 1024,
        });
        return .{
            .stdout = result.stdout,
            .stderr = result.stderr,
            .term = result.term,
        };
    }

    fn readText(self: *App, path: []const u8) ![]const u8 {
        return try std.fs.cwd().readFileAlloc(self.alloc, path, 128 * 1024 * 1024);
    }

    fn writeAtomicText(self: *App, path: []const u8, content: []const u8) !void {
        const tmp = try std.fmt.allocPrint(self.alloc, "{s}.tmp.{s}", .{ path, self.paths.run_id });
        var file = try std.fs.createFileAbsolute(tmp, .{ .read = true, .truncate = true, .mode = 0o644 });
        defer file.close();
        try file.writeAll(content);
        try file.sync();
        try std.fs.renameAbsolute(tmp, path);
    }

    fn writeAtomicTextMode(self: *App, path: []const u8, content: []const u8, mode: u32) !void {
        const tmp = try std.fmt.allocPrint(self.alloc, "{s}.tmp.{s}", .{ path, self.paths.run_id });
        var file = try std.fs.createFileAbsolute(tmp, .{ .read = true, .truncate = true, .mode = mode });
        defer file.close();
        try file.writeAll(content);
        try file.sync();
        try std.fs.renameAbsolute(tmp, path);
        try chmodPath(path, mode);
    }

    fn writeJsonFile(self: *App, path: []const u8, value: anytype) !void {
        var list = std.ArrayList(u8).init(self.alloc);
        try std.json.stringify(value, .{ .whitespace = .indent_2 }, list.writer());
        try list.writer().writeByte('\n');
        try self.writeAtomicText(path, list.items);
    }

    fn appendJsonl(self: *App, path: []const u8, value: anytype) !void {
        var list = std.ArrayList(u8).init(self.alloc);
        try std.json.stringify(value, .{}, list.writer());
        try list.writer().writeByte('\n');

        var file = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try std.fs.createFileAbsolute(path, .{ .read = true, .truncate = false }),
            else => return err,
        };
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll(list.items);
        try file.sync();
    }

    fn backupFile(self: *App, path: []const u8) !?[]const u8 {
        if (!fileExists(path)) return null;
        const encoded = try encodePath(self.alloc, path);
        const stamp = try makeCompactTimestamp(self.alloc);
        const backup = try std.fmt.allocPrint(self.alloc, "{s}/{s}.{s}.{s}.bak", .{ self.paths.base_backup_dir, encoded, stamp, self.paths.run_id });
        const res = try self.runCmd(&.{ "cp", "-p", path, backup });
        if (res.exitCode() != 0) return self.fail(EXIT_CONFIG, "backup", "failed to back up {s} to {s}", .{ path, backup });
        try self.appendJsonl(self.paths.rollback_manifest, .{ .path = path, .backup = backup, .run_id = self.paths.run_id });
        try self.logger.log("INFO", self.phase, "backup", try std.fmt.allocPrint(self.alloc, "backup created at {s}", .{backup}));
        return backup;
    }

    fn restoreBackup(self: *App, original: []const u8, backup: ?[]const u8) void {
        if (backup) |b| {
            const res = self.runCmd(&.{ "cp", "-p", b, original }) catch return;
            if (res.exitCode() == 0) {
                self.logger.log("WARN", self.phase, "rollback", std.fmt.allocPrint(self.alloc, "restored {s} from {s}", .{ original, b }) catch "restored backup") catch {};
            }
        }
    }

    fn recordChange(self: *App, path: []const u8, action: []const u8, detail: []const u8) !void {
        try self.appendJsonl(self.paths.change_manifest, .{
            .path = path,
            .action = action,
            .detail = detail,
            .timestamp = self.nowStamp(),
            .run_id = self.paths.run_id,
        });
    }

    fn hasManagedBlock(self: *App, path: []const u8) bool {
        const text = self.readText(path) catch return false;
        return std.mem.indexOf(u8, text, BEGIN_MARK) != null;
    }

    fn updateManagedBlock(self: *App, path: []const u8, body_lines: []const []const u8) !bool {
        var block = std.ArrayList(u8).init(self.alloc);
        try block.writer().print("{s}\n# generated by {s} on {s}\n", .{ BEGIN_MARK, SCRIPT_NAME, self.nowStamp() });
        for (body_lines) |line| {
            try block.writer().print("{s}\n", .{line});
        }
        try block.writer().print("{s}\n", .{END_MARK});

        const current = self.readText(path) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };

        var merged = std.ArrayList(u8).init(self.alloc);
        const begin_idx = std.mem.indexOf(u8, current, BEGIN_MARK);
        const end_idx = std.mem.indexOf(u8, current, END_MARK);
        if (begin_idx != null and end_idx != null and end_idx.? >= begin_idx.?) {
            try merged.writer().writeAll(current[0..begin_idx.?]);
            if (begin_idx.? > 0 and current[begin_idx.? - 1] != '\n') try merged.writer().writeByte('\n');
            try merged.writer().writeAll(block.items);
            const after = end_idx.? + END_MARK.len;
            if (after < current.len and current[after] == '\n') {
                try merged.writer().writeAll(current[(after + 1)..]);
            } else if (after < current.len) {
                try merged.writer().writeAll(current[after..]);
            }
        } else if (current.len > 0) {
            try merged.writer().writeAll(current);
            if (current[current.len - 1] != '\n') try merged.writer().writeByte('\n');
            try merged.writer().writeByte('\n');
            try merged.writer().writeAll(block.items);
        } else {
            try merged.writer().writeAll(block.items);
        }

        if (std.mem.eql(u8, merged.items, current)) return false;

        const backup = try self.backupFile(path);
        self.writeAtomicText(path, merged.items) catch |err| {
            self.restoreBackup(path, backup);
            return self.fail(EXIT_ROLLBACK, "write-managed-block", "failed atomic replace of {s}: {s}", .{ path, @errorName(err) });
        };
        try self.recordChange(path, "managed-block", "");
        try self.logger.log("OK", self.phase, "write-managed-block", try std.fmt.allocPrint(self.alloc, "managed block updated in {s}", .{path}));
        return true;
    }

    fn ensureTextFile(self: *App, path: []const u8, content: []const u8, mode: u32, owner: ?UserInfo) !bool {
        const current = self.readText(path) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
        if (std.mem.eql(u8, current, content)) {
            if (owner) |info| {
                try chownPath(path, info.uid, info.gid);
                try chmodPath(path, mode);
            }
            return false;
        }
        const backup = try self.backupFile(path);
        self.writeAtomicTextMode(path, content, mode) catch |err| {
            self.restoreBackup(path, backup);
            return self.fail(EXIT_ROLLBACK, "write-file", "failed atomic replace of {s}: {s}", .{ path, @errorName(err) });
        };
        if (owner) |info| {
            try chownPath(path, info.uid, info.gid);
        }
        try self.recordChange(path, "write-file", "");
        try self.logger.log("OK", self.phase, "write-file", try std.fmt.allocPrint(self.alloc, "managed file written: {s}", .{path}));
        return true;
    }

    fn commandExists(self: *App, command: []const u8) !bool {
        const result = try self.runCmd(&.{ "which", command });
        return result.exitCode() == 0;
    }

    fn setSysctlRuntime(self: *App, key: []const u8, value: []const u8) !bool {
        const probe = try self.runCmd(&.{ "sysctl", "-n", key });
        if (probe.exitCode() != 0) {
            try self.logger.log("WARN", self.phase, "runtime-sysctl", try std.fmt.allocPrint(self.alloc, "{s} not present on this host; skipping", .{key}));
            return false;
        }
        const arg = try std.fmt.allocPrint(self.alloc, "{s}={s}", .{ key, value });
        const apply = try self.runCmd(&.{ "sysctl", arg });
        if (apply.exitCode() == 0) {
            try self.logger.log("OK", self.phase, "runtime-sysctl", try std.fmt.allocPrint(self.alloc, "set {s}={s} at runtime", .{ key, value }));
            return true;
        }
        try self.logger.log("WARN", self.phase, "runtime-sysctl", try std.fmt.allocPrint(self.alloc, "unable to set {s}={s} at runtime; persistence only", .{ key, value }));
        return false;
    }

    fn lookupUser(self: *App, name: []const u8) !UserInfo {
        const zname = try std.cstr.addNullByte(self.alloc, name);
        const pw = c.getpwnam(zname.ptr);
        if (pw == null) return self.fail(EXIT_PLATFORM, "validate-user", "target user {s} does not exist", .{name});
        return .{
            .uid = @intCast(pw.*.pw_uid),
            .gid = @intCast(pw.*.pw_gid),
            .home = try self.alloc.dupe(u8, std.mem.span(pw.*.pw_dir)),
        };
    }

    fn userInGroup(self: *App, group_name: []const u8) !bool {
        const result = try self.runCmd(&.{ "id", "-Gn", self.args.username });
        if (result.exitCode() != 0) return false;
        var it = std.mem.tokenizeAny(u8, result.stdout, " \t\r\n");
        while (it.next()) |token| {
            if (std.mem.eql(u8, token, group_name)) return true;
        }
        return false;
    }

    fn validateKeyboardLayout(self: *App) !bool {
        const candidates = [_][]const u8{
            "/usr/local/share/X11/xkb/rules/base.lst",
            "/usr/local/share/X11/xkb/rules/evdev.lst",
            "/usr/X11R6/share/X11/xkb/rules/base.lst",
            "/usr/X11R6/share/X11/xkb/rules/evdev.lst",
        };
        for (candidates) |path| {
            if (fileExists(path) and try self.keyboardLayoutInRules(path)) {
                self.keyboard_validation_source = path;
                return true;
            }
        }

        const symbols = [_][]const u8{
            "/usr/local/share/X11/xkb/symbols",
            "/usr/X11R6/share/X11/xkb/symbols",
        };
        for (symbols) |root| {
            const candidate = try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ root, self.args.keyboard });
            if (fileExists(candidate)) {
                self.keyboard_validation_source = candidate;
                return true;
            }
        }

        const common = [_][]const u8{
            "us", "uk", "gb", "br", "de", "fr", "es", "it", "pt", "pl", "tr", "se", "no", "dk", "fi", "nl", "be", "ch", "at", "cz", "sk", "hu", "ro", "bg", "hr", "rs", "si", "ua", "ru", "jp", "kr", "latam", "ca", "il", "gr",
        };
        for (common) |layout| {
            if (std.mem.eql(u8, layout, self.args.keyboard)) {
                self.keyboard_validation_source = "builtin-common-layouts";
                self.deferred_keyboard_validate = true;
                return true;
            }
        }
        return false;
    }

    fn keyboardLayoutInRules(self: *App, path: []const u8) !bool {
        const text = try self.readText(path);
        var in_layout = false;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "! layout")) {
                in_layout = true;
                continue;
            }
            if (in_layout and line.len > 0 and line[0] == '!' and !std.mem.startsWith(u8, line, "! layout")) break;
            if (in_layout) {
                var tok = std.mem.tokenizeAny(u8, line, " \t");
                if (tok.next()) |first| {
                    if (std.mem.eql(u8, first, self.args.keyboard)) return true;
                }
            }
        }
        return false;
    }

    fn readOrCapture(self: *App, path: []const u8, argv: []const []const u8) ![]const u8 {
        if (fileExists(path)) return self.readText(path);
        const result = try self.runCmd(argv);
        const text = try std.fmt.allocPrint(self.alloc, "{s}{s}", .{ result.stdout, result.stderr });
        try self.writeAtomicText(path, text);
        return text;
    }

    fn readSndstat(self: *App) ![]const u8 {
        _ = self;
        if (!fileExists("/dev/sndstat")) return "";
        return std.fs.cwd().readFileAlloc(std.heap.page_allocator, "/dev/sndstat", 4 * 1024 * 1024) catch "";
    }

    fn parseAudioDevices(self: *App, sndstat_text: []const u8) ![]AudioDevice {
        var list = std.ArrayList(AudioDevice).init(self.alloc);
        var it = std.mem.splitScalar(u8, sndstat_text, '\n');
        while (it.next()) |line| {
            if (!std.mem.startsWith(u8, line, "pcm")) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (colon <= 3) continue;
            const unit = line[3..colon];
            if (!allDigits(unit)) continue;
            const desc = std.mem.trim(u8, line[(colon + 1)..], " \t");
            const lower = try std.ascii.allocLowerString(self.alloc, desc);
            var kind: []const u8 = "other";
            var score: i32 = 100;
            var reason: []const u8 = "fallback-first-detected-device";
            if (containsAny(lower, &.{ "analog", "speaker", "headphone", "front", "line out" })) {
                kind = "analog";
                score = 400;
                reason = "analog-headphone-speaker-output";
            } else if (containsAny(lower, &.{ "usb", "dac", "headset" })) {
                kind = "usb";
                score = 300;
                reason = "usb-headset-or-dac";
            } else if (containsAny(lower, &.{ "hdmi", "displayport", "display port", " dp" })) {
                kind = "hdmi";
                score = 200;
                reason = "hdmi-displayport-audio";
            }
            try list.append(.{ .unit = unit, .desc = desc, .kind = kind, .score = score, .reason = reason });
        }
        return list.toOwnedSlice();
    }

    fn selectAudioDevice(self: *App, devices: []const AudioDevice) ?AudioDevice {
        _ = self;
        if (devices.len == 0) return null;
        var best = devices[0];
        var best_unit = std.fmt.parseInt(i32, best.unit, 10) catch 0;
        for (devices[1..]) |dev| {
            const unit_num = std.fmt.parseInt(i32, dev.unit, 10) catch 0;
            if (dev.score > best.score or (dev.score == best.score and unit_num < best_unit)) {
                best = dev;
                best_unit = unit_num;
            }
        }
        return best;
    }

    fn sysctlExists(self: *App, key: []const u8) !bool {
        const res = try self.runCmd(&.{ "sysctl", "-n", key });
        return res.exitCode() == 0;
    }

    fn ensurePackageInstalled(self: *App, pkg: []const u8, required: bool) !void {
        if (pkg.len == 0) return;
        const check = try self.runCmd(&.{ "pkg", "info", "-e", pkg });
        const label = if (required) "required" else "optional";
        if (check.exitCode() == 0) {
            try self.logger.log("SKIP", self.phase, "pkg-install", try std.fmt.allocPrint(self.alloc, "{s} package {s} already installed", .{ label, pkg }));
            return;
        }
        try self.logger.log("INFO", self.phase, "pkg-install", try std.fmt.allocPrint(self.alloc, "installing {s} package {s}", .{ label, pkg }));
        const install = try self.runCmd(&.{ "pkg", "install", "-y", pkg });
        if (install.exitCode() != 0) {
            if (required) return self.fail(EXIT_PACKAGE, "pkg-install", "required package install failed for {s}", .{pkg});
            try self.logger.log("WARN", self.phase, "pkg-install", try std.fmt.allocPrint(self.alloc, "optional package install failed for {s}; continuing", .{pkg}));
            return;
        }
        try self.logger.log("OK", self.phase, "pkg-install", try std.fmt.allocPrint(self.alloc, "installed {s} package {s}", .{ label, pkg }));
    }

    fn resolveRequired(self: *App, slot: []const u8, candidates: []const []const u8) ![]const u8 {
        for (candidates) |candidate| {
            const res = try self.runCmd(&.{ "pkg", "search", "-e", candidate });
            if (res.exitCode() == 0) return candidate;
        }
        return self.fail(EXIT_PACKAGE, "resolve-package", "required package slot {s} could not be resolved", .{slot});
    }

    fn resolveOptional(self: *App, slot: []const u8, candidates: []const []const u8) ![]const u8 {
        for (candidates) |candidate| {
            const res = try self.runCmd(&.{ "pkg", "search", "-e", candidate });
            if (res.exitCode() == 0) return candidate;
        }
        try self.logger.log("WARN", self.phase, "resolve-optional", try std.fmt.allocPrint(self.alloc, "optional package slot {s} unresolved; continuing", .{slot}));
        return "";
    }

    fn phasePreflight(self: *App) !void {
        self.phase = "phase1";
        if (self.shouldSkipByCheckpoint(1)) {
            try self.logger.log("SKIP", self.phase, "resume", "phase 1 already completed; skipping by checkpoint");
            const info = try self.lookupUser(self.args.username);
            self.target_home = info.home;
            self.target_uid = info.uid;
            self.target_gid = info.gid;
            return;
        }

        try self.logger.log("INFO", self.phase, "start", "preflight validation begins");

        const uname = try self.runCmd(&.{ "uname", "-s" });
        if (!std.mem.eql(u8, std.mem.trim(u8, uname.stdout, " \t\r\n"), "DragonFly")) {
            return self.fail(EXIT_PLATFORM, "detect-os", "uname -s returned {s}; DragonFlyBSD required", .{std.mem.trim(u8, uname.stdout, " \t\r\n")});
        }
        try self.logger.log("OK", self.phase, "detect-os", "DragonFlyBSD confirmed");

        if (std.posix.geteuid() != 0) return self.fail(EXIT_PLATFORM, "detect-root", "script must run as root", .{});
        try self.logger.log("OK", self.phase, "detect-root", "root privileges confirmed");

        if (std.mem.eql(u8, self.args.username, "root")) return self.fail(EXIT_PLATFORM, "validate-user", "target user must not be root", .{});
        const info = try self.lookupUser(self.args.username);
        self.target_home = info.home;
        self.target_uid = info.uid;
        self.target_gid = info.gid;
        if (!dirExists(self.target_home)) return self.fail(EXIT_PLATFORM, "validate-home", "target home for {s} is invalid: {s}", .{ self.args.username, self.target_home });
        try self.logger.log("OK", self.phase, "validate-user", try std.fmt.allocPrint(self.alloc, "target user {s} with home {s} confirmed", .{ self.args.username, self.target_home }));

        if (!try self.commandExists("pkg")) return self.fail(EXIT_PLATFORM, "validate-pkg", "pkg is not available in PATH and cannot be validated", .{});
        const pkg_n = try self.runCmd(&.{ "pkg", "-N" });
        if (pkg_n.exitCode() == 0) {
            try self.logger.log("OK", self.phase, "validate-pkg", "pkg is available");
        } else {
            try self.logger.log("WARN", self.phase, "validate-pkg", "pkg present but not initialized; bootstrap will be attempted later");
        }

        const required_commands = [_][]const u8{ "uname", "id", "awk", "sed", "grep", "cut", "sort", "tr", "mkdir", "mv", "cp", "rm", "find", "pciconf", "kldstat", "sysctl", "hostname", "date", "touch", "pkg", "pw" };
        for (required_commands) |cmd| {
            if (!try self.commandExists(cmd)) return self.fail(EXIT_PLATFORM, "validate-command", "required command {s} is missing", .{cmd});
        }
        try self.logger.log("OK", self.phase, "validate-commands", "essential commands are present");

        if (!try self.validateKeyboardLayout()) return self.fail(EXIT_PLATFORM, "validate-keyboard", "keyboard layout {s} could not be validated against local XKB data", .{self.args.keyboard});
        try self.logger.log("OK", self.phase, "validate-keyboard", try std.fmt.allocPrint(self.alloc, "keyboard layout {s} validated via {s}", .{ self.args.keyboard, self.keyboard_validation_source }));
        if (self.deferred_keyboard_validate) {
            try self.logger.log("WARN", self.phase, "validate-keyboard", try std.fmt.allocPrint(self.alloc, "keyboard layout {s} accepted by fallback list; strict XKB revalidation will occur after X packages install", .{self.args.keyboard}));
        }

        try self.saveCheckpoint(1, "preflight-validation");
        try self.logger.log("OK", self.phase, "end", "preflight validation complete");
    }

    fn phaseDiscovery(self: *App) !void {
        self.phase = "phase2";
        if (self.args.resume and self.completed_phase >= 2 and fileExists(self.paths.hardware_snapshot)) {
            try self.logger.log("SKIP", self.phase, "resume", "phase 2 already completed; skipping by checkpoint");
            return;
        }

        try self.logger.log("INFO", self.phase, "start", "discovery snapshot begins");
        try ensureDir(self.paths.discovery_dir);

        try self.captureToFile(&.{ "uname", "-a" }, try std.fmt.allocPrint(self.alloc, "{s}/uname-a.txt", .{self.paths.discovery_dir}));
        try self.captureToFile(&.{ "pkg", "-N" }, try std.fmt.allocPrint(self.alloc, "{s}/pkg-N.txt", .{self.paths.discovery_dir}));
        try self.captureToFile(&.{ "pkg", "info" }, try std.fmt.allocPrint(self.alloc, "{s}/pkg-info.txt", .{self.paths.discovery_dir}));
        try self.captureToFile(&.{ "pciconf", "-lv" }, try std.fmt.allocPrint(self.alloc, "{s}/pciconf-lv.txt", .{self.paths.discovery_dir}));
        try self.captureToFile(&.{ "kldstat" }, try std.fmt.allocPrint(self.alloc, "{s}/kldstat.txt", .{self.paths.discovery_dir}));

        const sndstat_out = try std.fmt.allocPrint(self.alloc, "{s}/sndstat.txt", .{self.paths.discovery_dir});
        if (fileExists("/dev/sndstat")) {
            try self.writeAtomicText(sndstat_out, try self.readText("/dev/sndstat"));
        } else {
            try self.writeAtomicText(sndstat_out, "sndstat-unavailable\n");
        }

        var sysctl_lines = std.ArrayList(u8).init(self.alloc);
        const sysctls = [_][]const u8{ "kern.syscons_async", "hw.snd.default_unit", "hw.snd.default_auto", "hw.backlight_max", "hw.backlight_level" };
        for (sysctls) |key| {
            const res = try self.runCmd(&.{ "sysctl", key });
            if (res.exitCode() == 0) {
                try sysctl_lines.writer().writeAll(res.stdout);
                if (res.stdout.len == 0 or res.stdout[res.stdout.len - 1] != '\n') try sysctl_lines.writer().writeByte('\n');
            }
        }
        try self.writeAtomicText(try std.fmt.allocPrint(self.alloc, "{s}/sysctl-snapshot.txt", .{self.paths.discovery_dir}), sysctl_lines.items);

        try self.captureToFile(&.{ "id", self.args.username }, try std.fmt.allocPrint(self.alloc, "{s}/id-{s}.txt", .{ self.paths.discovery_dir, self.args.username }));
        try self.captureToFile(&.{ "id", "-Gn", self.args.username }, try std.fmt.allocPrint(self.alloc, "{s}/groups-{s}.txt", .{ self.paths.discovery_dir, self.args.username }));

        const managed = [_][]const u8{ "/etc/rc.conf", "/boot/loader.conf", "/etc/sysctl.conf", "/etc/ttys" };
        for (managed) |path| {
            if (fileExists(path)) {
                const encoded = try encodePath(self.alloc, path);
                const dst = try std.fmt.allocPrint(self.alloc, "{s}/{s}.snapshot", .{ self.paths.discovery_dir, encoded });
                const cp = try self.runCmd(&.{ "cp", "-p", path, dst });
                if (cp.exitCode() != 0) {}
            }
        }

        if (dirExists("/etc/X11")) {
            const res = try self.runCmd(&.{ "find", "/etc/X11", "-maxdepth", "3", "-type", "f" });
            var lines = std.ArrayList([]const u8).init(self.alloc);
            var split = std.mem.splitScalar(u8, res.stdout, '\n');
            while (split.next()) |line| {
                if (line.len == 0) continue;
                try lines.append(line);
            }
            std.sort.heap([]const u8, lines.items, {}, lessThanString);
            var out = std.ArrayList(u8).init(self.alloc);
            for (lines.items) |line| {
                try out.writer().print("{s}\n", .{line});
            }
            try self.writeAtomicText(try std.fmt.allocPrint(self.alloc, "{s}/x11-filelist.txt", .{self.paths.discovery_dir}), out.items);
        } else {
            try self.writeAtomicText(try std.fmt.allocPrint(self.alloc, "{s}/x11-filelist.txt", .{self.paths.discovery_dir}), "x11-absent\n");
        }

        const userfiles = [_][]const u8{ ".xsession", ".xinitrc" };
        for (userfiles) |rel| {
            const abs = try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ self.target_home, rel });
            if (fileExists(abs)) {
                const encoded = try encodePath(self.alloc, abs);
                const dst = try std.fmt.allocPrint(self.alloc, "{s}/{s}.snapshot", .{ self.paths.discovery_dir, encoded });
                const cp = try self.runCmd(&.{ "cp", "-p", abs, dst });
                if (cp.exitCode() != 0) {}
            }
        }

        try self.writeJsonFile(self.paths.hardware_snapshot, .{
            .snapshot_dir = self.paths.discovery_dir,
            .discovery_utc = self.nowStamp(),
            .target_user = self.args.username,
            .target_home = self.target_home,
        });
        try self.saveCheckpoint(2, "discovery-snapshot");
        try self.logger.log("OK", self.phase, "end", "discovery snapshot complete");
    }

    fn captureToFile(self: *App, argv: []const []const u8, output_path: []const u8) !void {
        const result = try self.runCmd(argv);
        const text = try std.fmt.allocPrint(self.alloc, "{s}{s}", .{ result.stdout, result.stderr });
        try self.writeAtomicText(output_path, text);
    }

    fn phaseTuning(self: *App) !void {
        self.phase = "phase3";
        if (self.shouldSkipByCheckpoint(3) and self.hasManagedBlock("/etc/sysctl.conf")) {
            try self.logger.log("SKIP", self.phase, "resume", "phase 3 already completed and managed sysctl block detected; skipping");
            return;
        }

        try self.logger.log("INFO", self.phase, "start", "conservative desktop tuning begins");
        var lines = std.ArrayList([]const u8).init(self.alloc);

        const kern = try self.runCmd(&.{ "sysctl", "-n", "kern.syscons_async" });
        if (kern.exitCode() == 0) {
            const current = std.mem.trim(u8, kern.stdout, " \t\r\n");
            if (!std.mem.eql(u8, current, "1")) {
                _ = try self.setSysctlRuntime("kern.syscons_async", "1");
            } else {
                try self.logger.log("SKIP", self.phase, "runtime-sysctl", "kern.syscons_async already set to 1");
            }
            try lines.append("kern.syscons_async=1");
        } else {
            try self.logger.log("WARN", self.phase, "runtime-sysctl", "kern.syscons_async not present on this host; skipping");
        }

        const sndstat = try self.readSndstat();
        const devices = try self.parseAudioDevices(sndstat);
        if (devices.len > 1) {
            if (self.selectAudioDevice(devices)) |selected| {
                self.hardware.audio_selected_unit = selected.unit;
                self.hardware.audio_default_reason = selected.reason;
                _ = try self.setSysctlRuntime("hw.snd.default_unit", selected.unit);
                try lines.append(try std.fmt.allocPrint(self.alloc, "hw.snd.default_unit={s}", .{selected.unit}));
            }
        } else if (devices.len == 1) {
            try self.logger.log("SKIP", self.phase, "runtime-sysctl", "single sound device detected; no persistent hw.snd.default_unit override needed");
        } else {
            try self.logger.log("WARN", self.phase, "runtime-sysctl", "no sound devices detected during tuning phase");
        }

        _ = try self.updateManagedBlock("/etc/sysctl.conf", lines.items);
        try self.saveCheckpoint(3, "conservative-desktop-tuning");
        try self.logger.log("OK", self.phase, "end", "conservative desktop tuning complete");
    }

    fn phasePkgReady(self: *App) !void {
        self.phase = "phase4";
        if (self.shouldSkipByCheckpoint(4)) {
            try self.logger.log("SKIP", self.phase, "resume", "phase 4 already completed; skipping by checkpoint");
            return;
        }

        try self.logger.log("INFO", self.phase, "start", "package manager readiness begins");
        const pkg_n = try self.runCmd(&.{ "pkg", "-N" });
        if (pkg_n.exitCode() != 0) {
            try self.logger.log("INFO", self.phase, "pkg-bootstrap", "bootstrapping pkg");
            const boot = try self.runCmd(&.{ "pkg", "bootstrap", "-yf" });
            if (boot.exitCode() != 0) return self.fail(EXIT_PACKAGE, "pkg-bootstrap", "pkg bootstrap failed", .{});
        }
        try self.logger.log("OK", self.phase, "pkg-bootstrap", "pkg is initialized");

        const update = try self.runCmd(&.{ "pkg", "update" });
        if (update.exitCode() != 0) return self.fail(EXIT_PACKAGE, "pkg-update", "pkg update failed", .{});
        try self.logger.log("OK", self.phase, "pkg-update", "repository metadata updated");

        const abi = try self.runCmd(&.{ "pkg", "config", "ABI" });
        const repo = try self.runCmd(&.{ "pkg", "repo", "-l" });
        const repo_line = firstLine(repo.stdout);
        const repo_name = firstToken(repo_line);
        try self.logger.log("INFO", self.phase, "pkg-context", try std.fmt.allocPrint(self.alloc, "pkg ABI {s}; repository context {s}", .{ std.mem.trim(u8, abi.stdout, " \t\r\n"), repo_name }));

        if (self.args.skip_upgrade) {
            try self.logger.log("SKIP", self.phase, "pkg-upgrade", "package upgrade skipped by flag");
        } else {
            try self.logger.log("INFO", self.phase, "pkg-upgrade", "upgrading installed packages conservatively");
            const upgrade = try self.runCmd(&.{ "pkg", "upgrade", "-y" });
            if (upgrade.exitCode() == 0) {
                try self.logger.log("OK", self.phase, "pkg-upgrade", "package upgrade completed");
            } else {
                try self.logger.log("WARN", self.phase, "pkg-upgrade", "package upgrade failed; continuing with package resolution");
            }
        }

        try self.saveCheckpoint(4, "package-manager-readiness");
        try self.logger.log("OK", self.phase, "end", "package manager readiness complete");
    }

    fn phaseHardwarePlan(self: *App) !void {
        self.phase = "phase5";
        if (self.args.resume and self.completed_phase >= 5 and fileExists(self.paths.hardware_snapshot)) {
            const text = self.readText(self.paths.hardware_snapshot) catch "";
            if (text.len > 0 and std.mem.indexOf(u8, text, "gpu_plan") != null) {
                const parsed_opt = std.json.parseFromSlice(HardwareSnapshot, self.alloc, text, .{ .ignore_unknown_fields = true }) catch null;
                if (parsed_opt) |parsed_val| {
                    var parsed = parsed_val;
                    defer parsed.deinit();
                    self.hardware.gpu_plan = parsed.value.gpu_plan;
                    self.hardware.audio_profile = parsed.value.audio_profile;
                    self.hardware.audio_device_count = parsed.value.audio_device_count;
                    self.hardware.audio_selected_unit = parsed.value.audio_selected_unit;
                    self.hardware.audio_default_reason = parsed.value.audio_default_reason;
                    self.hardware.backlight_manageable = parsed.value.backlight_manageable;
                }
                try self.logger.log("SKIP", self.phase, "resume", "phase 5 already completed; using saved hardware plan");
                return;
            }
        }

        try self.logger.log("INFO", self.phase, "start", "hardware-aware planning begins");
        const pciconf_text = try self.readOrCapture(try std.fmt.allocPrint(self.alloc, "{s}/pciconf-lv.txt", .{self.paths.discovery_dir}), &.{ "pciconf", "-lv" });
        const kldstat_text = try self.readOrCapture(try std.fmt.allocPrint(self.alloc, "{s}/kldstat.txt", .{self.paths.discovery_dir}), &.{ "kldstat" });
        self.hardware.gpu_plan = try self.classifyGpu(pciconf_text, kldstat_text);
        try self.logger.log("INFO", self.phase, "gpu-plan", try std.fmt.allocPrint(self.alloc, "GPU classified as {s}", .{self.hardware.gpu_plan}));

        const sndstat = try self.readSndstat();
        const devices = try self.parseAudioDevices(sndstat);
        self.hardware.audio_device_count = devices.len;
        if (devices.len == 0) {
            self.hardware.audio_profile = "no-detected-audio";
        } else {
            var has_usb = false;
            var has_analog = false;
            var has_hdmi = false;
            for (devices) |dev| {
                if (std.mem.eql(u8, dev.kind, "usb")) has_usb = true;
                if (std.mem.eql(u8, dev.kind, "analog")) has_analog = true;
                if (std.mem.eql(u8, dev.kind, "hdmi")) has_hdmi = true;
            }
            if (has_usb) {
                self.hardware.audio_profile = "USB audio present";
            } else if (devices.len > 1 and has_analog and has_hdmi) {
                self.hardware.audio_profile = "multi-device analog + HDMI";
            } else {
                self.hardware.audio_profile = "single-device analog";
            }
            if (self.selectAudioDevice(devices)) |selected| {
                self.hardware.audio_selected_unit = selected.unit;
                self.hardware.audio_default_reason = selected.reason;
            }
        }
        try self.logger.log("INFO", self.phase, "audio-plan", try std.fmt.allocPrint(self.alloc, "audio classified as {s}; selected unit {s} reason {s}", .{ self.hardware.audio_profile, self.hardware.audio_selected_unit, self.hardware.audio_default_reason }));

        self.hardware.backlight_manageable = try self.sysctlExists("hw.backlight_max") and try self.sysctlExists("hw.backlight_level");
        if (self.hardware.backlight_manageable) {
            try self.logger.log("INFO", self.phase, "backlight-plan", "backlight sysctls present; machine is backlight-manageable");
        } else {
            try self.logger.log("WARN", self.phase, "backlight-plan", "backlight sysctls not present; skipping backlight helper");
        }

        if (self.deferred_keyboard_validate) {
            try self.logger.log("INFO", self.phase, "keyboard-plan", try std.fmt.allocPrint(self.alloc, "keyboard layout {s} will be strictly revalidated after XKB data is installed", .{self.args.keyboard}));
        } else {
            try self.logger.log("OK", self.phase, "keyboard-plan", try std.fmt.allocPrint(self.alloc, "keyboard layout {s} ready for minimal Xorg drop-in", .{self.args.keyboard}));
        }

        try self.writeJsonFile(self.paths.hardware_snapshot, .{
            .snapshot_dir = self.paths.discovery_dir,
            .discovery_utc = self.nowStamp(),
            .target_user = self.args.username,
            .target_home = self.target_home,
            .gpu_plan = self.hardware.gpu_plan,
            .audio_profile = self.hardware.audio_profile,
            .audio_device_count = self.hardware.audio_device_count,
            .audio_selected_unit = self.hardware.audio_selected_unit,
            .audio_default_reason = self.hardware.audio_default_reason,
            .backlight_manageable = self.hardware.backlight_manageable,
        });
        try self.saveCheckpoint(5, "hardware-aware-planning");
        try self.logger.log("OK", self.phase, "end", "hardware-aware planning complete");
    }

    fn classifyGpu(self: *App, pciconf_text: []const u8, kldstat_text: []const u8) ![]const u8 {
        _ = self;
        const low_kld = try std.ascii.allocLowerString(std.heap.page_allocator, kldstat_text);
        if (std.mem.indexOf(u8, low_kld, "amdgpu") != null) return "amd-amdgpu";
        if (std.mem.indexOf(u8, low_kld, "radeon") != null) return "amd-radeon";
        if (std.mem.indexOf(u8, low_kld, "i915") != null or std.mem.indexOf(u8, low_kld, "intel") != null) return "intel-kms";

        const low = try std.ascii.allocLowerString(std.heap.page_allocator, pciconf_text);
        if ((std.mem.indexOf(u8, low, "intel") != null) and containsAny(low, &.{ "vg", "display", "graphics" })) return "intel-kms";
        if (containsAny(low, &.{ "amd", "ati", "advanced micro devices" })) {
            if (containsAny(low, &.{ "vega", "navi", "polaris", "ellesmere", "baffin", "gfx", "rdna", "rembrandt", "phoenix", "raven", "renoir", "cezanne", "rx 4", "rx 5", "rx 6", "rx 7" })) {
                return "amd-amdgpu";
            }
            return "amd-radeon";
        }
        return "unknown-generic";
    }

    fn phasePackageResolution(self: *App) !void {
        self.phase = "phase6";
        if (self.args.resume and self.completed_phase >= 6 and fileExists(self.paths.package_snapshot)) {
            const text = self.readText(self.paths.package_snapshot) catch "";
            if (text.len > 0 and std.mem.indexOf(u8, text, "pkg_xorg") != null) {
                const parsed_opt = std.json.parseFromSlice(PackageSnapshot, self.alloc, text, .{ .ignore_unknown_fields = true }) catch null;
                if (parsed_opt) |parsed_val| {
                    var parsed = parsed_val;
                    defer parsed.deinit();
                    self.packages = parsed.value;
                }
                try self.logger.log("SKIP", self.phase, "resume", "phase 6 already completed; using saved package resolution");
                return;
            }
        }

        try self.logger.log("INFO", self.phase, "start", "package resolution begins");

        self.packages.pkg_xorg = try self.resolveRequired("xorg", &.{ "xorg" });
        self.packages.pkg_input_libinput = try self.resolveRequired("xf86-input-libinput", &.{ "xf86-input-libinput" });
        self.packages.pkg_input_evdev = try self.resolveRequired("xf86-input-evdev", &.{ "xf86-input-evdev" });
        self.packages.pkg_xdm = try self.resolveRequired("xdm", &.{ "xdm" });
        self.packages.pkg_gnustep = try self.resolveRequired("gnustep", &.{ "gnustep" });
        self.packages.pkg_gnustep_back = try self.resolveRequired("gnustep-back", &.{ "gnustep-back" });
        self.packages.pkg_windowmaker = try self.resolveRequired("windowmaker", &.{ "windowmaker" });
        self.packages.pkg_terminal = try self.resolveRequired("terminal", &.{ "xterm", "rxvt-unicode", "mlterm" });
        self.packages.pkg_editor = try self.resolveRequired("editor", &.{ "vim", "nano" });
        self.packages.pkg_browser = try self.resolveRequired("browser", &.{ "firefox", "firefox-esr", "chromium" });
        self.packages.pkg_curl = try self.resolveRequired("curl", &.{ "curl" });
        self.packages.pkg_wget = try self.resolveRequired("wget", &.{ "wget" });
        self.packages.pkg_rsync = try self.resolveRequired("rsync", &.{ "rsync" });
        self.packages.pkg_git = try self.resolveRequired("git", &.{ "git" });

        self.packages.terminal_bin = if (std.mem.eql(u8, self.packages.pkg_terminal, "rxvt-unicode")) "urxvt" else if (std.mem.eql(u8, self.packages.pkg_terminal, "mlterm")) "mlterm" else "xterm";

        try self.logger.log("INFO", self.phase, "resolve-required", try std.fmt.allocPrint(self.alloc, "resolved xorg to {s}", .{self.packages.pkg_xorg}));
        try self.logger.log("INFO", self.phase, "resolve-required", try std.fmt.allocPrint(self.alloc, "resolved xf86-input-libinput to {s}", .{self.packages.pkg_input_libinput}));
        try self.logger.log("INFO", self.phase, "resolve-required", try std.fmt.allocPrint(self.alloc, "resolved xf86-input-evdev to {s}", .{self.packages.pkg_input_evdev}));
        try self.logger.log("INFO", self.phase, "resolve-required", try std.fmt.allocPrint(self.alloc, "resolved xdm to {s}", .{self.packages.pkg_xdm}));
        try self.logger.log("INFO", self.phase, "resolve-required", try std.fmt.allocPrint(self.alloc, "resolved gnustep to {s}", .{self.packages.pkg_gnustep}));
        try self.logger.log("INFO", self.phase, "resolve-required", try std.fmt.allocPrint(self.alloc, "resolved gnustep-back to {s}", .{self.packages.pkg_gnustep_back}));
        try self.logger.log("INFO", self.phase, "resolve-required", try std.fmt.allocPrint(self.alloc, "resolved windowmaker to {s}", .{self.packages.pkg_windowmaker}));
        try self.logger.log("INFO", self.phase, "resolve-required", try std.fmt.allocPrint(self.alloc, "resolved terminal to {s}", .{self.packages.pkg_terminal}));
        try self.logger.log("INFO", self.phase, "resolve-required", try std.fmt.allocPrint(self.alloc, "resolved editor to {s}", .{self.packages.pkg_editor}));
        try self.logger.log("INFO", self.phase, "resolve-required", try std.fmt.allocPrint(self.alloc, "resolved browser to {s}", .{self.packages.pkg_browser}));

        self.packages.pkg_office = try self.resolveOptional("office", &.{ "libreoffice" });
        self.packages.pkg_pdfview = try self.resolveOptional("pdf-viewer", &.{ "evince", "xpdf", "zathura" });
        self.packages.pkg_filemgr = try self.resolveOptional("file-manager", &.{ "thunar", "pcmanfm", "xfe" });
        self.packages.pkg_sysmon = try self.resolveOptional("system-monitor", &.{ "htop", "btop" });
        self.packages.pkg_zip = try self.resolveOptional("zip", &.{ "zip" });
        self.packages.pkg_unzip = try self.resolveOptional("unzip", &.{ "unzip" });
        self.packages.pkg_p7zip = try self.resolveOptional("p7zip", &.{ "p7zip" });
        self.packages.pkg_clip = try self.resolveOptional("clipboard", &.{ "xclip", "xsel" });
        self.packages.pkg_fonts = try self.resolveOptional("fonts", &.{ "dejavu", "liberation-fonts-ttf", "noto-basic-ttf" });
        self.packages.pkg_video = try self.resolveOptional("video-player", &.{ "mpv", "vlc" });
        self.packages.pkg_audio = try self.resolveOptional("audio-player", &.{ "mpg123", "audacious" });
        self.packages.pkg_transcoder = try self.resolveOptional("transcoder", &.{ "ffmpeg" });
        self.packages.pkg_audio_util = try self.resolveOptional("audio-utility", &.{ "sox" });
        self.packages.pkg_image = try self.resolveOptional("image-editor", &.{ "gimp" });
        self.packages.pkg_screenshot = try self.resolveOptional("screenshot", &.{ "scrot", "maim", "ImageMagick7", "ImageMagick" });

        self.packages.timestamp = self.nowStamp();
        try self.writeJsonFile(self.paths.package_snapshot, self.packages);

        const required_pkgs = [_][]const u8{
            self.packages.pkg_xorg,
            self.packages.pkg_input_libinput,
            self.packages.pkg_input_evdev,
            self.packages.pkg_xdm,
            self.packages.pkg_gnustep,
            self.packages.pkg_gnustep_back,
            self.packages.pkg_windowmaker,
            self.packages.pkg_terminal,
            self.packages.pkg_editor,
            self.packages.pkg_browser,
            self.packages.pkg_curl,
            self.packages.pkg_wget,
            self.packages.pkg_rsync,
            self.packages.pkg_git,
        };
        for (required_pkgs) |pkg| try self.ensurePackageInstalled(pkg, true);

        const optional_pkgs = [_][]const u8{
            self.packages.pkg_office,
            self.packages.pkg_pdfview,
            self.packages.pkg_filemgr,
            self.packages.pkg_sysmon,
            self.packages.pkg_zip,
            self.packages.pkg_unzip,
            self.packages.pkg_p7zip,
            self.packages.pkg_clip,
            self.packages.pkg_fonts,
            self.packages.pkg_video,
            self.packages.pkg_audio,
            self.packages.pkg_transcoder,
            self.packages.pkg_audio_util,
            self.packages.pkg_image,
            self.packages.pkg_screenshot,
        };
        for (optional_pkgs) |pkg| try self.ensurePackageInstalled(pkg, false);

        if (self.deferred_keyboard_validate) {
            const strict_candidates = [_][]const u8{
                "/usr/local/share/X11/xkb/rules/base.lst",
                "/usr/local/share/X11/xkb/rules/evdev.lst",
                "/usr/X11R6/share/X11/xkb/rules/base.lst",
                "/usr/X11R6/share/X11/xkb/rules/evdev.lst",
            };
            var strict_ok = false;
            for (strict_candidates) |path| {
                if (fileExists(path) and try self.keyboardLayoutInRules(path)) {
                    self.keyboard_validation_source = path;
                    strict_ok = true;
                    break;
                }
            }
            if (!strict_ok) return self.fail(EXIT_VALIDATION, "validate-keyboard-strict", "keyboard layout {s} failed strict XKB validation after package install", .{self.args.keyboard});
            self.deferred_keyboard_validate = false;
            try self.logger.log("OK", self.phase, "validate-keyboard-strict", try std.fmt.allocPrint(self.alloc, "keyboard layout {s} strictly revalidated via {s}", .{ self.args.keyboard, self.keyboard_validation_source }));
        }

        try self.saveCheckpoint(6, "package-resolution");
        try self.logger.log("OK", self.phase, "end", "package resolution complete");
    }

    fn phaseSystemConfiguration(self: *App) !void {
        self.phase = "phase7";
        if (self.shouldSkipByCheckpoint(7) and self.hasManagedBlock("/etc/rc.conf")) {
            try self.logger.log("SKIP", self.phase, "resume", "phase 7 already completed and managed block detected; skipping");
            return;
        }

        try self.logger.log("INFO", self.phase, "start", "system configuration begins");
        _ = try self.updateManagedBlock("/etc/rc.conf", &.{ "# intentionally conservative: no desktop daemons forced in v1" });
        _ = try self.updateManagedBlock("/boot/loader.conf", &.{ "# intentionally conservative: no loader tunables forced in v1 without diagnosed need" });
        try self.updateTtysForXdm();
        try self.saveCheckpoint(7, "system-configuration");
        try self.logger.log("OK", self.phase, "end", "system configuration complete");
    }

    fn updateTtysForXdm(self: *App) !void {
        const path = "/etc/ttys";
        const current = self.readText(path) catch |err| switch (err) {
            error.FileNotFound => return self.fail(EXIT_CONFIG, "write-ttys", "/etc/ttys is missing", .{}),
            else => return err,
        };
        const backup = try self.backupFile(path);
        const desired = "ttyv8\t\"/usr/local/bin/xdm -nodaemon\"\txterm\ton\tsecure";

        var out = std.ArrayList(u8).init(self.alloc);
        var matched = false;
        var split = std.mem.splitScalar(u8, current, '\n');
        while (split.next()) |line| {
            if (std.mem.startsWith(u8, line, "ttyv8") and isSpaceOrTab(line, 5)) {
                matched = true;
                try out.writer().print("{s}\n", .{desired});
            } else if (line.len > 0) {
                try out.writer().print("{s}\n", .{line});
            }
        }
        if (!matched) {
            try out.writer().print("{s}\n", .{desired});
        }

        if (std.mem.indexOf(u8, out.items, desired) == null) {
            self.restoreBackup(path, backup);
            return self.fail(EXIT_VALIDATION, "validate-ttys", "generated /etc/ttys does not contain enabled XDM ttyv8 entry", .{});
        }

        self.writeAtomicText(path, out.items) catch |err| {
            self.restoreBackup(path, backup);
            return self.fail(EXIT_ROLLBACK, "write-ttys", "failed atomic replace of /etc/ttys: {s}", .{@errorName(err)});
        };
        try self.recordChange(path, "ttyv8-xdm-enabled", "");
        try self.logger.log("OK", self.phase, "write-ttys", "/etc/ttys updated for XDM on ttyv8");
    }

    fn phaseX11Configuration(self: *App) !void {
        self.phase = "phase8";
        if (self.args.resume and self.completed_phase >= 8 and fileExists("/etc/X11/xorg.conf.d/00-keyboard.conf")) {
            try self.logger.log("SKIP", self.phase, "resume", "phase 8 already completed; keyboard drop-in present");
            return;
        }

        try self.logger.log("INFO", self.phase, "start", "X11 configuration begins");
        try ensureDir("/etc/X11/xorg.conf.d");

        const keyboard_conf = try std.fmt.allocPrint(self.alloc,
            "Section \"InputClass\"\n    Identifier \"turkishvan-bsd keyboard\"\n    MatchIsKeyboard \"on\"\n    Option \"XkbLayout\" \"{s}\"\nEndSection\n",
            .{self.args.keyboard},
        );
        _ = try self.ensureTextFile("/etc/X11/xorg.conf.d/00-keyboard.conf", keyboard_conf, 0o644, null);
        try self.logger.log("OK", self.phase, "write-keyboard-conf", "minimal keyboard drop-in written");

        if (fileExists("/etc/X11/xorg.conf")) {
            try self.logger.log("WARN", self.phase, "xorg-policy", "monolithic /etc/X11/xorg.conf exists; leaving it untouched and preferring drop-ins");
        } else {
            try self.logger.log("OK", self.phase, "xorg-policy", "no monolithic xorg.conf forced; autodetection remains primary");
        }

        if (fileExists("/etc/X11/xorg.conf.d/10-libinput.conf")) {
            try self.logger.log("SKIP", self.phase, "libinput-conf", "existing 10-libinput.conf preserved");
        } else {
            try self.logger.log("SKIP", self.phase, "libinput-conf", "libinput explicit drop-in not needed in v1");
        }

        if (fileExists("/etc/X11/xorg.conf.d/20-local-video-permissions.conf")) {
            try self.logger.log("SKIP", self.phase, "video-perm-conf", "existing 20-local-video-permissions.conf preserved");
        } else {
            try self.logger.log("SKIP", self.phase, "video-perm-conf", "explicit DRI permission stanza not needed; video group model used");
        }

        try self.saveCheckpoint(8, "x11-configuration");
        try self.logger.log("OK", self.phase, "end", "X11 configuration complete");
    }

    fn phaseUserProvisioning(self: *App) !void {
        self.phase = "phase9";
        const xsession_path = try std.fmt.allocPrint(self.alloc, "{s}/.xsession", .{self.target_home});
        const xinitrc_path = try std.fmt.allocPrint(self.alloc, "{s}/.xinitrc", .{self.target_home});
        if (self.args.resume and self.completed_phase >= 9 and fileExists(xsession_path) and fileExists(xinitrc_path)) {
            try self.logger.log("SKIP", self.phase, "resume", "phase 9 already completed; user session files present");
            return;
        }

        try self.logger.log("INFO", self.phase, "start", "user provisioning begins");
        try self.ensureVideoGroupMembership();
        const gnustep_init = try self.discoverGNUstepInit();

        const config_dir = try std.fmt.allocPrint(self.alloc, "{s}/.config/{s}", .{ self.target_home, SCRIPT_NAME });
        try ensureDir(config_dir);
        try chownPath(config_dir, self.target_uid, self.target_gid);
        try chmodPath(config_dir, 0o755);

        const xsession = try std.fmt.allocPrint(self.alloc,
            "#!/bin/csh -f\n" ++
            "setenv XDG_CONFIG_HOME \"{s}/.config\"\n" ++
            "setenv DESKTOP_SESSION \"WindowMaker\"\n" ++
            "setenv XDG_CURRENT_DESKTOP \"GNUstep:WindowMaker\"\n" ++
            "setenv WINDOW_MANAGER \"WindowMaker\"\n" ++
            "setenv XKB_DEFAULT_LAYOUT \"{s}\"\n" ++
            "if ( -r \"{s}\" ) then\n    source \"{s}\"\nendif\n" ++
            "if ( -x /usr/local/bin/wmaker ) then\n    exec /usr/local/bin/wmaker\nendif\n" ++
            "if ( -x /usr/local/bin/WindowMaker ) then\n    exec /usr/local/bin/WindowMaker\nendif\n" ++
            "if ( -x /usr/X11R6/bin/{s} ) then\n    exec /usr/X11R6/bin/{s}\nendif\n" ++
            "if ( -x /usr/local/bin/{s} ) then\n    exec /usr/local/bin/{s}\nendif\n" ++
            "if ( -x /usr/X11R6/bin/xterm ) then\n    exec /usr/X11R6/bin/xterm\nendif\n" ++
            "exec /usr/local/bin/xterm\n",
            .{ self.target_home, self.args.keyboard, gnustep_init, gnustep_init, self.packages.terminal_bin, self.packages.terminal_bin, self.packages.terminal_bin, self.packages.terminal_bin },
        );
        _ = try self.ensureTextFile(xsession_path, xsession, 0o755, .{ .uid = self.target_uid, .gid = self.target_gid, .home = self.target_home });

        const xinitrc = try std.fmt.allocPrint(self.alloc, "#!/bin/csh -f\nexec \"{s}/.xsession\"\n", .{self.target_home});
        _ = try self.ensureTextFile(xinitrc_path, xinitrc, 0o755, .{ .uid = self.target_uid, .gid = self.target_gid, .home = self.target_home });

        if (self.hardware.backlight_manageable) {
            const helper_path = try std.fmt.allocPrint(self.alloc, "{s}/.config/{s}/brightness.csh", .{ self.target_home, SCRIPT_NAME });
            const helper =
                "#!/bin/csh -f\n" ++
                "if ( $#argv != 1 ) then\n    /bin/echo \"usage: brightness.csh up|down\"\n    exit 64\nendif\n" ++
                "set max = `sysctl -n hw.backlight_max`\n" ++
                "set cur = `sysctl -n hw.backlight_level`\n" ++
                "@ step = $max / 10\n" ++
                "if ( $step < 1 ) set step = 1\n" ++
                "switch ( \"$argv[1]\" )\n" ++
                "    case up:\n        @ new = $cur + $step\n        if ( $new > $max ) set new = $max\n        breaksw\n" ++
                "    case down:\n        @ new = $cur - $step\n        if ( $new < 0 ) set new = 0\n        breaksw\n" ++
                "    default:\n        /bin/echo \"usage: brightness.csh up|down\"\n        exit 64\n        breaksw\n" ++
                "endsw\n" ++
                "sysctl hw.backlight_level=$new\n";
            _ = try self.ensureTextFile(helper_path, helper, 0o755, .{ .uid = self.target_uid, .gid = self.target_gid, .home = self.target_home });
            try self.logger.log("OK", self.phase, "backlight-helper", try std.fmt.allocPrint(self.alloc, "installed user backlight helper at {s}", .{helper_path}));
        }

        try self.saveCheckpoint(9, "user-provisioning");
        try self.logger.log("OK", self.phase, "end", "user provisioning complete");
    }

    fn ensureVideoGroupMembership(self: *App) !void {
        const group_show = try self.runCmd(&.{ "pw", "groupshow", "video" });
        if (group_show.exitCode() != 0) {
            const add = try self.runCmd(&.{ "pw", "groupadd", "video" });
            if (add.exitCode() != 0) return self.fail(EXIT_CONFIG, "ensure-video-group", "failed to ensure video group exists", .{});
            try self.logger.log("OK", self.phase, "ensure-video-group", "created missing video group");
        }

        if (try self.userInGroup("video")) {
            try self.logger.log("SKIP", self.phase, "group-membership", try std.fmt.allocPrint(self.alloc, "{s} already in video group", .{self.args.username}));
            return;
        }

        const mod = try self.runCmd(&.{ "pw", "groupmod", "video", "-m", self.args.username });
        if (mod.exitCode() != 0) return self.fail(EXIT_CONFIG, "group-membership", "failed to add {s} to video group", .{self.args.username});
        self.group_changed = true;
        self.need_relogin = true;
        try self.logger.log("OK", self.phase, "group-membership", try std.fmt.allocPrint(self.alloc, "added {s} to video group", .{self.args.username}));
    }

    fn discoverGNUstepInit(self: *App) ![]const u8 {
        const candidates = [_][]const u8{
            "/usr/local/share/GNUstep/Makefiles/GNUstep.csh",
            "/usr/local/share/GNUstep/Makefiles/GNUstep-reset.csh",
            "/usr/local/share/GNUstep/Makefiles/GNUstep-local.csh",
            "/usr/local/GNUstep/System/Library/Makefiles/GNUstep.csh",
        };
        for (candidates) |path| {
            if (fileExists(path)) {
                try self.logger.log("OK", self.phase, "discover-gnustep-env", try std.fmt.allocPrint(self.alloc, "GNUstep csh init discovered at {s}", .{path}));
                return path;
            }
        }

        const pkg_info = try self.runCmd(&.{ "pkg", "info" });
        var lines = std.mem.splitScalar(u8, pkg_info.stdout, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "gnustep")) continue;
            const pkg_name = firstToken(line);
            const listing = try self.runCmd(&.{ "pkg", "info", "-l", pkg_name });
            var list_it = std.mem.splitScalar(u8, listing.stdout, '\n');
            while (list_it.next()) |entry| {
                if (entry.len == 0) continue;
                if (std.mem.indexOf(u8, entry, "GNUstep") != null and std.mem.endsWith(u8, entry, ".csh") and fileExists(entry)) {
                    try self.logger.log("OK", self.phase, "discover-gnustep-env", try std.fmt.allocPrint(self.alloc, "GNUstep csh init discovered at {s}", .{entry}));
                    return entry;
                }
            }
        }

        const found = try self.runCmd(&.{ "find", "/usr/local", "-type", "f", "(", "-name", "GNUstep*.csh", "-o", "-name", "GNUstep.csh", ")" });
        var found_it = std.mem.splitScalar(u8, found.stdout, '\n');
        while (found_it.next()) |entry| {
            if (entry.len == 0) continue;
            if (fileExists(entry)) {
                try self.logger.log("OK", self.phase, "discover-gnustep-env", try std.fmt.allocPrint(self.alloc, "GNUstep csh init discovered at {s}", .{entry}));
                return entry;
            }
        }

        return self.fail(EXIT_VALIDATION, "discover-gnustep-env", "GNUstep is installed but no csh-compatible GNUstep init script was found", .{});
    }

    fn phaseAudioConfiguration(self: *App) !void {
        self.phase = "phase10";
        if (self.shouldSkipByCheckpoint(10)) {
            try self.logger.log("SKIP", self.phase, "resume", "phase 10 already completed; skipping by checkpoint");
            return;
        }

        try self.logger.log("INFO", self.phase, "start", "audio configuration begins");
        const devices = try self.parseAudioDevices(try self.readSndstat());
        self.hardware.audio_device_count = devices.len;

        if (devices.len > 0) {
            if (self.hardware.audio_selected_unit.len == 0) {
                if (self.selectAudioDevice(devices)) |selected| {
                    self.hardware.audio_selected_unit = selected.unit;
                    self.hardware.audio_default_reason = selected.reason;
                }
            }
            if (self.hardware.audio_selected_unit.len > 0) {
                _ = try self.setSysctlRuntime("hw.snd.default_unit", self.hardware.audio_selected_unit);
                var found = false;
                for (devices) |dev| {
                    if (std.mem.eql(u8, dev.unit, self.hardware.audio_selected_unit)) {
                        found = true;
                        break;
                    }
                }
                if (!found) return self.fail(EXIT_VALIDATION, "validate-audio", "selected default audio device {s} not found in /dev/sndstat", .{self.hardware.audio_selected_unit});
            }
            const mix = try self.runCmd(&.{ "mixer" });
            if (mix.exitCode() == 0) {
                try self.logger.log("OK", self.phase, "validate-audio", "mixer access available for audio validation");
            } else {
                try self.logger.log("WARN", self.phase, "validate-audio", "mixer utility unavailable or inactive; sndstat validation used");
            }
        } else {
            try self.logger.log("WARN", self.phase, "select-default-audio", "no PCM devices detected; audio configuration limited to discovery logs");
        }

        try self.saveCheckpoint(10, "audio-configuration");
        try self.logger.log("OK", self.phase, "end", "audio configuration complete");
    }

    fn phaseVideoDisplayConfiguration(self: *App) !void {
        self.phase = "phase11";
        if (self.shouldSkipByCheckpoint(11)) {
            try self.logger.log("SKIP", self.phase, "resume", "phase 11 already completed; skipping by checkpoint");
            return;
        }

        try self.logger.log("INFO", self.phase, "start", "video and display configuration begins");
        if (std.mem.eql(u8, self.hardware.gpu_plan, "unknown-generic")) {
            try self.logger.log("WARN", self.phase, "drm-path", "GPU plan remains unknown-generic; keeping Xorg autodetection and no forced DRM modules");
        } else {
            try self.logger.log("OK", self.phase, "drm-path", try std.fmt.allocPrint(self.alloc, "GPU plan {s}; using Xorg autodetection with video group permissions", .{self.hardware.gpu_plan}));
        }

        if (!(fileExecutable("/usr/local/bin/Xorg") or fileExecutable("/usr/X11R6/bin/Xorg"))) {
            return self.fail(EXIT_VALIDATION, "validate-display", "Xorg binary not found after package installation", .{});
        }
        try self.logger.log("OK", self.phase, "validate-display", "Xorg binary present");

        if (!fileExecutable("/usr/local/bin/xdm")) {
            return self.fail(EXIT_VALIDATION, "validate-display", "XDM binary not found after package installation", .{});
        }
        try self.logger.log("OK", self.phase, "validate-display", "XDM binary present at /usr/local/bin/xdm");

        const xsession_path = try std.fmt.allocPrint(self.alloc, "{s}/.xsession", .{self.target_home});
        if (!fileExists(xsession_path)) return self.fail(EXIT_VALIDATION, "validate-display", "user session launcher {s} is missing", .{xsession_path});
        if (!try self.userInGroup("video")) return self.fail(EXIT_VALIDATION, "validate-display", "target user {s} is not in video group", .{self.args.username});
        if (!fileExists("/etc/X11/xorg.conf.d/00-keyboard.conf")) return self.fail(EXIT_VALIDATION, "validate-display", "keyboard config file /etc/X11/xorg.conf.d/00-keyboard.conf is missing", .{});

        try self.saveCheckpoint(11, "video-display-configuration");
        try self.logger.log("OK", self.phase, "end", "video and display configuration complete");
    }

    fn phaseXdmEnablement(self: *App) !void {
        self.phase = "phase12";
        if (self.shouldSkipByCheckpoint(12)) {
            try self.logger.log("SKIP", self.phase, "resume", "phase 12 already completed; skipping by checkpoint");
            return;
        }

        try self.logger.log("INFO", self.phase, "start", "XDM enablement begins");
        const xdm_check = try self.runCmd(&.{ "pkg", "info", "-e", self.packages.pkg_xdm });
        if (xdm_check.exitCode() != 0) return self.fail(EXIT_VALIDATION, "xdm-install", "XDM package {s} is not installed", .{self.packages.pkg_xdm});

        const ttys = self.readText("/etc/ttys") catch "";
        if (std.mem.indexOf(u8, ttys, "ttyv8\t\"/usr/local/bin/xdm -nodaemon\"\txterm\ton") == null) {
            return self.fail(EXIT_VALIDATION, "xdm-enable", "/etc/ttys is not configured for XDM on ttyv8", .{});
        }

        if (self.args.immediate_xdm) {
            std.posix.kill(1, std.posix.SIG.HUP) catch {
                self.xdm_mode = "SUCCESS_PENDING_REBOOT";
                self.need_reboot = true;
                try self.logger.log("WARN", self.phase, "xdm-activate", "immediate init reload failed; XDM remains pending reboot or manual init restart");
                try self.writeAtomicText(self.paths.reboot_required, "pending=1\nreason=desktop-refresh-needed\n");
                try self.saveCheckpoint(12, "xdm-enablement");
                try self.logger.log("OK", self.phase, "end", try std.fmt.allocPrint(self.alloc, "XDM enablement complete ({s})", .{self.xdm_mode}));
                return;
            };
            self.xdm_mode = "SUCCESS_ACTIVE";
            try self.logger.log("OK", self.phase, "xdm-activate", "init reloaded; XDM activation requested immediately");
        } else {
            self.xdm_mode = "SUCCESS_PENDING_REBOOT";
            self.need_reboot = true;
            try self.logger.log("WARN", self.phase, "xdm-activate", "conservative mode retained; XDM configured but pending reboot or manual init reload");
        }

        if (self.need_reboot or self.need_relogin) {
            try self.writeAtomicText(self.paths.reboot_required, "pending=1\nreason=desktop-refresh-needed\n");
        } else {
            std.fs.deleteFileAbsolute(self.paths.reboot_required) catch {};
        }

        try self.saveCheckpoint(12, "xdm-enablement");
        try self.logger.log("OK", self.phase, "end", try std.fmt.allocPrint(self.alloc, "XDM enablement complete ({s})", .{self.xdm_mode}));
    }

    fn finalValidation(self: *App) !void {
        self.phase = "final";
        try self.logger.log("INFO", self.phase, "validation", "final validation begins");

        _ = try self.lookupUser(self.args.username);
        if (!dirExists(self.target_home)) return self.fail(EXIT_VALIDATION, "final-validation", "target home {s} no longer exists", .{self.target_home});
        if (!try self.userInGroup("video")) return self.fail(EXIT_VALIDATION, "final-validation", "target user {s} is not in video group", .{self.args.username});

        const reqs = [_][]const u8{ self.packages.pkg_xorg, self.packages.pkg_xdm, self.packages.pkg_gnustep, self.packages.pkg_gnustep_back, self.packages.pkg_windowmaker };
        for (reqs) |pkg| {
            const check = try self.runCmd(&.{ "pkg", "info", "-e", pkg });
            if (check.exitCode() != 0) return self.fail(EXIT_VALIDATION, "final-validation", "required package {s} is missing at final validation", .{pkg});
        }

        const ttys = self.readText("/etc/ttys") catch "";
        if (std.mem.indexOf(u8, ttys, "ttyv8\t\"/usr/local/bin/xdm -nodaemon\"\txterm\ton") == null) {
            return self.fail(EXIT_VALIDATION, "final-validation", "/etc/ttys does not contain enabled XDM ttyv8 entry", .{});
        }

        if (!fileExists("/etc/X11/xorg.conf.d/00-keyboard.conf")) return self.fail(EXIT_VALIDATION, "final-validation", "keyboard config file missing", .{});
        const xsession_path = try std.fmt.allocPrint(self.alloc, "{s}/.xsession", .{self.target_home});
        if (!fileExists(xsession_path)) return self.fail(EXIT_VALIDATION, "final-validation", "user session file {s} missing", .{xsession_path});

        const sysctl_conf = self.readText("/etc/sysctl.conf") catch "";
        if (std.mem.indexOf(u8, sysctl_conf, BEGIN_MARK) == null) return self.fail(EXIT_VALIDATION, "final-validation", "managed sysctl block missing", .{});

        const devices = try self.parseAudioDevices(try self.readSndstat());
        if (devices.len > 0 and self.hardware.audio_selected_unit.len > 0) {
            var found = false;
            for (devices) |dev| {
                if (std.mem.eql(u8, dev.unit, self.hardware.audio_selected_unit)) {
                    found = true;
                    break;
                }
            }
            if (!found) return self.fail(EXIT_VALIDATION, "final-validation", "selected default audio device {s} missing at final validation", .{self.hardware.audio_selected_unit});
        }

        try self.writeJsonFile(self.paths.final_summary, .{
            .run_id = self.paths.run_id,
            .timestamp = self.nowStamp(),
            .target_user = self.args.username,
            .target_home = self.target_home,
            .keyboard_layout = self.args.keyboard,
            .gpu_plan = self.hardware.gpu_plan,
            .audio_profile = self.hardware.audio_profile,
            .audio_selected_unit = self.hardware.audio_selected_unit,
            .backlight_manageable = self.hardware.backlight_manageable,
            .xdm_mode = self.xdm_mode,
            .group_changed = self.group_changed,
            .need_relogin = self.need_relogin,
            .need_reboot = self.need_reboot,
            .logfile = self.paths.logfile,
            .version = VERSION,
        });
        try self.writeJsonFile(self.paths.last_run_file, .{
            .run_id = self.paths.run_id,
            .timestamp = self.nowStamp(),
            .target_user = self.args.username,
            .target_home = self.target_home,
            .keyboard_layout = self.args.keyboard,
            .gpu_plan = self.hardware.gpu_plan,
            .audio_profile = self.hardware.audio_profile,
            .audio_selected_unit = self.hardware.audio_selected_unit,
            .backlight_manageable = self.hardware.backlight_manageable,
            .xdm_mode = self.xdm_mode,
            .group_changed = self.group_changed,
            .need_relogin = self.need_relogin,
            .need_reboot = self.need_reboot,
            .logfile = self.paths.logfile,
            .version = VERSION,
        });
        try self.logger.log("OK", self.phase, "validation", try std.fmt.allocPrint(self.alloc, "final validation complete; summary written to {s}", .{self.paths.final_summary}));
    }
};

fn printUsage() void {
    std.debug.print(
        "usage: {s}.zig --username <name> --keyboard <kbd-layout> [--resume] [--force] [--verbose] [--skip-upgrade] [--immediate-xdm]\n" ++
            "\n" ++
            "Run directly with Zig 0.12:\n" ++
            "  zig run turkishvan-bsd.zig -- --username alice --keyboard us\n" ++
            "\n" ++
            "Build a standalone binary:\n" ++
            "  zig build-exe -O ReleaseSafe turkishvan-bsd.zig\n",
        .{SCRIPT_NAME},
    );
}

fn parseArgs(alloc: std.mem.Allocator) !Args {
    var out = Args{ .username = "", .keyboard = "" };
    var it = try std.process.argsWithAllocator(alloc);
    defer it.deinit();
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--username")) {
            out.username = it.next() orelse return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--keyboard")) {
            out.keyboard = it.next() orelse return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--resume")) {
            out.resume = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            out.force = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            out.verbose = true;
        } else if (std.mem.eql(u8, arg, "--skip-upgrade")) {
            out.skip_upgrade = true;
        } else if (std.mem.eql(u8, arg, "--immediate-xdm")) {
            out.immediate_xdm = true;
        } else {
            return error.InvalidArgs;
        }
    }
    if (out.username.len == 0 or out.keyboard.len == 0) return error.InvalidArgs;
    return out;
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const args = parseArgs(alloc) catch {
        printUsage();
        std.process.exit(EXIT_USAGE);
    };

    var app = try App.init(alloc, args);
    defer app.lock.release();

    const code = app.run() catch |err| switch (err) {
        error.Fatal => blk: {
            app.logger.log("ERROR", "fatal", app.fatal_step, app.fatal_message) catch {};
            break :blk app.fatal_code;
        },
        else => blk: {
            app.logger.log("ERROR", "fatal", "unexpected", @errorName(err)) catch {};
            break :blk EXIT_INTERNAL;
        },
    };
    std.process.exit(code);
}

fn ensureDir(path: []const u8) !void {
    try std.fs.cwd().makePath(path);
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn dirExists(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

fn fileExecutable(path: []const u8) bool {
    if (!fileExists(path)) return false;
    const zpath = std.cstr.addNullByte(std.heap.page_allocator, path) catch return false;
    defer std.heap.page_allocator.free(zpath);
    return c.access(zpath.ptr, c.X_OK) == 0;
}

fn chmodPath(path: []const u8, mode: u32) !void {
    const zpath = try std.cstr.addNullByte(std.heap.page_allocator, path);
    defer std.heap.page_allocator.free(zpath);
    if (c.chmod(zpath.ptr, mode) != 0) return error.AccessDenied;
}

fn chownPath(path: []const u8, uid: u32, gid: u32) !void {
    const zpath = try std.cstr.addNullByte(std.heap.page_allocator, path);
    defer std.heap.page_allocator.free(zpath);
    if (c.chown(zpath.ptr, uid, gid) != 0) return error.AccessDenied;
}

fn makeRunId(alloc: std.mem.Allocator) ![]const u8 {
    const stamp = try makeCompactTimestamp(alloc);
    return std.fmt.allocPrint(alloc, "{s}-{d}", .{ stamp, std.posix.getpid() });
}

fn makeCompactTimestamp(alloc: std.mem.Allocator) ![]const u8 {
    var now: c.time_t = c.time(null);
    var tm: c.struct_tm = undefined;
    _ = c.gmtime_r(&now, &tm);
    var buf: [32]u8 = undefined;
    const len = c.strftime(&buf[0], buf.len, "%Y%m%dT%H%M%SZ", &tm);
    return alloc.dupe(u8, buf[0..len]);
}

fn isoTimestamp(buf: *[32]u8) []const u8 {
    var now: c.time_t = c.time(null);
    var tm: c.struct_tm = undefined;
    _ = c.gmtime_r(&now, &tm);
    const len = c.strftime(&buf[0], buf.len, "%Y-%m-%dT%H:%M:%SZ", &tm);
    return buf[0..len];
}

fn getHostnameShort(alloc: std.mem.Allocator) ![]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "hostname", "-s" },
        .max_output_bytes = 4096,
    });
    const text = switch (result.term) {
        .Exited => |code| if (code == 0) std.mem.trim(u8, result.stdout, " \t\r\n") else "localhost",
        else => "localhost",
    };
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse text.len;
    return alloc.dupe(u8, if (dot > 0) text[0..dot] else text);
}

fn encodePath(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    var list = std.ArrayList(u8).init(alloc);
    for (path) |ch| {
        try list.append(if (ch == '/') '_' else ch);
    }
    while (list.items.len > 0 and list.items[0] == '_') {
        _ = list.orderedRemove(0);
    }
    return list.toOwnedSlice();
}

fn firstLine(text: []const u8) []const u8 {
    const idx = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return std.mem.trim(u8, text[0..idx], " \t\r\n");
}

fn firstToken(text: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    return it.next() orelse "unknown";
}

fn allDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn isSpaceOrTab(line: []const u8, idx: usize) bool {
    if (idx >= line.len) return false;
    return line[idx] == ' ' or line[idx] == '\t';
}
