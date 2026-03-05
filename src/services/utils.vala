using Gtk;
using Gdk;

namespace Topbar {

  public class Utils {

    private const string apps_relative_path = ".config/rofi/launchers/type-3/launcher.sh";
    private const string power_menu_relative_path = ".config/rofi/powermenu/type-5/powermenu.sh";
    private const string bluetooth_menu_path = "scripts/bluetooth.sh";
    private static IconTheme icon_theme;

    public static string get_full_path (string relative_path) {
      return Path.build_filename (Environment.get_home_dir (), relative_path);
    }

    private static string get_exe_dir () throws FileError {
      string exe_path = FileUtils.read_link ("/proc/self/exe");
      return Path.get_dirname (exe_path);
    }

    public static string get_asset_path (string relative_path) throws FileError {
      return Path.build_filename (get_exe_dir (), relative_path);
    }

    public static async string get_file_contents_async (string path) throws Error {
      uint8[] contents;
      var file = File.new_for_path (path);
      yield file.load_contents_async (null, out contents, null);

      return (string) contents;
    }

    public static bool icon_exists (string icon_name) {
      if (icon_theme == null)
        icon_theme = IconTheme.get_for_display (Gdk.Display.get_default ());
      return icon_theme.has_icon (icon_name);
    }

    public static async string run_script (string[] argv) throws Error {
      var subprocess = new Subprocess.newv (
        argv,
        SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE
      );

      Bytes stdout_bytes;
      Bytes stderr_bytes;
      yield subprocess.communicate_async (null, null, out stdout_bytes, out stderr_bytes);

      if (!subprocess.get_successful ()) {
        throw new Error (
                Quark.from_string ("command-error"),
                subprocess.get_exit_status (),
                "Command failed: %s",
                (string) stderr_bytes.get_data ()
        );
      }

      var data = stdout_bytes.get_data ();
      return (data == null) ? null : ((string) data).strip ();
    }

    public static void run_script_async (string[] argv) {
      try {
        new Subprocess.newv (argv,
                             SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
      } catch (Error e) {
        warning ("Failed to run script: %s", e.message);
      }
    }

    public static void launch_apps () {
      Utils.run_script_async ({ Utils.get_full_path (apps_relative_path) });
    }

    public static void launch_bluetooth_menu () {
      Utils.run_script_async ({ Utils.get_full_path (bluetooth_menu_path) });
    }

    public static void launch_power_menu () {
      Utils.run_script_async ({ Utils.get_full_path (power_menu_relative_path) });
    }

    public static void launch_btop () {
      Utils.run_script_async ({ "kitty", "-e", "btop" });
    }

    public static void send_notification (string summary, string body) {
      // Create and show notification
      var notification = new Notification (summary);
      notification.set_body (body);
      GLib.Application.get_default ().send_notification (null, notification);
    }

    public static async void launch_color_picker () {
      try {
        var subprocess = new Subprocess.newv (
          { "niri", "msg", "pick-color" },
          SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE
        );

        Bytes stdout, stderr;
        yield subprocess.communicate_async (null, null, out stdout, out stderr);

        string output = (string) stdout.get_data ();
        output = output.strip ();

        if (subprocess.get_exit_status () == 0 && output.length > 0) {
          if (output == "No color was picked.")return;

          // Extract color and copy to clipboard
          var color = "#" + output.split ("#")[1];
          Utils.run_script_async ({ "wl-copy", "-n", color });

          // Send Notification
          var msg = @"\n<span color='$color'><i><b>$color</b></i></span> copied to clipboard";
          send_notification ("Color Picker", msg);
        } else {
          printerr ("Error: %s\n", (string) stderr.get_data ());
        }
      } catch (Error e) {
        warning ("Failed to run script: %s", e.message);
      }
    }
  }
}
