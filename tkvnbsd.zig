const std = @import("std");
const c = @cImport({
    @cInclude("ncurses.h");
    @cInclude("pwd.h");
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/types.h");
    @cInclude("sys/stat.h");
});

const Allocator = std.mem.Allocator;

const LOG_PATH = "/var/log/tkvnbsd.log";
const STATE_PATH = "/var/tmp/tkvnbsd.state";
const SYSCTL_CONF = "/etc/sysctl.conf";
const RC_CONF = "/etc/rc.conf";
const LOADER_CONF = "/boot/loader.conf";
const XKB_CONF = "/usr/local/etc/X11/xorg.conf.d/00-keyboard-tkvnbsd.conf";
const LIBINPUT_CONF = "/usr/local/etc/X11/xorg.conf.d/20-libinput-tkvnbsd.conf";
const XDM_XSETUP = "/usr/local/etc/X11/xdm/Xsetup_0";
const XDM_XSESSION = "/usr/local/etc/X11/xdm/Xsession";
const XDM_XSERVERS = "/usr/local/etc/X11/xdm/Xservers";
const TTYS_PATH = "/etc/ttys";

const MarkerBegin = "# BEGIN TKVNBSD";
const MarkerEnd = "# END TKVNBSD";

const GpuVendor = enum {
    intel,
    amd,
    nvidia,
    vm,
    unknown,
};

const MachineKind = enum {
    desktop,
    laptop,
    vm,
};

const Step = enum {
    none,
    preflight,
    detect,
    sysctl,
    packages,
    drivers,
    xdm,
    vtwm,
    probe,
    validate,
    done,
};

const SysctlEntry = struct {
    key: []const u8,
    value: []const u8,
};

const CmdResult = struct {
    code: i32,
    out: []u8,
};

const HardwareInfo = struct {
    gpu: GpuVendor = .unknown,
    audio_present: bool = false,
    machine: MachineKind = .desktop,
    low_memory: bool = false,
    physmem_bytes: u64 = 0,

    fn profile(self: HardwareInfo) []const u8 {
        if (self.machine == .vm or self.low_memory) return "safe";
        return "desktop";
    }
};

const ValidationResult = struct {
    ok: bool = true,
    warnings: usize = 0,
};

const PackageDecision = enum {
    stop,
    retry,
    ignore,
};

const AppState = struct {
    allocator: Allocator,
    username: ?[]u8 = null,
    keyboard: ?[]u8 = null,
    home_dir: ?[]u8 = null,
    uid: c.uid_t = 0,
    gid: c.gid_t = 0,
    hw: HardwareInfo = .{},
    last_completed: Step = .none,
    current_step: Step = .none,
    current_action: [256]u8 = [_]u8{0} ** 256,
    current_action_len: usize = 0,
    current_command: [384]u8 = [_]u8{0} ** 384,
    current_command_len: usize = 0,
    last_status: [256]u8 = [_]u8{0} ** 256,
    last_status_len: usize = 0,
    warnings: std.array_list.Managed([]u8),
    installed_packages: std.array_list.Managed([]u8),
    probe_notes: std.array_list.Managed([]u8),
    checksum_enabled: bool = true,

    fn init(allocator: Allocator) AppState {
        return .{
            .allocator = allocator,
            .warnings = std.array_list.Managed([]u8).init(allocator),
            .installed_packages = std.array_list.Managed([]u8).init(allocator),
            .probe_notes = std.array_list.Managed([]u8).init(allocator),
        };
    }

    fn deinit(self: *AppState) void {
        if (self.username) |v| self.allocator.free(v);
        if (self.keyboard) |v| self.allocator.free(v);
        if (self.home_dir) |v| self.allocator.free(v);
        for (self.warnings.items) |w| self.allocator.free(w);
        self.warnings.deinit();
        for (self.installed_packages.items) |pkg| self.allocator.free(pkg);
        self.installed_packages.deinit();
        for (self.probe_notes.items) |note| self.allocator.free(note);
        self.probe_notes.deinit();
    }
};

const pkgs_core = [_][]const u8{
    "xorg",
    "xdm",
    "vtwm",
    "xterm",
    "xauth",
    "dejavu",
};

const pkgs_audio = [_][]const u8{
    "pulseaudio",
    "pavucontrol",
};

const pkgs_input = [_][]const u8{
    "libinput",
    "xf86-input-libinput",
    "setxkbmap",
};

const pkgs_video_intel = [_][]const u8{
    "drm-kmod",
    "xf86-video-intel",
};

const pkgs_video_amd = [_][]const u8{
    "drm-kmod",
};

const pkgs_video_nvidia = [_][]const u8{
    "nvidia-driver",
    "nvidia-settings",
};

const pkgs_video_vm = [_][]const u8{
    "xf86-video-vesa",
};

const pkgs_video_generic = [_][]const u8{
    "xf86-video-vesa",
};

const pkgs_utils = [_][]const u8{
    "nano",
    "vim-console",
    "tmux",
    "htop",
    "rsync",
    "zip",
    "unzip",
    "p7zip",
};

const pkgs_productivity = [_][]const u8{
    "firefox",
    "libreoffice",
    "evince",
};

const pkgs_multimedia = [_][]const u8{
    "mpv",
    "vlc",
};

const safe_sysctls = [_]SysctlEntry{
    .{ .key = "kern.ipc.shm_allow_removed", .value = "1" },
    .{ .key = "hw.snd.maxautovchans", .value = "2" },
    .{ .key = "vfs.usermount", .value = "1" },
    .{ .key = "net.local.stream.recvspace", .value = "65536" },
    .{ .key = "net.local.stream.sendspace", .value = "65536" },
};

const desktop_sysctls = [_]SysctlEntry{
    .{ .key = "kern.ipc.shm_allow_removed", .value = "1" },
    .{ .key = "hw.snd.maxautovchans", .value = "4" },
    .{ .key = "vfs.usermount", .value = "1" },
    .{ .key = "net.local.stream.recvspace", .value = "131072" },
    .{ .key = "net.local.stream.sendspace", .value = "131072" },
};

fn stepName(step: Step) []const u8 {
    return switch (step) {
        .none => "none",
        .preflight => "preflight",
        .detect => "detect",
        .sysctl => "sysctl",
        .packages => "packages",
        .drivers => "drivers",
        .xdm => "xdm",
        .vtwm => "vtwm",
        .probe => "probe",
        .validate => "validate",
        .done => "done",
    };
}

fn stepFromName(name: []const u8) Step {
    inline for ([_]Step{ .none, .preflight, .detect, .sysctl, .packages, .drivers, .xdm, .vtwm, .probe, .validate, .done }) |s| {
        if (std.mem.eql(u8, name, stepName(s))) return s;
    }
    return .none;
}

fn gpuName(gpu: GpuVendor) []const u8 {
    return switch (gpu) {
        .intel => "Intel",
        .amd => "AMD",
        .nvidia => "NVIDIA",
        .vm => "Virtual/VM",
        .unknown => "Unknown",
    };
}

fn machineName(kind: MachineKind) []const u8 {
    return switch (kind) {
        .desktop => "desktop",
        .laptop => "laptop",
        .vm => "vm",
    };
}

fn nextStepAfter(step: Step) Step {
    return switch (step) {
        .none => .sysctl,
        .preflight => .sysctl,
        .detect => .sysctl,
        .sysctl => .packages,
        .packages => .drivers,
        .drivers => .xdm,
        .xdm => .vtwm,
        .vtwm => .probe,
        .probe => .validate,
        .validate => .done,
        .done => .done,
    };
}

fn fatalScreen(msg: []const u8) noreturn {
    _ = c.endwin();
    std.debug.print("{s}\n", .{msg});
    std.process.exit(1);
}

fn uiPrint(row: i32, col: i32, text: []const u8) void {
    _ = c.mvaddnstr(row, col, text.ptr, @as(c_int, @intCast(text.len)));
}

fn uiPrintf(row: i32, col: i32, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    uiPrint(row, col, s);
}

fn centerText(row: i32, text: []const u8) void {
    const cols = c.COLS;
    const start = @max(0, @divTrunc(cols - @as(c_int, @intCast(text.len)), 2));
    uiPrint(row, start, text);
}

fn drawFrame(title: []const u8) void {
    _ = c.erase();
    _ = c.box(c.stdscr, 0, 0);
    centerText(1, title);
    uiPrint(c.LINES - 2, 2, "Enter continue/edit  Tab/arrows move  q quit  l log path  r retry when available");
    _ = c.refresh();
}

fn drawProgress(app: *AppState) void {
    drawFrame("tkvnbsd - progress");
    uiPrintf(3, 4, "Step: {s}", .{stepName(app.current_step)});
    uiPrintf(5, 4, "Action: {s}", .{app.current_action[0..app.current_action_len]});
    uiPrintf(7, 4, "Command: {s}", .{app.current_command[0..app.current_command_len]});
    uiPrintf(9, 4, "Status: {s}", .{app.last_status[0..app.last_status_len]});
    uiPrintf(11, 4, "Log: {s}", .{LOG_PATH});
    if (app.username) |u| uiPrintf(13, 4, "User: {s}", .{u});
    if (app.keyboard) |k| uiPrintf(14, 4, "Keyboard: {s}", .{k});
    _ = c.refresh();
}

fn setAction(app: *AppState, step: Step, action: []const u8) void {
    app.current_step = step;
    app.current_action_len = @min(app.current_action.len, action.len);
    std.mem.copyForwards(u8, app.current_action[0..app.current_action_len], action[0..app.current_action_len]);
    if (app.current_action_len < app.current_action.len) app.current_action[app.current_action_len] = 0;
    app.current_command_len = 0;
    setStatus(app, "running");
}

