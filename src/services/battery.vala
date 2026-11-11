namespace Topbar {

  public class BatteryService : Object {

    private static BatteryService ? instance = null;

    public int percentage { get; private set; }
    public string battery_icon_name { get; private set; }

    public signal void updated ();

    private DBusProxy proxy;

    public static BatteryService get_default () throws Error {
      if (instance == null)instance = new BatteryService ();
      return instance;
    }

    private BatteryService () throws Error {
      proxy = find_battery_proxy ();
      refresh ();
      proxy.g_properties_changed.connect ((changed, invalidated) => refresh ());
    }

    private DBusProxy find_battery_proxy () throws Error {
      var upower = new DBusProxy.for_bus_sync (
        BusType.SYSTEM,
        DBusProxyFlags.NONE,
        null,
        "org.freedesktop.UPower",
        "/org/freedesktop/UPower",
        "org.freedesktop.UPower"
      );

      var devices = upower.call_sync ("EnumerateDevices", null, DBusCallFlags.NONE, -1);

      foreach (Variant v in devices.get_child_value (0)) {
        string path = v.get_string ();
        var p = new DBusProxy.for_bus_sync (
          BusType.SYSTEM,
          DBusProxyFlags.NONE,
          null,
          "org.freedesktop.UPower",
          path,
          "org.freedesktop.UPower.Device"
        );

        if (p.get_cached_property ("Type").get_uint32 () == 2) // Battery
          return p;
      }

      throw new IOError.NOT_FOUND ("No battery found");
    }

    private void refresh () {
      var state = proxy.get_cached_property ("State").get_uint32 ();
      var type = proxy.get_cached_property ("Type").get_uint32 ();

      double perc = proxy.get_cached_property ("Percentage").get_double () / 100.0;

      bool is_battery = (type != 0) && (type != 1); // not UNKNOWN, not LINE_POWER

      var curr_battery_icon_name = get_icon_name (state, is_battery, perc);
      var curr_percentage = (int) (perc * 100);

      if (curr_battery_icon_name != battery_icon_name || curr_percentage != percentage) {
        battery_icon_name = curr_battery_icon_name;
        percentage = curr_percentage;
        updated ();
      }
    }

    private static string get_icon_name (uint state, bool is_battery, double perc) {
      if (!is_battery)return "battery-missing-symbolic";

      // UPower: fully charged (4) or waiting to charge (5), e.g. at a charge limit.
      if (state == 4 || state == 5)return "battery-plugged-symbolic";

      string charge = state == 1 ? "-charging" : ""; // CHARGING
      int level = (int) Math.round (perc * 10) * 10;
      return @"battery-level-$level$charge-symbolic";
    }
  }
}
