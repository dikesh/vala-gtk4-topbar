using Gee;
using Gtk;

namespace Topbar {

  // -------------------- Niri Window ----------------------------
  private class WindowBox : Box {
    public int id;
    public int workspace_id;

    public WindowBox (NiriWindow ? window = null) {
      if (window == null)return;

      id = window.id;
      workspace_id = window.workspace_id;

      var icon_name = window.app_id.ascii_down ();
      if (icon_name == "kitty") {
        append (new Image.from_resource ("/com/github/dikesh/topbar/kitty-custom.svg"));
      } else {
        if (icon_name == "org.gnome.nautilus")icon_name = "nautilus";
        else if (!Utils.icon_exists (icon_name))icon_name = "application-x-executable";

        append (new Image.from_icon_name (icon_name));
      }
    }

    public static WindowBox empty_window_box () {
      var ws_box = new WindowBox ();
      ws_box.append (new Image.from_icon_name ("archlinux-logo"));
      return ws_box;
    }
  }

  // -------------------- Niri Workspace ----------------------------
  private class WorkspaceBox : Box {
    public int id;
    public bool is_active { get; set; }
    public bool is_focused { get; set; }
    private HashSet<int> ws_window_ids;

    public WorkspaceBox (NiriWorkspace workspace, NiriIPC niri) {
      Object (spacing: 8, visible: false);
      set_tooltip_text ("Left click to focus workspace\nScroll to switch between windows");
      set_css_classes ({ "hl-workspace" });

      id = workspace.id;
      is_active = workspace.is_active;
      is_focused = workspace.is_focused;
      ws_window_ids = new HashSet<int> ();

      add_empty_window_box ();
      foreach (var niri_window in niri.niri_windows.values)add_window_box (niri_window);

      // Watch for change in focus and active status
      if (is_focused)update_css_classes ();
      update_visibility ();

      notify["is-focused"].connect ((s, p) => update_css_classes ());
      notify["is-active"].connect ((s, p) => update_visibility ());

      // Add click gesture
      var gesture = new GestureClick ();
      gesture.pressed.connect (() => { if (!is_focused)NiriIPC.focus_workspace (id); });
      add_controller (gesture);

      // Add scroller
      var scroll_controller = new EventControllerScroll (EventControllerScrollFlags.VERTICAL);
      scroll_controller.scroll.connect ((controller, delta_x, delta_y) => {
        if (!is_focused)NiriIPC.focus_workspace (id);

        if (delta_y < 0)NiriIPC.cycle_windows (id, true);
        else if (delta_y > 0)NiriIPC.cycle_windows (id, false);
        return true;
      });
      add_controller (scroll_controller);
    }

    private void update_css_classes () {
      const string class_to_update = "hl-workspace-active";
      if (is_focused && (!has_css_class (class_to_update)))add_css_class (class_to_update);
      else if (!is_focused && has_css_class (class_to_update))remove_css_class (class_to_update);
    }

    private void update_visibility () {
      visible = is_active || ws_window_ids.size > 0;
    }

    public void add_empty_window_box () {
      append (WindowBox.empty_window_box ());
    }

    public void add_window_box (NiriWindow niri_window) {
      // Validation
      if (niri_window.workspace_id != id)return;

      // Remove empty window
      if (ws_window_ids.size == 0)remove (get_first_child ());

      // Append new window
      append (new WindowBox (niri_window));
      ws_window_ids.add (niri_window.id);
      update_visibility ();
    }

    public void remove_window_box (WindowBox win_box) {
      ws_window_ids.remove (win_box.id);
      remove (win_box);
      win_box = null;
      if (ws_window_ids.size == 0)add_empty_window_box ();
      update_visibility ();
    }

    public bool remove_window_box_by_id (int window_id) {
      // Nothing to remove or window does not exist in this workspace
      if (!ws_window_ids.contains (window_id))return false;

      var win_box = (WindowBox) get_first_child ();
      while (win_box != null) {
        if (win_box.id == window_id) {
          remove_window_box (win_box);
          return true;
        }
        win_box = (WindowBox) win_box.get_next_sibling ();
      }

      return false;
    }

    public void remove_other_workspace_windows (NiriIPC niri) {
      if (ws_window_ids.size == 0)return; // Nothing to remove

      var win_box = (WindowBox) get_first_child ();
      while (win_box != null) {
        var niri_win = niri.niri_windows.get (win_box.id);
        if (win_box.workspace_id != niri_win.workspace_id)remove_window_box (win_box);
        win_box = (WindowBox) win_box.get_next_sibling ();
      }
    }

    public void append_window_if_missing (NiriWindow niri_window) {
      if (niri_window.workspace_id == id && !ws_window_ids.contains (niri_window.id))
        add_window_box (niri_window);
    }
  }

  // -------------------- Main ----------------------------
  public class NiriWorkspaces : Box {

    private Gdk.Monitor monitor;
    private NiriIPC niri;