fn setCommand(app: *AppState, command: []const u8) void {
    app.current_command_len = @min(app.current_command.len, command.len);
    std.mem.copyForwards(u8, app.current_command[0..app.current_command_len], command[0..app.current_command_len]);
    if (app.current_command_len < app.current_command.len) app.current_command[app.current_command_len] = 0;
    drawProgress(app);
}

fn setStatus(app: *AppState, status: []const u8) void {
    app.last_status_len = @min(app.last_status.len, status.len);
    std.mem.copyForwards(u8, app.last_status[0..app.last_status_len], status[0..app.last_status_len]);
    if (app.last_status_len < app.last_status.len) app.last_status[app.last_status_len] = 0;
    drawProgress(app);
}

fn trimAscii(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn setOwnedString(allocator: Allocator, slot: *?[]u8, value: []const u8) !void {
    if (slot.*) |old| allocator.free(old);
    slot.* = try allocator.dupe(u8, value);
}

fn appendWarning(app: *AppState, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(app.allocator, fmt, args);
    try app.warnings.append(msg);
    try writeLog(app, .validate, msg);
}

fn appendProbeNote(app: *AppState, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(app.allocator, fmt, args);
    try app.probe_notes.append(msg);
    try writeLog(app, .probe, msg);
}

fn appendInstalledPackage(app: *AppState, pkg: []const u8) !void {
    for (app.installed_packages.items) |existing| {
        if (std.mem.eql(u8, existing, pkg)) return;
    }
    try app.installed_packages.append(try app.allocator.dupe(u8, pkg));
}

fn packageFailurePrompt(pkg: []const u8, detail: []const u8) PackageDecision {
    drawFrame("tkvnbsd - package failure");
    uiPrintf(3, 4, "Package failed: {s}", .{pkg});
    uiPrintf(4, 4, "Log: {s}", .{LOG_PATH});
    uiPrint(6, 4, "Failure details:");

    var row: i32 = 7;
    var lines = std.mem.splitScalar(u8, detail, '\n');
    var shown: usize = 0;
    while (lines.next()) |line| {
        const t = trimAscii(line);
        if (t.len == 0) continue;
        const clipped = if (t.len > 72) t[0..72] else t;
        uiPrintf(row, 6, "{s}", .{clipped});
        row += 1;
        shown += 1;
        if (shown >= 8 or row >= c.LINES - 6) break;
    }
    if (shown == 0) {
        uiPrint(row, 6, "No details returned by pkg.");
        row += 1;
    }

    uiPrint(c.LINES - 5, 4, "Choose: r retry  i ignore and continue  s stop installation  l show log path");
    _ = c.refresh();

    while (true) {
        const ch = c.getch();
        switch (ch) {
            'r', 'R', 10, 13, c.KEY_ENTER => return .retry,
            'i', 'I' => return .ignore,
            's', 'S', 'q', 'Q' => return .stop,
            'l', 'L' => {
                uiPrintf(c.LINES - 4, 4, "Log path: {s}", .{LOG_PATH});
                _ = c.refresh();
            },
            else => {},
        }
    }
}


fn runBestEffort(app: *AppState, step: Step, action: []const u8, command: []const u8) !void {
    const res = try runCommand(app, step, action, command);
    defer app.allocator.free(res.out);
    if (res.code != 0) {
        try appendWarning(app, "{s} failed: {s}", .{ action, trimAscii(res.out) });
    }
}

fn ensureUserInGroup(app: *AppState, step: Step, group: []const u8) !void {
    const user = app.username.?;
    const check_cmd = try std.fmt.allocPrint(app.allocator, "id -Gn {s}", .{user});
    defer app.allocator.free(check_cmd);
    const check = try runCapture(app.allocator, check_cmd);
    defer app.allocator.free(check.out);
    if (check.code == 0) {
        var it = std.mem.tokenizeAny(u8, trimAscii(check.out), " \t\r\n");
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, group)) return;
        }
    }
    const mod_cmd = try std.fmt.allocPrint(app.allocator, "pw groupmod {s} -m {s}", .{ group, user });
    defer app.allocator.free(mod_cmd);
    const res = try runCommand(app, step, "adding user to desktop group", mod_cmd);
    defer app.allocator.free(res.out);
    if (res.code != 0) return error.GroupModifyFailed;
}

fn ensureExecutable(app: *AppState, step: Step, path: []const u8) !void {
    const cmd = try std.fmt.allocPrint(app.allocator, "chmod 755 '{s}'", .{path});
    defer app.allocator.free(cmd);
    const res = try runCommand(app, step, "marking file executable", cmd);
    defer app.allocator.free(res.out);
    if (res.code != 0) return error.ChmodFailed;
}

fn pkgIntegrityCheck(app: *AppState, pkg: []const u8) !void {
    const checksum_cmd = try std.fmt.allocPrint(app.allocator, "pkg check -q -s {s}", .{pkg});
    defer app.allocator.free(checksum_cmd);
    const checksum = try runCapture(app.allocator, checksum_cmd);
    defer app.allocator.free(checksum.out);
    if (checksum.code != 0) {
        try appendWarning(app, "package checksum verification failed for {s}", .{pkg});
    }

    const dep_cmd = try std.fmt.allocPrint(app.allocator, "pkg check -n -d {s}", .{pkg});
    defer app.allocator.free(dep_cmd);
    const dep = try runCapture(app.allocator, dep_cmd);
    defer app.allocator.free(dep.out);
    if (dep.code != 0) {
        try appendWarning(app, "package dependency verification reported issues for {s}", .{pkg});
    }
}

fn groupHasUser(app: *AppState, group: []const u8) !bool {
    const user = app.username.?;
    const check_cmd = try std.fmt.allocPrint(app.allocator, "id -Gn {s}", .{user});
    defer app.allocator.free(check_cmd);
    const check = try runCapture(app.allocator, check_cmd);
    defer app.allocator.free(check.out);
    if (check.code != 0) return false;
    var it = std.mem.tokenizeAny(u8, trimAscii(check.out), " \t\r\n");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, group)) return true;
    }
    return false;
}

fn groupExists(allocator: Allocator, group: []const u8) !bool {
    const cmd = try std.fmt.allocPrint(allocator, "pw groupshow {s}", .{group});
    defer allocator.free(cmd);
    const res = try runCapture(allocator, cmd);
    defer allocator.free(res.out);
    return res.code == 0;
}

fn ensureOptionalGroup(app: *AppState, step: Step, group: []const u8) !void {
    if (!(try groupExists(app.allocator, group))) return;
    try ensureUserInGroup(app, step, group);
}

fn buildDesktopRcBody(app: *AppState) ![]u8 {
    const webcamd_enabled = try pkgInstalled(app, "webcamd");
    const webcamd_line = if (webcamd_enabled) "webcamd_enable=\"YES\"\n" else "";
    const powerd_flags = if (app.hw.machine == .laptop)
        "powerd_enable=\"YES\"\npowerd_flags=\"-a hiadaptive -b adaptive -i 25 -r 85 -N\"\n"
    else
        "powerd_enable=\"YES\"\npowerd_flags=\"-a hiadaptive -n hiadaptive -i 25 -r 85 -N\"\n";
    const kld_line = if (driverModuleName(app.hw.gpu)) |modname|
        try std.fmt.allocPrint(app.allocator, "kld_list=\"${{kld_list}} {s}\"\n", .{modname})
    else
        try app.allocator.dupe(u8, "");

    defer app.allocator.free(kld_line);

    return try std.fmt.allocPrint(app.allocator,
        "xdm_enable=\"YES\"\ndbus_enable=\"YES\"\nhald_enable=\"YES\"\nmixer_enable=\"YES\"\n{s}{s}{s}",
        .{ webcamd_line, powerd_flags, kld_line },
    );
}

fn driverModuleName(gpu: GpuVendor) ?[]const u8 {
    return switch (gpu) {
        .intel => "i915kms",
        .amd => "amdgpu",
        .nvidia => "nvidia",
        .vm, .unknown => null,
    };
}

fn startServiceIfPresent(app: *AppState, step: Step, name: []const u8) !void {
    const local_path = try std.fmt.allocPrint(app.allocator, "/usr/local/etc/rc.d/{s}", .{name});
    defer app.allocator.free(local_path);
    const base_path = try std.fmt.allocPrint(app.allocator, "/etc/rc.d/{s}", .{name});
    defer app.allocator.free(base_path);
    if (!fileExists(local_path) and !fileExists(base_path)) return;

    const cmd = try std.fmt.allocPrint(app.allocator, "service {s} onestart", .{name});
    defer app.allocator.free(cmd);
    try runBestEffort(app, step, "starting desktop service", cmd);
}

