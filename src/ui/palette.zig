//! The command palette: the person's Rex actions, with the keys their config binds to them, and
//! Renux's own. Typing filters; Enter or a click runs the action on the focused pane.
const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");
const gtk = @import("gtk");
const adw = @import("adw");
const Server = @import("../rex/server.zig").Server;
const filterdialog = @import("filterdialog.zig");
const settings = @import("../settings/settings.zig");

const gpa = std.heap.c_allocator;

/// Renux's own actions, run through the app's action names.
const local = [_]struct { title: [:0]const u8, action: [:0]const u8, words: []const u8 }{
    .{ .title = "Split right", .action = "app.split-right", .words = "pane new horizontal" },
    .{ .title = "Split down", .action = "app.split-down", .words = "pane new vertical" },
    .{ .title = "Float or minimize pane", .action = "app.pane-float-focused", .words = "floating layer" },
    .{ .title = "Zoom pane", .action = "app.zoom-pane", .words = "maximize fullscreen" },
    .{ .title = "Close pane", .action = "app.close-pane", .words = "kill" },
    .{ .title = "Find in pane", .action = "app.find", .words = "search" },
    .{ .title = "Previous prompt", .action = "app.prompt-prev", .words = "jump shell command up" },
    .{ .title = "Next prompt", .action = "app.prompt-next", .words = "jump shell command down" },
    .{ .title = "New window", .action = "app.new-window", .words = "tab" },
    .{ .title = "New session", .action = "app.new-session", .words = "" },
    .{ .title = "Forward Port…", .action = "app.forward-port", .words = "client.host.forward_port localhost remote tunnel browser tcp" },
    .{ .title = "Toggle sidebar", .action = "app.toggle-sidebar", .words = "hide show" },
    .{ .title = "Overview", .action = "app.overview", .words = "all tabs windows zoom out grid expose mission" },
    .{ .title = "Full screen mode", .action = "app.full-screen", .words = "panes only hide sidebar background bare zen focus" },
    .{ .title = "Tight layout", .action = "app.tight", .words = "compact tmux relaxed" },
    .{ .title = "Settings", .action = "app.settings", .words = "preferences font" },
};

const small_actions = [_]struct { title: []const u8, name: []const u8, category: []const u8 }{
    .{ .title = "Quick Look", .name = "client.quick_look", .category = "Pane" },
    .{ .title = "Mute or unmute tab", .name = "client.tab.mute", .category = "Tab" },
    .{ .title = "Switch host", .name = "client.host.switch", .category = "Host" },
    .{ .title = "Remove host…", .name = "client.host.remove", .category = "Host" },
    .{ .title = "Refresh sessions", .name = "session.refresh", .category = "Session" },
    .{ .title = "Close Session…", .name = "session.close", .category = "Session" },
    .{ .title = "Copy pane ID", .name = "pane.copy_id", .category = "Pane" },
    .{ .title = "Select all in pane", .name = "pane.select_all", .category = "Pane" },
    .{ .title = "Copy from pane", .name = "pane.copy", .category = "Pane" },
    .{ .title = "Paste into pane", .name = "pane.paste", .category = "Pane" },
    .{ .title = "Close other panes", .name = "pane.close_others", .category = "Pane" },
    .{ .title = "Rename pane", .name = "pane.rename", .category = "Pane" },
    .{ .title = "New floating pane", .name = "pane.new_floating", .category = "Pane" },
    .{ .title = "Minimize floating pane", .name = "pane.minimize_floating", .category = "Pane" },
    .{ .title = "Minimize all floating panes", .name = "pane.minimize_all_floating", .category = "Pane" },
    .{ .title = "Move pane to tab…", .name = "pane.move_to_tab", .category = "Pane" },
    .{ .title = "Move pane to new tab", .name = "pane.move_to_new_tab", .category = "Pane" },
    .{ .title = "Insert path…", .name = "pane.insert_path", .category = "Pane" },
    .{ .title = "Go to directory…", .name = "pane.go_to_directory", .category = "Pane" },
};

