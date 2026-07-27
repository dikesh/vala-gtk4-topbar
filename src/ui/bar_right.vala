using Gtk;
using Gdk;

namespace Topbar {

  private class BtDeviceBox : Box {
    public BtDeviceBox (string device_name = "", string icon_name = "") {
      Object (spacing: device_name == "" ? 0 : 8);
      append (new Image.from_icon_name (icon_name));
      append (new Label (device_name));
    }
  }

  private class Bluetooth : Box {

    public class Bluetooth () {
      set_tooltip_text ("Left click to open launcher\nRight click to toggle power");
      set_css_classes ({ "bar-section", "bluetooth" });

      var bt = BluetoothService.get_default ();
      bt.updated.connect (() => render (bt));
      render (bt);

      var click = new GestureClick ();
      click.set_button (0);
      click.pressed.connect ((gesture, n_press, x, y) => {
        var btn_clicked = gesture.get_current_button ();
        if (btn_clicked == BUTTON_PRIMARY)Utils.launch_bluetooth_menu ();
        else if (btn_clicked == BUTTON_SECONDARY)bt.toggle_power ();
      });
      add_controller (click);
    }

    private void render (BluetoothService bt) {
      remove_all_children ();
      if (!bt.powered)append (new BtDeviceBox ("", "bluetooth-disabled-symbolic"));
      else if (bt.devices.size == 0)append (new BtDeviceBox ("", "bluetooth-active-symbolic"));
      else {
        foreach (var device in bt.devices.values) {
          append (new BtDeviceBox (device.name, device.icon));
        }
      }
      spacing = bt.devices.size == 0 ? 0 : 8;
    }

    private void remove_all_children () {
      var child = get_first_child ();
      while (child != null) {
        remove (child);
        child = get_first_child ();
      }
    }
  }

  private class Volume : Box {

    public class Volume () {
      Object (spacing: 8, tooltip_text: "Scroll to change volume\nLeft Click to toggle mute");
      set_css_classes ({ "bar-section", "volume" });

      var volume = VolumeService.get_default ();

      var icon = new Image.from_icon_name (volume.icon_name);
      var label = new Label (@"$(volume.level)%");
      append (icon);
      append (label);

      volume.updated.connect ((level, icon_name) => {
        icon.icon_name = icon_name;
        label.label = @"$(level)%";
      });

      var click_gesture = new GestureClick ();
      click_gesture.pressed.connect (() => volume.toggle_volume_mute.begin ());

      var scroll_gesture = new EventControllerScroll (EventControllerScrollFlags.VERTICAL);
      scroll_gesture.scroll.connect ((dx, dy) => {
        if (dy < 0)volume.update_volume_level.begin (true);
        else if (dy > 0)volume.update_volume_level.begin (false);
        return true;
      });

      add_controller (click_gesture);
      add_controller (scroll_gesture);
    }
  }

  private class Wifi : Box {
    Image icon;
    Label label;

    public Wifi () {
      Object (spacing: 8, tooltip_text: "Click to open NetworkManager TUI");
      set_css_classes ({ "bar-section", "network" });

      var wifi = WifiService.get_default ();

      icon = new Image.from_icon_name (wifi.icon_name);
      label = new Label (wifi.ssid);

      append (icon);
      append (label);

      wifi.updated.connect (() => {
        icon.icon_name = wifi.icon_name;
        label.label = wifi.ssid;
      });

      var click_gesture = new GestureClick ();
      click_gesture.pressed.connect (Utils.launch_wifi_menu);
      add_controller (click_gesture);
    }
  }

  private class Battery : Box {

    Image icon;
    Label label;

    public Battery () {
      Object (spacing: 4);
      set_css_classes ({ "bar-section", "battery" });

      icon = new Gtk.Image ();
      label = new Gtk.Label ("");

      append (icon);
      append (label);

      try {
        var battery = BatteryService.get_default ();
        battery.updated.connect (() => update (battery));
        update (battery);
      } catch (Error e) {
        warning ("Error: %s".printf (e.message));
      }
    }

    private void update (BatteryService battery) {
      icon.set_from_icon_name (battery.battery_icon_name);
      label.set_text ("%d%%".printf (battery.percentage));
    }
  }

  private class PowerMenu : Button {

    public PowerMenu () {
      set_css_classes ({ "bar-section", "power" });
      set_tooltip_text ("Click to open Power Menu");
      child = new Image.from_icon_name ("system-shutdown-symbolic");
      clicked.connect (Utils.launch_power_menu);
    }
  }

  public class BarRight : Gtk.Box {

    public BarRight () {
      Object (spacing: 8);
      append (new Bluetooth ());
      append (new Volume ());
      append (new Wifi ());
      append (new Battery ());
      append (new SystemTray ());
      append (new PowerMenu ());
    }
  }
}