fn ensureAllTtysXdmDisabled(app: *AppState, step: Step) !void {
    var existing_opt: ?[]u8 = null;
    if (fileExists(TTYS_PATH)) {
        existing_opt = try readFileAlloc(app.allocator, TTYS_PATH, 1024 * 1024);
    }
    defer if (existing_opt) |existing| app.allocator.free(existing);
    const existing = existing_opt orelse "";

    var out = std.array_list.Managed(u8).init(app.allocator);
    defer out.deinit();

    var lines = std.mem.splitScalar(u8, existing, '
');
    while (lines.next()) |line| {
        const trimmed_left = std.mem.trimLeft(u8, line, " 	");
        if (std.mem.startsWith(u8, trimmed_left, "ttyv") and std.mem.indexOf(u8, trimmed_left, "/usr/local/bin/xdm -nodaemon") != null) {
            var fields = std.mem.tokenizeAny(u8, trimmed_left, " 	");
            const tty_name = fields.next() orelse "ttyv8";
            const new_line = try std.fmt.allocPrint(app.allocator, "{s}   \"/usr/local/bin/xdm -nodaemon\"  xterm   off secure", .{tty_name});
            defer app.allocator.free(new_line);
            try out.writer().print("{s}
", .{new_line});
        } else if (line.len > 0) {
            try out.writer().print("{s}
", .{line});
        }
    }

    const new_content = try out.toOwnedSlice();
    defer app.allocator.free(new_content);

    if (existing.len > 0 and std.mem.eql(u8, trimAscii(existing), trimAscii(new_content))) return;
    try backupFile(app, TTYS_PATH, step);
    try writeFile(TTYS_PATH, new_content);
}

fn anyTtysXdmEntryEnabled(app: *AppState) !bool {
    if (!fileExists(TTYS_PATH)) return false;
    const content = try readFileAlloc(app.allocator, TTYS_PATH, 1024 * 1024);
    defer app.allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '
');
    while (lines.next()) |line| {
        const trimmed_left = std.mem.trimLeft(u8, line, " 	");
        if (trimmed_left.len == 0 or trimmed_left[0] == '#') continue;
        if (std.mem.indexOf(u8, trimmed_left, "/usr/local/bin/xdm -nodaemon") != null and
            std.mem.indexOf(u8, trimmed_left, " off ") == null)
            return true;
    }
    return false;
}

fn fileContains(path: []const u8, needle: []const u8, allocator: Allocator) !bool {
    if (!fileExists(path)) return false;
    const content = try readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(content);
    return std.mem.indexOf(u8, content, needle) != null;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn ensureDir(path: []const u8) !void {
    const cmd = try std.fmt.allocPrint(std.heap.page_allocator, "mkdir -p '{s}'", .{path});
    defer std.heap.page_allocator.free(cmd);
    const res = try runCapture(std.heap.page_allocator, cmd);
    defer std.heap.page_allocator.free(res.out);
    if (res.code != 0) return error.MakeDirFailed;
}

fn readFileAlloc(allocator: Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, max_bytes);
}

fn writeFile(path: []const u8, data: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true, .read = true });
    defer file.close();
    try file.writeAll(data);
}

fn writeFileIfDifferent(app: *AppState, step: Step, path: []const u8, data: []const u8) !bool {
    if (fileExists(path)) {
        const existing = try readFileAlloc(app.allocator, path, 1024 * 1024);
        defer app.allocator.free(existing);
        if (std.mem.eql(u8, trimAscii(existing), trimAscii(data))) return false;
        try backupFile(app, path, step);
    }
    try writeFile(path, data);
    return true;
}

fn backupFile(app: *AppState, path: []const u8, step: Step) !void {
    if (!fileExists(path)) return;
    const cmd = try std.fmt.allocPrint(app.allocator, "cp -p '{s}' '{s}.bak'", .{ path, path });
    defer app.allocator.free(cmd);
    const res = try runCommand(app, step, "backing up file", cmd);
    defer app.allocator.free(res.out);
    if (res.code != 0) return error.BackupFailed;
}

fn replaceManagedBlock(app: *AppState, step: Step, path: []const u8, body: []const u8) !bool {
    var existing_opt: ?[]u8 = null;
    if (fileExists(path)) {
        existing_opt = try readFileAlloc(app.allocator, path, 1024 * 1024);
    }
    defer if (existing_opt) |existing| {
        app.allocator.free(existing);
    };
    const existing = existing_opt orelse "";

    const desired_block = try std.fmt.allocPrint(app.allocator, "{s}\n{s}\n{s}\n", .{ MarkerBegin, trimAscii(body), MarkerEnd });
    defer app.allocator.free(desired_block);

    var out = std.array_list.Managed(u8).init(app.allocator);
    defer out.deinit();

    if (existing.len == 0) {
        try out.appendSlice(desired_block);
    } else if (std.mem.indexOf(u8, existing, MarkerBegin)) |start| {
        const end_marker_index = std.mem.indexOfPos(u8, existing, start, MarkerEnd) orelse return error.ManagedBlockCorrupt;
        const end_after = end_marker_index + MarkerEnd.len;
        try out.appendSlice(existing[0..start]);
        if (start > 0 and existing[start - 1] != '\n') try out.append('\n');
        try out.appendSlice(desired_block);
        if (end_after < existing.len and existing[end_after] != '\n') try out.append('\n');
        try out.appendSlice(existing[@min(existing.len, end_after + @as(usize, if (end_after < existing.len and existing[end_after] == '\n') 1 else 0))..]);
    } else {
        try out.appendSlice(existing);
        if (existing.len > 0 and existing[existing.len - 1] != '\n') try out.append('\n');
        try out.append('\n');
        try out.appendSlice(desired_block);
    }

    const new_content = try out.toOwnedSlice();
    defer app.allocator.free(new_content);

    if (existing.len > 0 and std.mem.eql(u8, trimAscii(existing), trimAscii(new_content))) {
        return false;
    }

    try backupFile(app, path, step);
    try writeFile(path, new_content);
    return true;
}

fn ensureManagedOrMissingFile(app: *AppState, step: Step, path: []const u8, content: []const u8) !bool {
    if (!fileExists(path)) {
        try writeFile(path, content);
        return true;
    }
    const existing = try readFileAlloc(app.allocator, path, 1024 * 1024);
    defer app.allocator.free(existing);
    if (std.mem.indexOf(u8, existing, MarkerBegin) != null) {
        if (std.mem.eql(u8, trimAscii(existing), trimAscii(content))) return false;
        try backupFile(app, path, step);
        try writeFile(path, content);
        return true;
    }
    if (std.mem.eql(u8, trimAscii(existing), trimAscii(content))) return false;
    return false;
}

fn ensureFileIfMissing(app: *AppState, path: []const u8, content: []const u8) !bool {
    _ = app;
    if (fileExists(path)) return false;
    try writeFile(path, content);
    return true;
}

fn chownUser(path: []const u8, uid: c.uid_t, gid: c.gid_t) !void {
    const zpath = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(zpath);
    if (c.chown(zpath.ptr, uid, gid) != 0) return error.ChownFailed;
}

fn writeLog(app: *AppState, step: Step, message: []const u8) !void {
    const ts_res = try runCapture(app.allocator, "date -u +%Y-%m-%dT%H:%M:%SZ");
    defer app.allocator.free(ts_res.out);
    const ts = trimAscii(ts_res.out);
    const line = try std.fmt.allocPrint(app.allocator, "{s} [{s}] {s}\n", .{ ts, stepName(step), trimAscii(message) });
    defer app.allocator.free(line);

    var file = std.fs.cwd().openFile(LOG_PATH, .{ .mode = .read_write }) catch try std.fs.cwd().createFile(LOG_PATH, .{ .truncate = false, .read = true });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(line);
}

fn runCapture(allocator: Allocator, command: []const u8) !CmdResult {
    const wrapped_tmp = try std.fmt.allocPrint(allocator, "{s} 2>&1", .{command});
    defer allocator.free(wrapped_tmp);
    const wrapped = try allocator.dupeZ(u8, wrapped_tmp);
    defer allocator.free(wrapped);

    const fp = c.popen(wrapped.ptr, "r");
    if (fp == null) return error.POpenFailed;

    var out = std.array_list.Managed(u8).init(allocator);
    var buf: [512]u8 = undefined;
    while (c.fgets(@as([*c]u8, @ptrCast(&buf)), @as(c_int, @intCast(buf.len)), fp) != null) {
        const line = std.mem.span(@as([*:0]u8, @ptrCast(&buf)));
        try out.appendSlice(line);
    }

    const status = c.pclose(fp);
    var code: i32 = status;
    if (status >= 0) code = @as(i32, @intCast((@as(u32, @bitCast(status)) >> 8) & 0xff));
    return .{ .code = code, .out = try out.toOwnedSlice() };
}

fn lastNonEmptyLine(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and (text[end - 1] == '\n' or text[end - 1] == '\r' or text[end - 1] == ' ' or text[end - 1] == '\t')) : (end -= 1) {}
    while (end > 0) {
        var start = end;
        while (start > 0 and text[start - 1] != '\n') : (start -= 1) {}
        const line = trimAscii(text[start..end]);
        if (line.len > 0) return line;
        if (start == 0) break;
        end = start - 1;
        while (end > 0 and (text[end - 1] == '\n' or text[end - 1] == '\r')) : (end -= 1) {}
    }
    return "";
}