fn switchedOff(action: []const u8) bool {
    const st = &settings.current;
    const eql = std.mem.eql;
    if (!st.overview and (eql(u8, action, "app.overview") or eql(u8, action, "client.overview.toggle"))) return true;
    return !st.agent_board and eql(u8, action, "client.board.toggle");
}

const Item = struct {
    row: *gtk.ListBoxRow,
    haystack: []u8,
    /// A Rex action's name. The server's list can be read again while the palette is open, so
    /// the action is looked up by name when it runs.
    rex_name: ?[]u8,
    local_index: ?usize,
};

/// The palettes that are open, so one whose server goes away can close.
var open_palettes: std.ArrayList(*Palette) = .empty;

/// A server is about to be destroyed: close any palette that would run its actions.
pub fn serverGone(server: *Server) void {
    for (open_palettes.items) |p| if (p.server == server) {
        p.server = null;
        _ = p.dialog.close();
    };
}

pub const Palette = struct {
    dialog: *adw.Dialog,
    entry: *gtk.SearchEntry,
    list: *gtk.ListBox,
    items: std.ArrayList(Item) = .empty,
    /// Null once the server has gone away, while the dialog is still closing.
    server: ?*Server,
    app: *gtk.Application,
    session_id: []u8,
    block_id: ?[]u8,

    pub fn open(server: *Server, app: *gtk.Application, parent: *gtk.Widget, session_id: []const u8, block_id: ?[]const u8) void {
        const p = gpa.create(Palette) catch return;
        const owned_session = gpa.dupe(u8, session_id) catch {
            gpa.destroy(p);
            return;
        };
        const parts = filterdialog.build("Commands", "Run a command", 560, 480, "palette");
        p.* = .{
            .dialog = parts.dialog,
            .entry = parts.entry,
            .list = parts.list,
            .server = server,
            .app = app,
            .session_id = owned_session,
            .block_id = if (block_id) |b| gpa.dupe(u8, b) catch null else null,
        };
        open_palettes.append(gpa, p) catch {};
        _ = gtk.ListBox.signals.row_activated.connect(p.list, *Palette, &activated, p, .{});
        filterdialog.onQuery(p.entry, *Palette, &changed, p);
        _ = gtk.SearchEntry.signals.activate.connect(p.entry, *Palette, &enter, p, .{});
        _ = gtk.SearchEntry.signals.stop_search.connect(p.entry, *Palette, &stop, p, .{});
        _ = adw.Dialog.signals.closed.connect(p.dialog, *Palette, &closed, p, .{});

        // An action without a title is a call a program makes, such as reading a terminal's
        // screen, not a command for a person to run; those stay out of the list.
        for (server.actions) |a| if (!std.mem.eql(u8, a.title, a.name) and !switchedOff(a.name)) p.add(a.title, a.category, a.keys, a.keywords, a.name, true, null);
        for (small_actions) |item| {
            const listed = for (server.actions) |a| {
                if (std.mem.eql(u8, a.name, item.name) and !std.mem.eql(u8, a.title, a.name)) break true;
            } else false;
            if (!listed) p.add(item.title, item.category, "", "", item.name, true, null);
        }
        for (local, 0..) |l, i| if (!switchedOff(l.action)) p.add(l.title, "Renux", "", l.words, l.action, false, i);

        p.filter("");
        p.dialog.present(parent);
        _ = p.entry.as(gtk.Widget).grabFocus();
    }

    fn add(p: *Palette, title: []const u8, category: []const u8, keys: []const u8, words: []const u8, name: []const u8, rex: bool, loc: ?usize) void {
        const line = gtk.Box.new(.horizontal, 10);
        const z = gpa.dupeSentinel(u8, title, 0) catch return;
        defer gpa.free(z);
        const label = gtk.Label.new(z.ptr);
        label.setXalign(0);
        label.setEllipsize(.end);
        label.as(gtk.Widget).setHexpand(1);
        line.append(label.as(gtk.Widget));
        if (category.len > 0) {
            const c = gpa.dupeSentinel(u8, category, 0) catch return;
            defer gpa.free(c);
            const cl = gtk.Label.new(c.ptr);
            cl.as(gtk.Widget).addCssClass("palette-category");
            line.append(cl.as(gtk.Widget));
        }
        if (keys.len > 0) {
            const k = gpa.dupeSentinel(u8, keys, 0) catch return;
            defer gpa.free(k);
            const kl = gtk.Label.new(k.ptr);
            kl.as(gtk.Widget).addCssClass("palette-keys");
            line.append(kl.as(gtk.Widget));
        }
        const row = gtk.ListBoxRow.new();
        row.setChild(line.as(gtk.Widget));
        p.list.append(row.as(gtk.Widget));
        const hay = std.fmt.allocPrint(gpa, "{s} {s} {s} {s}", .{ title, name, category, words }) catch return;
        for (hay) |*ch| ch.* = std.ascii.toLower(ch.*);
        const rex_name: ?[]u8 = if (rex) gpa.dupe(u8, name) catch null else null;
        p.items.append(gpa, .{ .row = row, .haystack = hay, .rex_name = rex_name, .local_index = loc }) catch {
            gpa.free(hay);
            if (rex_name) |n| gpa.free(n);
        };
    }

    /// Shows the items holding every word typed, in order of the list.
    fn filter(p: *Palette, query: []const u8) void {
        var first: ?*gtk.ListBoxRow = null;
        for (p.items.items) |it| {
            const match = filterdialog.matchesWords(it.haystack, query);
            it.row.as(gtk.Widget).setVisible(@intFromBool(match));
            if (match and first == null) first = it.row;
        }
        p.list.selectRow(first);
    }

    fn changed(entry: *gtk.SearchEntry, p: *Palette) callconv(.c) void {
        p.filter(filterdialog.query(entry));
    }

    fn enter(_: *gtk.SearchEntry, p: *Palette) callconv(.c) void {
        if (p.list.getSelectedRow()) |row| p.run(row);
    }

    fn stop(_: *gtk.SearchEntry, p: *Palette) callconv(.c) void {
        _ = p.dialog.close();
    }

    fn activated(_: *gtk.ListBox, row: *gtk.ListBoxRow, p: *Palette) callconv(.c) void {
        p.run(row);
    }

    fn run(p: *Palette, row: *gtk.ListBoxRow) void {
        for (p.items.items) |it| if (it.row == row) {
            if (it.rex_name) |name| {
                if (p.server) |server| runRex(p, server, name);
            } else if (it.local_index) |i| {
                const name = local[i].action["app.".len..];
                p.app.as(gio.ActionGroup).activateAction(name.ptr, null);
            }
            _ = p.dialog.close();
            return;
        };
    }

    fn runRex(p: *Palette, server: *Server, name: []const u8) void {
        const a = for (server.actions) |a| {
            if (std.mem.eql(u8, a.name, name)) break a;
        } else {
            for (small_actions) |item| if (std.mem.eql(u8, item.name, name)) {
                if (!server.performLocal(p.session_id, name, null)) server.notifyMessage("Renux can't do that action yet");
                return;
            };
            return server.notifyMessage("That command is no longer in your Rex config");
        };
        if (a.needs_args and a.args == null) {
            server.notifyMessage("That command needs arguments; bind it to a key in your Rex config");
        } else if (std.mem.startsWith(u8, a.name, "pane.") or std.mem.startsWith(u8, a.name, "client.") or std.mem.startsWith(u8, a.name, "session.")) {
            if (!server.performLocal(p.session_id, a.name, a.args)) server.notifyMessage("Renux can't do that action yet");
        } else {
            server.runAction(p.session_id, p.block_id, a.name, a.args);
        }
    }

    fn closed(_: *adw.Dialog, p: *Palette) callconv(.c) void {
        for (open_palettes.items, 0..) |x, i| if (x == p) {
            _ = open_palettes.swapRemove(i);
            break;
        };
        for (p.items.items) |it| {
            gpa.free(it.haystack);
            if (it.rex_name) |n| gpa.free(n);
        }
        p.items.deinit(gpa);
        gpa.free(p.session_id);
        if (p.block_id) |b| gpa.free(b);
        gpa.destroy(p);
    }
};

test {
    _ = @import("filterdialog.zig");
}