    public NiriWorkspaces (Gdk.Monitor monitor) {
      Object (orientation: Orientation.HORIZONTAL, spacing: 4);
      set_css_classes ({ "bar-section" });

      // Keep the monitor reference and read its connector live rather than
      // snapshotting it. On hotplug the Gdk.Monitor can be handed over before
      // its connector name is populated; a snapshot taken then would stay
      // empty forever and never match any Niri workspace output.
      this.monitor = monitor;

      try {
        niri = NiriIPC.get_default ();
        niri.workspaces_changed.connect (on_workspaces_changed);
        niri.workspace_focus_changed.connect (on_workspace_focus_changed);
        niri.windows_changed.connect (on_windows_changed);
        niri.window_closed.connect (on_window_closed);

        // Re-seed once the connector becomes available (see note above).
        monitor.notify["connector"].connect (on_workspaces_changed);

        destroy.connect (() => {
          niri.workspaces_changed.disconnect (on_workspaces_changed);
          niri.workspace_focus_changed.disconnect (on_workspace_focus_changed);
          niri.windows_changed.disconnect (on_windows_changed);
          niri.window_closed.disconnect (on_window_closed);
          monitor.notify["connector"].disconnect (on_workspaces_changed);
        });

        // Add Long Press gesture
        var gesture = new GestureLongPress ();
        gesture.pressed.connect (() => niri.toggle_overview ());
        add_controller (gesture);

        // Seed from cached IPC state. On display reconnect this widget is
        // created after Niri has already sent its initial event dump, so no
        // signal will fire to populate it — build from the cache directly.
        on_workspaces_changed ();
      } catch (Error e) {
        critical ("Failed to init Niri IPC: %s", e.message);
      }
    }

    private void on_workspaces_changed () {
      // Get workspaces
      var ws_li = new ArrayList<NiriWorkspace> ();

      // Read the connector live; may be null briefly right after hotplug.
      var output = monitor.get_connector ();
      if (output == null)return;

      // Filter by output
      foreach (var niri_ws in niri.niri_workspaces.values)
        if (niri_ws.output == output)ws_li.add (niri_ws);

      // Sort by Index first
      ws_li.sort ((a, b) => a.idx - b.idx);

      // Update workspaces
      var ws_box = (WorkspaceBox) get_first_child ();
      var idx = 0;

      while (true) {
        var niri_ws = idx >= 0 && idx < ws_li.size ? ws_li[idx++] : null;

        // End of loop
        if (ws_box == null && niri_ws == null)break;

        // Next sibling
        var next_ws_box = ws_box == null ? null : (WorkspaceBox) ws_box.get_next_sibling ();

        // Remove extra workspace boxes
        if (niri_ws == null && ws_box != null) {
          remove (ws_box);
          ws_box = null;
        }
        // Append new workspace boxes
        else if (niri_ws != null && ws_box == null)
          append (new WorkspaceBox (niri_ws, niri));
        // Update workspace boxes
        else if (niri_ws.id != ws_box.id) {
          var prev = (WorkspaceBox) ws_box.get_prev_sibling ();
          remove (ws_box);
          ws_box = null;
          insert_child_after (new WorkspaceBox (niri_ws, niri), prev);
        }

        // When a window is moved to last empty workspace,
        // Niri does not fire WorkspaceActivated event.
        // Instead it fires WorkspacesChanged event as it adds new workspace after the last one.
        if (ws_box != null && niri_ws != null)ws_box.is_focused = niri_ws.is_focused;

        // Update next box as current
        ws_box = next_ws_box;
      }
    }

    private void on_workspace_focus_changed (int workspace_id) {
      // Iterate on each workspace
      var output_has_focus = false;
      var ws_box = (WorkspaceBox) get_first_child ();
      while (ws_box != null) {
        ws_box.is_focused = ws_box.id == workspace_id;
        if (ws_box.is_focused)output_has_focus = true;
        ws_box = (WorkspaceBox) ws_box.get_next_sibling ();
      }

      // Update Active status
      if (output_has_focus) {
        ws_box = (WorkspaceBox) get_first_child ();
        while (ws_box != null) {
          ws_box.is_active = ws_box.is_focused;
          ws_box = (WorkspaceBox) ws_box.get_next_sibling ();
        }
      }
    }

    private void on_windows_changed () {
      // Iterate on each workspace
      var ws_box = (WorkspaceBox) get_first_child ();
      while (ws_box != null) {

        // Remove window first if required
        ws_box.remove_other_workspace_windows (niri);

        // Append window if required
        foreach (var niri_win in niri.niri_windows.values)
          ws_box.append_window_if_missing (niri_win);

        // Next Workspace Box
        ws_box = (WorkspaceBox) ws_box.get_next_sibling ();
      }
    }

    private void on_window_closed (int window_id) {
      // Iterate on each workspace
      var ws_box = (WorkspaceBox) get_first_child ();
      while (ws_box != null) {
        if (ws_box.remove_window_box_by_id (window_id))return;
        ws_box = (WorkspaceBox) ws_box.get_next_sibling ();
      }
    }
  }
}