fn runCommandMonitored(app: *AppState, step: Step, action: []const u8, command: []const u8) !CmdResult {
    setAction(app, step, action);
    setCommand(app, command);
    try writeLog(app, step, action);
    const cmd_msg = try std.fmt.allocPrint(app.allocator, "command: {s}", .{command});
    defer app.allocator.free(cmd_msg);
    try writeLog(app, step, cmd_msg);

    const stamp = std.time.nanoTimestamp();
    const script_path = try std.fmt.allocPrint(app.allocator, "/var/tmp/tkvnbsd-{d}.sh", .{stamp});
    defer app.allocator.free(script_path);
    const out_path = try std.fmt.allocPrint(app.allocator, "/var/tmp/tkvnbsd-{d}.out", .{stamp});
    defer app.allocator.free(out_path);
    const rc_path = try std.fmt.allocPrint(app.allocator, "/var/tmp/tkvnbsd-{d}.rc", .{stamp});
    defer app.allocator.free(rc_path);

    const script_body = try std.fmt.allocPrint(app.allocator,
        "#!/bin/sh\n({s}) > {s} 2>&1\nrc=$?\nprintf '%s\\n' \"$rc\" > {s}\n",
        .{ command, out_path, rc_path }
    );
    defer app.allocator.free(script_body);
    try writeFile(script_path, script_body);

    const launch_cmd = try std.fmt.allocPrint(app.allocator, "sh {s} >/dev/null 2>&1 &", .{script_path});
    defer app.allocator.free(launch_cmd);
    const launch = try runCapture(app.allocator, launch_cmd);
    defer app.allocator.free(launch.out);
    if (launch.code != 0) return error.CommandLaunchFailed;

    const spinners = [_][]const u8{ "|", "/", "-", "\\" };
    var spin_idx: usize = 0;
    const start_ns = std.time.nanoTimestamp();

    while (!fileExists(rc_path)) {
        var detail_copy: ?[]u8 = null;
        defer if (detail_copy) |buf| app.allocator.free(buf);

        var detail: []const u8 = "";
        if (fileExists(out_path)) {
            const partial = readFileAlloc(app.allocator, out_path, 1024 * 1024) catch null;
            if (partial) |p| {
                defer app.allocator.free(p);
                const last = lastNonEmptyLine(p);
                if (last.len > 0) {
                    detail_copy = try app.allocator.dupe(u8, last);
                    detail = detail_copy.?;
                }
            }
        }
        const elapsed_s = @divTrunc(std.time.nanoTimestamp() - start_ns, std.time.ns_per_s);
        const status = if (detail.len > 0)
            try std.fmt.allocPrint(app.allocator, "running {s} {d}s :: {s}", .{ spinners[spin_idx], elapsed_s, detail })
        else
            try std.fmt.allocPrint(app.allocator, "running {s} {d}s", .{ spinners[spin_idx], elapsed_s });
        defer app.allocator.free(status);
        setStatus(app, status);
        spin_idx = (spin_idx + 1) % spinners.len;
        std.Thread.sleep(250 * std.time.ns_per_ms);
    }

    const rc_text = try readFileAlloc(app.allocator, rc_path, 128);
    defer app.allocator.free(rc_text);
    const code = std.fmt.parseInt(i32, trimAscii(rc_text), 10) catch 1;

    const out = if (fileExists(out_path))
        try readFileAlloc(app.allocator, out_path, 8 * 1024 * 1024)
    else
        try app.allocator.dupe(u8, "");

    std.fs.cwd().deleteFile(script_path) catch {};
    std.fs.cwd().deleteFile(rc_path) catch {};
    std.fs.cwd().deleteFile(out_path) catch {};

    if (code == 0) {
        const ok_msg = try std.fmt.allocPrint(app.allocator, "ok: {s}", .{action});
        defer app.allocator.free(ok_msg);
        setStatus(app, "ok");
        try writeLog(app, step, ok_msg);
    } else {
        const fail_msg = try std.fmt.allocPrint(app.allocator, "failed ({d}): {s} :: {s}", .{ code, action, trimAscii(out) });
        defer app.allocator.free(fail_msg);
        setStatus(app, "failed");
        try writeLog(app, step, fail_msg);
    }

    return .{ .code = code, .out = out };
}

fn runCommand(app: *AppState, step: Step, action: []const u8, command: []const u8) !CmdResult {
    setAction(app, step, action);
    setCommand(app, command);
    try writeLog(app, step, action);
    const cmd_msg = try std.fmt.allocPrint(app.allocator, "command: {s}", .{command});
    defer app.allocator.free(cmd_msg);
    try writeLog(app, step, cmd_msg);
    const res = try runCapture(app.allocator, command);
    if (res.code == 0) {
        const ok_msg = try std.fmt.allocPrint(app.allocator, "ok: {s}", .{action});
        defer app.allocator.free(ok_msg);
        setStatus(app, "ok");
        try writeLog(app, step, ok_msg);
    } else {
        const fail_msg = try std.fmt.allocPrint(app.allocator, "failed ({d}): {s} :: {s}", .{ res.code, action, trimAscii(res.out) });
        defer app.allocator.free(fail_msg);
        setStatus(app, "failed");
        try writeLog(app, step, fail_msg);
    }
    return res;
}

fn waitForContinue(title: []const u8, body: []const []const u8) bool {
    drawFrame(title);
    var row: i32 = 4;
    for (body) |line| {
        uiPrint(row, 4, line);
        row += 1;
    }
    while (true) {
        const ch = c.getch();
        switch (ch) {
            'q' => return false,
            'l' => {
                uiPrintf(c.LINES - 4, 4, "Log path: {s}", .{LOG_PATH});
                _ = c.refresh();
            },
            10, 13, c.KEY_ENTER => return true,
            else => {},
        }
    }
}

fn promptText(app: *AppState, title: []const u8, label: []const u8, initial: ?[]const u8) ![]u8 {
    drawFrame(title);
    uiPrint(5, 4, label);
    if (initial) |v| uiPrintf(7, 4, "Current: {s}", .{v});
    uiPrint(9, 4, "Enter new value and press Enter:");
    _ = c.echo();
    _ = c.curs_set(1);
    var buf: [128]u8 = [_]u8{0} ** 128;
    _ = c.mvgetnstr(11, 4, @as([*c]u8, @ptrCast(&buf)), 127);
    _ = c.noecho();
    _ = c.curs_set(0);
    const value = trimAscii(std.mem.span(@as([*:0]u8, @ptrCast(&buf))));
    return try app.allocator.dupe(u8, value);
}

fn inputScreen(app: *AppState) !bool {
    var focus: usize = 0;
    while (true) {
        drawFrame("tkvnbsd - input");
        uiPrint(4, 4, "Provide the target desktop account, X11 keyboard layout, and optional package checksum behavior.");
        uiPrintf(7, 6, "[{s}] Username: {s}", .{ if (focus == 0) "*" else " ", if (app.username) |v| v else "<unset>" });
        uiPrintf(9, 6, "[{s}] Keyboard: {s}", .{ if (focus == 1) "*" else " ", if (app.keyboard) |v| v else "<unset>" });
        uiPrintf(11, 6, "[{s}] Package checksum verification: {s}", .{ if (focus == 2) "*" else " ", if (app.checksum_enabled) "enabled" else "disabled" });
        uiPrintf(13, 6, "[{s}] Continue", .{if (focus == 3) "*" else " "});
        _ = c.refresh();

        const ch = c.getch();
        switch (ch) {
            'q' => return false,
            'l' => {
                uiPrintf(c.LINES - 4, 4, "Log path: {s}", .{LOG_PATH});
                _ = c.refresh();
            },
            c.KEY_UP => focus = if (focus == 0) 3 else focus - 1,
            c.KEY_DOWN, 9 => focus = (focus + 1) % 4,
            10, 13, c.KEY_ENTER => {
                if (focus == 0) {
                    const entered = try promptText(app, "username", "Existing local username", app.username);
                    defer app.allocator.free(entered);
                    if (entered.len > 0) try setOwnedString(app.allocator, &app.username, entered);
                } else if (focus == 1) {
                    const entered = try promptText(app, "keyboard", "X11 keyboard layout", app.keyboard);
                    defer app.allocator.free(entered);
                    if (entered.len > 0) try setOwnedString(app.allocator, &app.keyboard, entered);
                } else if (focus == 2) {
                    app.checksum_enabled = !app.checksum_enabled;
                } else if (app.username != null and app.keyboard != null) {
                    return true;
                }
            },
            ' ' => {
                if (focus == 2) {
                    app.checksum_enabled = !app.checksum_enabled;
                }
            },
            else => {},
        }
    }
}
fn boolPrompt(title: []const u8, question: []const u8) bool {
    drawFrame(title);
    uiPrint(5, 4, question);
    uiPrint(7, 4, "Press y to continue with resume, n for a fresh run, q to quit.");
    while (true) {
        const ch = c.getch();
        switch (ch) {
            'y', 'Y' => return true,
            'n', 'N' => return false,
            'q' => return false,
            else => {},
        }
    }
}

fn screenDetection(app: *AppState) bool {
    drawFrame("tkvnbsd - detection");
    uiPrintf(4, 4, "Detected GPU: {s}", .{gpuName(app.hw.gpu)});
    uiPrintf(5, 4, "Audio present: {s}", .{if (app.hw.audio_present) "yes" else "no"});
    uiPrintf(6, 4, "Machine guess: {s}", .{machineName(app.hw.machine)});
    uiPrintf(7, 4, "Low memory: {s}", .{if (app.hw.low_memory) "yes" else "no"});
    uiPrintf(8, 4, "RAM bytes: {d}", .{app.hw.physmem_bytes});
    uiPrint(9, 4, "Selected stack: X11 + XDM + vtwm");
    uiPrintf(10, 4, "Sysctl profile: {s}", .{app.hw.profile()});
    while (true) {
        const ch = c.getch();
        switch (ch) {
            'q' => return false,
            'l' => {
                uiPrintf(c.LINES - 4, 4, "Log path: {s}", .{LOG_PATH});
                _ = c.refresh();
            },
            10, 13, c.KEY_ENTER => return true,
            else => {},
        }
    }
}

