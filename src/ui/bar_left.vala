using Gtk;

namespace Topbar {

  // -------------- Apps ----------------
  private class Apps : Button {

    public Apps () {
      Object (tooltip_text: "Apps Menu");
      set_css_classes ({ "bar-section", "apps" });
      set_cursor_from_name ("pointer");
      child = new Image.from_icon_name ("topbar-apps-symbolic");
      clicked.connect (Utils.launch_apps);
    }
  }

  // -------------- Color Picker ----------------
  private class ColorPicker : Button {

    public ColorPicker () {
      set_css_classes ({ "tool-button" });
      set_cursor_from_name ("pointer");
      set_tooltip_text ("Color Picker");
      child = new Image.from_icon_name ("topbar-color-picker-symbolic");
      clicked.connect (Utils.launch_color_picker);
    }
  }

  // -------------- Screen Recorder ----------------
  private class ScreenRec : Button {

    const string icon_recording_on = "topbar-record-desktop-indicator-recording-symbolic";
    const string icon_recording_off = "topbar-record-desktop-indicator-symbolic";

    public ScreenRec () {
      set_css_classes ({ "tool-button" });
      set_cursor_from_name ("pointer");
      set_tooltip_text ("Screen Recorder");
      // Get recording service
      var rec_service = ScreenRecordService.get_default ();

      // Seed from current state; recording_toggled only fires on change.
      var recording_icon = new Image.from_icon_name (
        rec_service.is_recording ? icon_recording_on : icon_recording_off);
      child = recording_icon;

      // Toggle on click
      clicked.connect (rec_service.toggle_recording);

      rec_service.recording_toggled.connect ((is_recording) => {
        recording_icon.set_from_icon_name (is_recording ? icon_recording_on : icon_recording_off);
      });
    }
  }

  // -------------- Screenshot ----------------
  private class Screenshot : Box {

    private PopoverMenu capture_menu;
    private string? pending_selection;
    private Gtk.Window? keyboard_window;
    private GtkLayerShell.KeyboardMode previous_keyboard_mode;

    public Screenshot () {
      var button = new MenuButton ();
      button.set_css_classes ({ "tool-button" });
      button.set_cursor_from_name ("pointer");
      button.set_tooltip_text ("Screenshot");
      button.set_child (new Image.from_icon_name ("topbar-screenshot-symbolic"));
      append (button);

      var menu = new GLib.Menu ();
      menu.append ("Screen", "screenshot.capture::screen");
      menu.append ("Region", "screenshot.capture::region");

      var actions = new SimpleActionGroup ();
      var capture = new SimpleAction ("capture", VariantType.STRING);
      capture.activate.connect ((parameter) => {
        pending_selection = parameter.get_string ();
        capture_menu.popdown ();
        if (!capture_menu.get_mapped ())
          launch_capture ();
      });
      actions.add_action (capture);
      insert_action_group ("screenshot", actions);

      capture_menu = new PopoverMenu.from_model (menu);
      capture_menu.add_css_class ("toolmenu");
      capture_menu.set_cursor_from_name ("default");
      capture_menu.set_has_arrow (false);
      capture_menu.set_position (PositionType.BOTTOM);
      capture_menu.set_offset (0, 12);
      button.set_popover (capture_menu);

      capture_menu.map.connect (() => {
        var window = get_root () as Gtk.Window;
        if (window == null || !GtkLayerShell.is_layer_window (window))
          return;
        keyboard_window = window;
        previous_keyboard_mode = GtkLayerShell.get_keyboard_mode (window);
        GtkLayerShell.set_keyboard_mode (window, GtkLayerShell.KeyboardMode.ON_DEMAND);
      });
      capture_menu.unmap.connect (() => {
        restore_keyboard ();
        launch_capture ();
      });
    }

    public override void unroot () {
      pending_selection = null;
      restore_keyboard ();
      base.unroot ();
    }

    private void restore_keyboard () {
      if (keyboard_window == null)
        return;
      GtkLayerShell.set_keyboard_mode (keyboard_window, previous_keyboard_mode);
      keyboard_window = null;
    }

    private void launch_capture () {
      if (pending_selection == null)
        return;
      var selection = pending_selection;
      pending_selection = null;
      // Let the popup unmap before grim captures or slurp takes input.
      Idle.add_once (() => {
        Utils.run_script_async ({ "fish", "-c", "xscreenshot $argv[1]", selection });
      });
    }
  }

  // -------------- Tools ----------------
  private class Tools : Box {

    private Revealer revealer;

    public Tools () {
      set_css_classes ({ "bar-section", "tools" });
      var btn = new Button () {
        css_classes = { "tool-button" }, tooltip_text = "Click to show / hide tools"
      };
      btn.set_cursor_from_name ("pointer");
      btn.child = new Image.from_icon_name ("topbar-tools-symbolic");

      btn.clicked.connect (() => {
        if (revealer == null)set_revealer ();
        revealer.reveal_child = !revealer.reveal_child;
        this.spacing = revealer.reveal_child ? 8 : 0;
      });

      append (btn);
    }

    private void set_revealer () {
      var revealer_child = new Box (Orientation.HORIZONTAL, 8);
      revealer_child.append (new ScreenRec ());
      revealer_child.append (new Screenshot ());
      revealer_child.append (new ColorPicker ());

      revealer = new Revealer ();
      revealer.child = revealer_child;
      revealer.set_transition_duration (500);
      revealer.set_transition_type (RevealerTransitionType.SWING_RIGHT);

      append (revealer);

      revealer.notify["child-revealed"].connect (() => {
        if (!revealer.child_revealed) {
          remove (revealer);
          revealer = null;
        }
      });
    }
  }

  // -------------- BarLeft ----------------
  public class BarLeft : Gtk.Box {

    public BarLeft (Gdk.Monitor monitor) {
      Object (spacing: 16);
      append (new SystemResources ());
      append (new Apps ());
      append (new Tools ());
      append (new NiriWorkspaces (monitor));
    }
  }
}
