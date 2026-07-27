using Gtk;

namespace Topbar {

  // -------------- Apps ----------------
  private class Apps : Button {

    public Apps () {
      Object (tooltip_text: "Apps Menu");
      set_css_classes ({ "bar-section", "apps" });
      child = new Label ("󰀻");
      clicked.connect (Utils.launch_apps);
    }
  }

  // -------------- Color Picker ----------------
  private class ColorPicker : Button {

    public ColorPicker () {
      set_css_classes ({ "bar-section", "apps" });
      set_tooltip_text ("Color Picker");
      child = new Label ("");
      clicked.connect (Utils.launch_color_picker);
    }
  }

  // -------------- Screen Recorder ----------------
  private class ScreenRec : Button {

    const string icon_recording_on = "record-desktop-indicator-recording";
    const string icon_recording_off = "record-desktop-indicator";

    public ScreenRec () {
      set_css_classes ({ "bar-section" });
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

  // -------------- Tools ----------------
  private class Tools : Box {

    private Revealer revealer;

    public Tools () {
      var btn = new Button () {
        css_classes = { "bar-section", "apps" }, tooltip_text = "Click to show / hide tools"
      };
      btn.child = new Label ("");

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
      Object (spacing: 8);
      append (new SystemResources ());
      append (new Apps ());
      append (new Tools ());
      append (new NiriWorkspaces (monitor));
    }
  }
}