fn screenSummary(app: *AppState, resume_from: Step) bool {
    drawFrame("tkvnbsd - summary");
    uiPrintf(4, 4, "User: {s}", .{app.username.?});
    uiPrintf(5, 4, "Keyboard: {s}", .{app.keyboard.?});
    uiPrintf(6, 4, "Package checksum verification: {s}", .{if (app.checksum_enabled) "enabled" else "disabled"});
    uiPrintf(7, 4, "Resume from: {s}", .{stepName(resume_from)});
    uiPrint(9, 4, "The tool will:");
    uiPrint(10, 6, "- apply managed sysctl desktop tuning");
    uiPrint(11, 6, "- install desktop, productivity, and multimedia packages");
    uiPrint(12, 6, "- configure graphics/audio/input basics");
    uiPrint(13, 6, "- enable XDM");
    uiPrint(14, 6, "- create a vtwm session path for the target user when safe");
    uiPrint(15, 6, if (app.checksum_enabled) "- run package checksum verification" else "- skip package checksum verification");
    while (true) {
        const ch = c.getch();
        switch (ch) {
            'q' => return false,
            'l' => {
                uiPrintf(c.LINES - 4, 4, "Log path: {s}", .{LOG_PATH});
                _ = c.refresh();
            },
            10, 13, c.KEY_ENTER => return true,
            else => {},
        }
    }
}
fn saveState(app: *AppState, step: Step) !void {
    var data = std.array_list.Managed(u8).init(app.allocator);
    defer data.deinit();
    if (app.username) |u| try data.writer().print("username={s}\n", .{u});
    if (app.keyboard) |k| try data.writer().print("keyboard={s}\n", .{k});
    try data.writer().print("checksum_enabled={s}\n", .{if (app.checksum_enabled) "yes" else "no"});
    try data.writer().print("step={s}\nstatus=done\n", .{stepName(step)});
    const slice = try data.toOwnedSlice();
    defer app.allocator.free(slice);
    try writeFile(STATE_PATH, slice);
}
fn clearState() void {
    std.fs.cwd().deleteFile(STATE_PATH) catch {};
}

fn loadState(app: *AppState) !bool {
    if (!fileExists(STATE_PATH)) return false;
    const content = try readFileAlloc(app.allocator, STATE_PATH, 4096);
    defer app.allocator.free(content);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOfScalar(u8, line, '=')) |idx| {
            const key = line[0..idx];
            const value = line[idx + 1 ..];
            if (std.mem.eql(u8, key, "username")) try setOwnedString(app.allocator, &app.username, value)
            else if (std.mem.eql(u8, key, "keyboard")) try setOwnedString(app.allocator, &app.keyboard, value)
            else if (std.mem.eql(u8, key, "checksum_enabled")) app.checksum_enabled = std.mem.eql(u8, value, "yes")
            else if (std.mem.eql(u8, key, "step")) app.last_completed = stepFromName(value);
        }
    }
    return true;
}
fn fillUserInfo(app: *AppState) !void {
    const user = app.username orelse return error.MissingUsername;
    const zuser = try app.allocator.dupeZ(u8, user);
    defer app.allocator.free(zuser);
    const pwd = c.getpwnam(zuser.ptr) orelse return error.UnknownUser;
    app.uid = pwd.*.pw_uid;
    app.gid = pwd.*.pw_gid;
    const home = std.mem.span(pwd.*.pw_dir);
    try setOwnedString(app.allocator, &app.home_dir, home);
}

fn detectGpuFromText(text: []const u8) GpuVendor {
    const lower = std.heap.page_allocator.dupe(u8, text) catch return .unknown;
    defer std.heap.page_allocator.free(lower);
    for (lower) |*ch| ch.* = std.ascii.toLower(ch.*);

    if (std.mem.indexOf(u8, lower, "intel corporation") != null or
        std.mem.indexOf(u8, lower, "uhd graphics") != null or
        std.mem.indexOf(u8, lower, "hd graphics") != null or
        std.mem.indexOf(u8, lower, "iris xe") != null or
        std.mem.indexOf(u8, lower, "iris graphics") != null or
        std.mem.indexOf(u8, lower, "intel") != null)
        return .intel;

    if (std.mem.indexOf(u8, lower, "advanced micro devices") != null or
        std.mem.indexOf(u8, lower, "amd/ati") != null or
        std.mem.indexOf(u8, lower, "amd") != null or
        std.mem.indexOf(u8, lower, "radeon") != null)
        return .amd;

    if (std.mem.indexOf(u8, lower, "nvidia") != null or
        std.mem.indexOf(u8, lower, "geforce") != null or
        std.mem.indexOf(u8, lower, "quadro") != null)
        return .nvidia;

    if (std.mem.indexOf(u8, lower, "virtio") != null or
        std.mem.indexOf(u8, lower, "vmware") != null or
        std.mem.indexOf(u8, lower, "virtualbox") != null or
        std.mem.indexOf(u8, lower, "qxl") != null or
        std.mem.indexOf(u8, lower, "bochs") != null or
        std.mem.indexOf(u8, lower, "hyper-v") != null)
        return .vm;

    return .unknown;
}

fn stepPreflight(app: *AppState) !void {
    const step: Step = .preflight;
    {
        const res = try runCommand(app, step, "checking FreeBSD release", "uname -r");
        defer app.allocator.free(res.out);
        if (!std.mem.startsWith(u8, trimAscii(res.out), "16.")) return error.UnsupportedFreeBSD;
    }
    if (c.geteuid() != 0) return error.NotRoot;
    if (app.username == null or app.keyboard == null) return error.MissingInput;
    try fillUserInfo(app);
    if (!fileExists(app.home_dir.?)) return error.MissingHomeDirectory;
    app.last_completed = .preflight;
}

fn stepDetect(app: *AppState) !void {
    const step: Step = .detect;
    {
        const res = try runCommand(app, step, "probing GPU", "pciconf -lv | grep -A4 -E '^((vgapci|drmn)[0-9]+@)' || true");
        defer app.allocator.free(res.out);
        app.hw.gpu = detectGpuFromText(res.out);
    }
    {
        const res = try runCommand(app, step, "probing audio", "pciconf -lv | egrep -i 'audio|multimedia'");
        defer app.allocator.free(res.out);
        app.hw.audio_present = trimAscii(res.out).len > 0;
    }
    {
        const vm_res = try runCommand(app, step, "checking virtualization", "sysctl -n kern.vm_guest || true");
        defer app.allocator.free(vm_res.out);
        const vm_guess = trimAscii(vm_res.out);
        if (vm_guess.len > 0 and !std.mem.eql(u8, vm_guess, "none")) {
            app.hw.machine = .vm;
        } else {
            const bat_res = try runCommand(app, step, "checking battery/laptop hints", "sysctl -a 2>/dev/null | egrep 'hw.acpi.battery|acpi_lid' || true");
            defer app.allocator.free(bat_res.out);
            app.hw.machine = if (trimAscii(bat_res.out).len > 0) .laptop else .desktop;
        }
    }
    {
        const mem_res = try runCommand(app, step, "checking memory tier", "sysctl -n hw.physmem");
        defer app.allocator.free(mem_res.out);
        app.hw.physmem_bytes = std.fmt.parseInt(u64, trimAscii(mem_res.out), 10) catch 0;
        app.hw.low_memory = app.hw.physmem_bytes > 0 and app.hw.physmem_bytes < 4 * 1024 * 1024 * 1024;
    }
    app.last_completed = .detect;
}

fn buildSysctlBody(app: *AppState) ![]u8 {
    const entries = if (std.mem.eql(u8, app.hw.profile(), "safe")) safe_sysctls[0..] else desktop_sysctls[0..];
    var body = std.array_list.Managed(u8).init(app.allocator);
    errdefer body.deinit();
    try body.writer().print("# managed desktop tuning profile: {s}\n", .{app.hw.profile()});
    for (entries) |entry| {
        const probe_cmd = try std.fmt.allocPrint(app.allocator, "sysctl -n {s}", .{entry.key});
        defer app.allocator.free(probe_cmd);
        const probe = try runCapture(app.allocator, probe_cmd);
        defer app.allocator.free(probe.out);
        if (probe.code == 0) {
            try body.writer().print("{s}={s}\n", .{ entry.key, entry.value });
        } else {
            const msg = try std.fmt.allocPrint(app.allocator, "skipping unsupported sysctl key {s}", .{entry.key});
            defer app.allocator.free(msg);
            try writeLog(app, .sysctl, msg);
        }
    }
    return try body.toOwnedSlice();
}

fn stepSysctl(app: *AppState) !void {
    const step: Step = .sysctl;
    const body = try buildSysctlBody(app);
    defer app.allocator.free(body);
    _ = try replaceManagedBlock(app, step, SYSCTL_CONF, body);

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const t = trimAscii(line);
        if (t.len == 0 or t[0] == '#') continue;
        const cmd = try std.fmt.allocPrint(app.allocator, "sysctl {s}", .{t});
        defer app.allocator.free(cmd);
        const res = try runCommand(app, step, "applying runtime sysctl", cmd);
        defer app.allocator.free(res.out);
        if (res.code != 0) return error.SysctlApplyFailed;
    }

    app.last_completed = .sysctl;
    try saveState(app, .sysctl);
}

fn ensurePkgBootstrap(app: *AppState) !void {
    const check = try runCommand(app, .packages, "checking pkg bootstrap", "pkg info -e pkg");
    defer app.allocator.free(check.out);
    if (check.code == 0) return;
    const boot = try runCommandMonitored(app, .packages, "bootstrapping pkg", "env ASSUME_ALWAYS_YES=yes BATCH=yes pkg bootstrap");
    defer app.allocator.free(boot.out);
    if (boot.code != 0) return error.PkgBootstrapFailed;
}

fn pkgInstalled(app: *AppState, pkg: []const u8) !bool {
    const cmd = try std.fmt.allocPrint(app.allocator, "pkg info -e {s}", .{pkg});
    defer app.allocator.free(cmd);
    const res = try runCapture(app.allocator, cmd);
    defer app.allocator.free(res.out);
    return res.code == 0;
}

fn installPackageList(app: *AppState, step: Step, label: []const u8, list: []const []const u8) !void {
    var needed = std.array_list.Managed([]const u8).init(app.allocator);
    defer needed.deinit();
    for (list) |pkg| {
        if (!(try pkgInstalled(app, pkg))) try needed.append(pkg);
    }
    if (needed.items.len == 0) {
        const msg = try std.fmt.allocPrint(app.allocator, "all packages present for {s}", .{label});
        defer app.allocator.free(msg);
        try writeLog(app, step, msg);
        return;
    }

    for (needed.items, 0..) |pkg, idx| {
        const action = try std.fmt.allocPrint(app.allocator, "{s} ({d}/{d})", .{ label, idx + 1, needed.items.len });
        defer app.allocator.free(action);
        const cmd = try std.fmt.allocPrint(app.allocator, "env ASSUME_ALWAYS_YES=yes BATCH=yes pkg install -y {s}", .{pkg});
        defer app.allocator.free(cmd);

        pkg_attempt: while (true) {
            const run = try runCommandMonitored(app, step, action, cmd);
            if (run.code == 0) {
                defer app.allocator.free(run.out);
                try appendInstalledPackage(app, pkg);
                if (app.checksum_enabled) {
                    try pkgIntegrityCheck(app, pkg);
                } else {
                    try writeLog(app, step, "package checksum verification disabled by user; skipping per-package verification");
                }
                break :pkg_attempt;
            }

            const decision = packageFailurePrompt(pkg, trimAscii(run.out));
            switch (decision) {
                .retry => {
                    app.allocator.free(run.out);
                    continue :pkg_attempt;
                },
                .ignore => {
                    const msg = try std.fmt.allocPrint(app.allocator, "ignoring failed package install for {s}", .{pkg});
                    defer app.allocator.free(msg);
                    try writeLog(app, step, msg);
                    app.allocator.free(run.out);
                    setStatus(app, "ignored");
                    break :pkg_attempt;
                },
                .stop => {
                    const msg = try std.fmt.allocPrint(app.allocator, "user stopped installation at package {s}", .{pkg});
                    defer app.allocator.free(msg);
                    try writeLog(app, step, msg);
                    app.allocator.free(run.out);
                    setStatus(app, "stopped");
                    return error.PackageInstallStoppedByUser;
                },
            }
        }
    }
}

fn stepPackages(app: *AppState) !void {
    const step: Step = .packages;
    try ensurePkgBootstrap(app);
    try installPackageList(app, step, "installing core desktop packages", pkgs_core[0..]);
    if (app.hw.audio_present) try installPackageList(app, step, "installing audio packages", pkgs_audio[0..]);
    try installPackageList(app, step, "installing input packages", pkgs_input[0..]);
    try installPackageList(app, step, "installing utility packages", pkgs_utils[0..]);
    try installPackageList(app, step, "installing productivity packages", pkgs_productivity[0..]);
    try installPackageList(app, step, "installing multimedia packages", pkgs_multimedia[0..]);
    app.last_completed = .packages;
    try saveState(app, .packages);
}

fn videoPkgList(hw: HardwareInfo) []const []const u8 {
    return switch (hw.gpu) {
        .intel => pkgs_video_intel[0..],
        .amd => pkgs_video_amd[0..],
        .nvidia => pkgs_video_nvidia[0..],
        .vm => pkgs_video_vm[0..],
        .unknown => pkgs_video_generic[0..],
    };
}

fn loaderBodyForGpu(gpu: GpuVendor) []const u8 {
    return switch (gpu) {
        .intel =>
        \\# Intel DRM
        \\i915kms_load="YES"
        ,
        .amd =>
        \\# AMD DRM
        \\amdgpu_load="YES"
        ,
        .nvidia =>
        \\# NVIDIA kernel modules
        \\nvidia_load="YES"
        ,
        .vm, .unknown =>
        \\# generic loader settings
        \\
        ,
    };
}

fn stepDrivers(app: *AppState) !void {
    const step: Step = .drivers;
    try installPackageList(app, step, "installing video driver packages", videoPkgList(app.hw));

    const rc_body = try buildDesktopRcBody(app);
    defer app.allocator.free(rc_body);
    _ = try replaceManagedBlock(app, step, RC_CONF, rc_body);

    const loader_body = loaderBodyForGpu(app.hw.gpu);
    _ = try replaceManagedBlock(app, step, LOADER_CONF, loader_body);

    try ensureDir("/usr/local/etc/X11/xorg.conf.d");
    const kbd = app.keyboard.?;
    const xkb_body = try std.fmt.allocPrint(app.allocator,
        \\Section "InputClass"
        \\    Identifier "tkvnbsd keyboard"
        \\    MatchIsKeyboard "on"
        \\    Option "XkbLayout" "{s}"
        \\EndSection
    , .{kbd});
    defer app.allocator.free(xkb_body);
    _ = try writeFileIfDifferent(app, step, XKB_CONF, xkb_body);

    const libinput_body =
        \\Section "InputClass"
        \\    Identifier "tkvnbsd libinput"
        \\    MatchIsPointer "on"
        \\    Driver "libinput"
        \\EndSection
        \\
        \\Section "InputClass"
        \\    Identifier "tkvnbsd libinput touch"
        \\    MatchIsTouchpad "on"
        \\    Driver "libinput"
        \\EndSection
    ;
    _ = try writeFileIfDifferent(app, step, LIBINPUT_CONF, libinput_body);

    try ensureUserInGroup(app, step, "video");
    if (try pkgInstalled(app, "webcamd")) {
        try ensureOptionalGroup(app, step, "webcamd");
        try runBestEffort(app, step, "loading cuse module for webcamd", "kldstat -m cuse >/dev/null 2>&1 || kldload cuse");
    }

    if (driverModuleName(app.hw.gpu)) |modname| {
        const kld_cmd = try std.fmt.allocPrint(app.allocator, "kldstat -m {s} >/dev/null 2>&1 || kldload {s}", .{ modname, modname });
        defer app.allocator.free(kld_cmd);
        try runBestEffort(app, step, "loading graphics module for current boot", kld_cmd);
    }

    try startServiceIfPresent(app, step, "dbus");
    try startServiceIfPresent(app, step, "hald");
    try startServiceIfPresent(app, step, "mixer");
    try startServiceIfPresent(app, step, "powerd");
    if (try pkgInstalled(app, "webcamd")) try startServiceIfPresent(app, step, "webcamd");

    if (!app.hw.audio_present) {
        try appendWarning(app, "no audio device detected; audio packages/config were minimized", .{});
    }
    if (app.hw.gpu == .unknown) {
        try appendWarning(app, "unknown GPU; generic X11 video path selected", .{});
    }

    app.last_completed = .drivers;
    try saveState(app, .drivers);
}

fn stepXdm(app: *AppState) !void {
    const step: Step = .xdm;

    const enable_rc = try runCommand(app, step, "enabling XDM in rc.conf", "sysrc xdm_enable=YES");
    defer app.allocator.free(enable_rc.out);
    if (enable_rc.code != 0) return error.XdmEnableFailed;

    try ensureDir("/usr/local/etc/X11/xdm");
    try ensureAllTtysXdmDisabled(app, step);

    const xservers_body =
        \\# BEGIN TKVNBSD
        \\:0 local /usr/local/bin/X -nolisten tcp
        \\# END TKVNBSD
    ;
    _ = try writeFileIfDifferent(app, step, XDM_XSERVERS, xservers_body);

    const xsetup_body =
        \\#!/bin/sh
        \\# BEGIN TKVNBSD
        \\xsetroot -solid '#202630'
        \\# END TKVNBSD
    ;
    _ = try writeFileIfDifferent(app, step, XDM_XSETUP, xsetup_body);
    try ensureExecutable(app, step, XDM_XSETUP);

    const xsession_body =
        \\#!/bin/sh
        \\# BEGIN TKVNBSD
        \\if [ -r "$HOME/.xsession" ]; then
        \\    exec /bin/sh "$HOME/.xsession"
        \\fi
        \\if [ -r "$HOME/.xinitrc" ]; then
        \\    exec /bin/sh "$HOME/.xinitrc"
        \\fi
        \\exec /usr/local/bin/vtwm
        \\# END TKVNBSD
    ;
    _ = try writeFileIfDifferent(app, step, XDM_XSESSION, xsession_body);
    try ensureExecutable(app, step, XDM_XSESSION);

    try appendWarning(app, "xdm is configured through rc.conf xdm_enable=YES with managed Xservers/Xsession; tty-based xdm startup entries were forced off to avoid conflicting startup methods", .{});

    app.last_completed = .xdm;
    try saveState(app, .xdm);
}
fn stepVtwm(app: *AppState) !void {
    const step: Step = .vtwm;
    const home = app.home_dir.?;
    const xsession_path = try std.fmt.allocPrint(app.allocator, "{s}/.xsession", .{home});
    defer app.allocator.free(xsession_path);
    const xinitrc_path = try std.fmt.allocPrint(app.allocator, "{s}/.xinitrc", .{home});
    defer app.allocator.free(xinitrc_path);
    const vtwmrc_path = try std.fmt.allocPrint(app.allocator, "{s}/.vtwmrc", .{home});
    defer app.allocator.free(vtwmrc_path);
    const xr_path = try std.fmt.allocPrint(app.allocator, "{s}/.Xdefaults", .{home});
    defer app.allocator.free(xr_path);

    const session_body =
        \\#!/bin/sh
        \\# BEGIN TKVNBSD
        \\export LANG="${LANG:-C.UTF-8}"
        \\[ -f "$HOME/.Xdefaults" ] && /usr/local/bin/xrdb -merge "$HOME/.Xdefaults"
        \\if [ -x /usr/local/bin/dbus-launch ]; then
        \\    exec /usr/local/bin/dbus-launch --exit-with-session /usr/local/bin/vtwm
        \\fi
        \\exec /usr/local/bin/vtwm
        \\# END TKVNBSD
    ;
    const changed_xsession = try ensureManagedOrMissingFile(app, step, xsession_path, session_body);
    if (!changed_xsession and fileExists(xsession_path)) {
        const existing = try readFileAlloc(app.allocator, xsession_path, 1024 * 64);
        defer app.allocator.free(existing);
        if (std.mem.indexOf(u8, existing, MarkerBegin) == null and std.mem.indexOf(u8, existing, "vtwm") == null) {
            try appendWarning(app, "existing .xsession kept untouched; verify it launches vtwm", .{});
        }
    }
    _ = try ensureManagedOrMissingFile(app, step, xinitrc_path, session_body);

    const vtwm_body =
        \\# BEGIN TKVNBSD
        \\Menu "defops" {
        \\    "xterm"         f.exec "xterm &"
        \\    "firefox"       f.exec "firefox &"
        \\    "editor"        f.exec "xterm -e vi &"
        \\    "restart"       f.restart
        \\    "exit"          f.quit
        \\}
        \\
        \\Button1 = : root : f.menu "defops"
        \\IconManagerGeometry "=5x5+0+0"
        \\NoGrabServer
        \\# END TKVNBSD
    ;
    _ = try ensureManagedOrMissingFile(app, step, vtwmrc_path, vtwm_body);

    const xr_body =
        \\! BEGIN TKVNBSD
        \\XTerm*faceName: monospace:size=11
        \\XTerm*loginShell: true
        \\! END TKVNBSD
    ;
    _ = try ensureFileIfMissing(app, xr_path, xr_body);

    if (fileExists(xsession_path)) {
        try chownUser(xsession_path, app.uid, app.gid);
        try ensureExecutable(app, step, xsession_path);
    }
    if (fileExists(xinitrc_path)) {
        try chownUser(xinitrc_path, app.uid, app.gid);
        try ensureExecutable(app, step, xinitrc_path);
    }
    if (fileExists(vtwmrc_path)) try chownUser(vtwmrc_path, app.uid, app.gid);
    if (fileExists(xr_path)) try chownUser(xr_path, app.uid, app.gid);

    app.last_completed = .vtwm;
    try saveState(app, .vtwm);
}


fn probeCommandContains(app: *AppState, label: []const u8, command: []const u8, needle: ?[]const u8) !bool {
    const res = try runCommand(app, .probe, label, command);
    defer app.allocator.free(res.out);
    if (res.code != 0) {
        try appendProbeNote(app, "[fail] {s}: command failed", .{label});
        return false;
    }
    if (needle) |n| {
        if (std.mem.indexOf(u8, res.out, n) == null) {
            try appendProbeNote(app, "[fail] {s}: expected content not found", .{label});
            return false;
        }
    }
    try appendProbeNote(app, "[ok] {s}", .{label});
    return true;
}

fn probeFileExists(app: *AppState, label: []const u8, path: []const u8) !bool {
    if (!fileExists(path)) {
        try appendProbeNote(app, "[fail] {s}: missing {s}", .{ label, path });
        return false;
    }
    try appendProbeNote(app, "[ok] {s}: {s}", .{ label, path });
    return true;
}

fn probeFileContains(app: *AppState, label: []const u8, path: []const u8, needle: []const u8) !bool {
    if (!(try fileContains(path, needle, app.allocator))) {
        try appendProbeNote(app, "[fail] {s}: expected content not found in {s}", .{ label, path });
        return false;
    }
    try appendProbeNote(app, "[ok] {s}", .{label});
    return true;
}

fn stepProbe(app: *AppState) !void {
    const step: Step = .probe;
    app.probe_notes.clearRetainingCapacity();
    setAction(app, step, "simulating and validating xdm + vtwm startup path");

    _ = try probeCommandContains(app, "rc.conf enables xdm", "sysrc -n xdm_enable", "YES");
    _ = try probeFileExists(app, "xdm binary present", "/usr/local/bin/xdm");
    _ = try probeFileExists(app, "X server binary present", "/usr/local/bin/X");
    _ = try probeFileExists(app, "vtwm binary present", "/usr/local/bin/vtwm");
    _ = try probeFileExists(app, "XDM Xservers present", XDM_XSERVERS);
    _ = try probeFileExists(app, "XDM Xsession present", XDM_XSESSION);
    _ = try probeFileContains(app, "XDM Xservers local display entry", XDM_XSERVERS, ":0 local /usr/local/bin/X -nolisten tcp");
    _ = try probeFileContains(app, "XDM Xsession launches vtwm", XDM_XSESSION, "/usr/local/bin/vtwm");

    const user_xsession = try std.fmt.allocPrint(app.allocator, "{s}/.xsession", .{app.home_dir.?});
    defer app.allocator.free(user_xsession);
    const user_xinitrc = try std.fmt.allocPrint(app.allocator, "{s}/.xinitrc", .{app.home_dir.?});
    defer app.allocator.free(user_xinitrc);

    _ = try probeFileExists(app, "user .xsession present", user_xsession);
    _ = try probeFileExists(app, "user .xinitrc present", user_xinitrc);
    _ = try probeFileContains(app, "user .xsession launches vtwm", user_xsession, "/usr/local/bin/vtwm");
    _ = try probeFileContains(app, "user .xinitrc launches vtwm", user_xinitrc, "/usr/local/bin/vtwm");

    if (try anyTtysXdmEntryEnabled(app)) {
        try appendProbeNote(app, "[warn] tty-based xdm startup is still enabled in /etc/ttys and may conflict with rc.conf startup", .{});
    } else {
        try appendProbeNote(app, "[ok] tty-based xdm startup is disabled, avoiding conflict with rc.conf startup", .{});
    }

    if (try groupHasUser(app, "video")) {
        try appendProbeNote(app, "[ok] target user is in video group", .{});
    } else {
        try appendProbeNote(app, "[fail] target user is not in video group", .{});
    }

    try appendProbeNote(app, "[info] simulation is a static startup-path validation of binaries, config files, startup model, and session handoff; it does not launch a live X server from inside the installer", .{});

    app.last_completed = .probe;
    try saveState(app, .probe);
}

fn requirePkg(app: *AppState, vr: *ValidationResult, pkg: []const u8) !void {
    if (!(try pkgInstalled(app, pkg))) {
        vr.ok = false;
        try appendWarning(app, "missing required package: {s}", .{pkg});
        vr.warnings += 1;
    }
}

fn stepValidate(app: *AppState) !ValidationResult {
    const step: Step = .validate;
    setAction(app, step, "validating result state");
    var vr = ValidationResult{};
    try requirePkg(app, &vr, "xorg");
    try requirePkg(app, &vr, "xdm");
    try requirePkg(app, &vr, "vtwm");

    {
        const res = try runCommand(app, step, "checking xdm_enable", "sysrc -n xdm_enable");
        defer app.allocator.free(res.out);
        if (!std.mem.eql(u8, trimAscii(res.out), "YES")) {
            vr.ok = false;
            vr.warnings += 1;
            try appendWarning(app, "xdm_enable is not YES in rc.conf", .{});
        }
    }
    if (try anyTtysXdmEntryEnabled(app)) {
        vr.warnings += 1;
        try appendWarning(app, "tty-based xdm entry is still enabled; rc.conf startup may conflict with tty-based startup", .{});
    }

    const xsession_path = try std.fmt.allocPrint(app.allocator, "{s}/.xsession", .{app.home_dir.?});
    defer app.allocator.free(xsession_path);
    const xinitrc_path = try std.fmt.allocPrint(app.allocator, "{s}/.xinitrc", .{app.home_dir.?});
    defer app.allocator.free(xinitrc_path);

    if (!fileExists(xsession_path)) {
        vr.ok = false;
        vr.warnings += 1;
        try appendWarning(app, "user session file is missing: {s}", .{xsession_path});
    }
    if (!fileExists(xinitrc_path)) {
        vr.ok = false;
        vr.warnings += 1;
        try appendWarning(app, "user xinitrc file is missing: {s}", .{xinitrc_path});
    }
    if (!fileExists(XKB_CONF)) {
        vr.ok = false;
        vr.warnings += 1;
        try appendWarning(app, "keyboard config is missing: {s}", .{XKB_CONF});
    }
    if (!fileExists(XDM_XSESSION)) {
        vr.ok = false;
        vr.warnings += 1;
        try appendWarning(app, "xdm Xsession is missing: {s}", .{XDM_XSESSION});
    }
    if (!fileExists(XDM_XSERVERS)) {
        vr.ok = false;
        vr.warnings += 1;
        try appendWarning(app, "xdm Xservers is missing: {s}", .{XDM_XSERVERS});
    } else if (!(try fileContains(XDM_XSERVERS, ":0 local /usr/local/bin/X -nolisten tcp", app.allocator))) {
        vr.ok = false;
        vr.warnings += 1;
        try appendWarning(app, "xdm Xservers does not contain the managed local display entry", .{});
    }
    if (!(try groupHasUser(app, "video"))) {
        vr.ok = false;
        vr.warnings += 1;
        try appendWarning(app, "target user is not in video group", .{});
    }
    if (try pkgInstalled(app, "webcamd") and !(try groupHasUser(app, "webcamd"))) {
        vr.ok = false;
        vr.warnings += 1;
        try appendWarning(app, "webcamd is installed but target user is not in webcamd group", .{});
    }
    if (!fileExists(SYSCTL_CONF)) {
        vr.ok = false;
        vr.warnings += 1;
        try appendWarning(app, "sysctl.conf is missing", .{});
    } else {
        const sysctl_conf = try readFileAlloc(app.allocator, SYSCTL_CONF, 1024 * 1024);
        defer app.allocator.free(sysctl_conf);
        if (std.mem.indexOf(u8, sysctl_conf, MarkerBegin) == null) {
            vr.ok = false;
            vr.warnings += 1;
            try appendWarning(app, "managed sysctl block not found", .{});
        }
    }
    if (driverModuleName(app.hw.gpu) != null and !(try fileContains(LOADER_CONF, MarkerBegin, app.allocator))) {
        vr.ok = false;
        vr.warnings += 1;
        try appendWarning(app, "graphics loader block not found in loader.conf", .{});
    }
    if (!(try fileContains(SYSCTL_CONF, "vfs.usermount=1", app.allocator))) {
        vr.ok = false;
        vr.warnings += 1;
        try appendWarning(app, "desktop sysctl tuning is missing vfs.usermount=1", .{});
    }
    if (!(try fileContains(SYSCTL_CONF, "hw.snd.maxautovchans=", app.allocator))) {
        vr.ok = false;
        vr.warnings += 1;
        try appendWarning(app, "desktop sysctl tuning is missing hw.snd.maxautovchans", .{});
    }
    if (!(try fileContains(RC_CONF, "powerd_enable=\"YES\"", app.allocator))) {
        vr.ok = false;
        vr.warnings += 1;
        try appendWarning(app, "powerd is not enabled persistently in rc.conf", .{});
    }
    if (!(try fileContains(RC_CONF, "powerd_flags=", app.allocator))) {
        vr.ok = false;
        vr.warnings += 1;
        try appendWarning(app, "powerd flags are missing from rc.conf", .{});
    }
    if (driverModuleName(app.hw.gpu)) |modname| {
        const kld_expect = try std.fmt.allocPrint(app.allocator, "kld_list=\"${{kld_list}} {s}\"", .{modname});
        defer app.allocator.free(kld_expect);
        if (!(try fileContains(RC_CONF, kld_expect, app.allocator))) {
            vr.ok = false;
            vr.warnings += 1;
            try appendWarning(app, "graphics module persistence is missing from rc.conf", .{});
        }
    }

    if (app.checksum_enabled) {
        const pkg_check = try runCommandMonitored(app, step, "checking installed package checksums", "pkg check -q -s -a");
        defer app.allocator.free(pkg_check.out);
        if (pkg_check.code != 0) {
            vr.ok = false;
            vr.warnings += 1;
            try appendWarning(app, "pkg checksum validation reported issues", .{});
        }
    } else {
        try writeLog(app, step, "package checksum verification disabled by user; skipping final checksum validation");
    }

    app.last_completed = .validate;
    try saveState(app, .validate);
    return vr;
}

fn retryOrQuit(app: *AppState, failed_step: Step, err_name: []const u8) bool {
    drawFrame("tkvnbsd - step failed");
    uiPrintf(4, 4, "Step failed: {s}", .{stepName(failed_step)});
    uiPrintf(5, 4, "Error: {s}", .{err_name});
    uiPrintf(7, 4, "See log: {s}", .{LOG_PATH});
    uiPrint(9, 4, "Press r to retry or q to quit.");
    while (true) {
        const ch = c.getch();
        switch (ch) {
            'r', 'R' => return true,
            'q', 'Q' => {
                setStatus(app, "stopped");
                return false;
            },
            else => {},
        }
    }
}

fn runStepWithRetry(app: *AppState, step: Step) !void {
    while (true) {
        const step_result = switch (step) {
            .sysctl => stepSysctl(app),
            .packages => stepPackages(app),
            .drivers => stepDrivers(app),
            .xdm => stepXdm(app),
            .vtwm => stepVtwm(app),
            .probe => stepProbe(app),
            else => return,
        };

        step_result catch |err| {
            const name = @errorName(err);
            const msg = try std.fmt.allocPrint(app.allocator, "step {s} error: {s}", .{ stepName(step), name });
            defer app.allocator.free(msg);
            try writeLog(app, step, msg);
            if (err == error.PackageInstallStoppedByUser) return err;
            if (!retryOrQuit(app, step, name)) return err;
            continue;
        };

        return;
    }
}

fn resultScreen(app: *AppState, vr: ValidationResult) void {
    drawFrame("tkvnbsd - result");
    uiPrintf(3, 4, "Validation: {s}", .{if (vr.ok) "success" else "warnings/failures present"});
    uiPrintf(4, 4, "Warnings: {d}", .{app.warnings.items.len});
    uiPrintf(5, 4, "Packages installed successfully this run: {d}", .{app.installed_packages.items.len});
    uiPrintf(6, 4, "Package checksum verification: {s}", .{if (app.checksum_enabled) "enabled" else "disabled"});
    uiPrint(8, 4, "Stages completed: preflight, detect, sysctl, packages, drivers, xdm, vtwm, probe, validate");
    uiPrint(9, 4, "Desktop post-config applied: sysctl profile, powerd, desktop groups, Xorg input/layout, graphics modules, rc.conf XDM enablement, managed Xservers/Xsession, vtwm user session.");
    uiPrint(10, 4, "Validation / simulation checks:");
    var row: i32 = 11;
    if (app.probe_notes.items.len == 0) {
        uiPrint(row, 6, "No probe notes recorded.");
        row += 1;
    } else {
        for (app.probe_notes.items[0..@min(app.probe_notes.items.len, @as(usize, 6))]) |note| {
            uiPrintf(row, 6, "{s}", .{note});
            row += 1;
        }
    }

    uiPrint(row, 4, "Installed packages:");
    row += 1;
    const start_row: i32 = row;
    const end_row: i32 = c.LINES - 6;
    const usable_rows: usize = if (end_row > start_row) @intCast(end_row - start_row + 1) else 1;
    const col_width: i32 = @divTrunc(c.COLS - 8, 3);

    if (app.installed_packages.items.len == 0) {
        uiPrint(start_row, 6, "No new packages were installed in this run.");
    } else {
        for (app.installed_packages.items, 0..) |pkg, idx| {
            const pkg_row: i32 = start_row + @as(i32, @intCast(idx % usable_rows));
            const col_idx: i32 = @as(i32, @intCast(idx / usable_rows));
            if (col_idx >= 3) break;
            const col: i32 = 6 + col_idx * col_width;
            uiPrintf(pkg_row, col, "- {s}", .{pkg});
        }
    }

    uiPrint(c.LINES - 4, 4, "The simulation step validates startup model, binaries, config files, and vtwm handoff without launching a live X server. Press q to exit.");
    _ = c.refresh();
    while (true) {
        const ch = c.getch();
        if (ch == 'q' or ch == 10 or ch == 13) break;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var app = AppState.init(gpa.allocator());
    defer app.deinit();

    _ = c.initscr();
    defer _ = c.endwin();
    _ = c.cbreak();
    _ = c.noecho();
    _ = c.keypad(c.stdscr, true);
    _ = c.curs_set(0);

    if (!waitForContinue("tkvnbsd", &.{
        "Single-file FreeBSD 16 desktop configurator.",
        "Target stack: X11 + XDM + vtwm.",
        "This tool is designed for one local machine and is safe to re-run.",
    })) return;

    const have_state = try loadState(&app);
    var resume_from: Step = .sysctl;
    if (have_state and app.last_completed != .done and app.last_completed != .none) {
        if (boolPrompt("tkvnbsd - resume", "Existing checkpoint found. Resume from the next unfinished step?")) {
            resume_from = nextStepAfter(app.last_completed);
        } else {
            clearState();
            app.last_completed = .none;
            resume_from = .sysctl;
        }
    }

    if (!(try inputScreen(&app))) return;

    stepPreflight(&app) catch |err| fatalScreen(@errorName(err));
    stepDetect(&app) catch |err| fatalScreen(@errorName(err));

    if (!screenDetection(&app)) return;
    if (!screenSummary(&app, resume_from)) return;

    const ordered_steps = [_]Step{ .sysctl, .packages, .drivers, .xdm, .vtwm, .probe };
    var should_run = resume_from == .sysctl;
    for (ordered_steps) |s| {
        if (s == resume_from) should_run = true;
        if (should_run) runStepWithRetry(&app, s) catch return;
    }

    const vr = stepValidate(&app) catch |err| blk: {
        try appendWarning(&app, "validation step failed: {s}", .{@errorName(err)});
        break :blk ValidationResult{ .ok = false, .warnings = app.warnings.items.len };
    };

    clearState();
    resultScreen(&app, vr);
}
