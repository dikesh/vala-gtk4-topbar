using Gdk;
using Gtk;
using Gee;

namespace Topbar {

  public class App : Gtk.Application {

    // Monitor → Bar mapping
    private HashMap<Monitor, Bar> bars;

    // Monitor list reference (so signal stays valid)
    private ListModel ? monitor_list;

    public App () {
      Object (application_id : "com.github.dikesh.Topbar", flags: ApplicationFlags.HANDLES_OPEN);
    }

    protected override void startup () {
      base.startup ();
      bars = new HashMap<Monitor, Bar>();

      // Initialize services early
      VolumeOSDIpc.get_default ();

      IconTheme.get_for_display (Display.get_default ()).add_resource_path (
        "/com/github/dikesh/topbar/icons");
      load_css ();
    }

    protected override void activate () {

      var display = Display.get_default ();
      if (display == null)return;

      monitor_list = display.get_monitors ();

      // Initial sync
      sync_monitors ();

      // Listen for monitor hotplug
      monitor_list.items_changed.connect (on_monitors_changed);

      // Detect display shutdown
      display.closed.connect (() => { destroy_all_bars (); });
    }

    /**
     * Load CSS globally once
     */
    private void load_css () {

      var provider = new CssProvider ();
      provider.load_from_resource ("/com/github/dikesh/topbar/style.css");

      StyleContext.add_provider_for_display (
        Display.get_default (),
        provider,
        STYLE_PROVIDER_PRIORITY_APPLICATION
      );
    }

    /**
     * Signal handler wrapper
     */
    private void on_monitors_changed (uint position, uint removed, uint added) {
      sync_monitors ();
    }

    /**
     * Synchronize bars with actual connected monitors
     *
     * Safe against:
     * - unordered HashMap
     * - monitor reorder
     * - hotplug
     * - Wayland dynamic updates
     */
    private void sync_monitors () {

      var display = Display.get_default ();
      if (display == null)return;

      var model = display.get_monitors ();

      var active_monitors = new HashSet<Monitor>();

      // Add missing bars
      for (uint i = 0; i < model.get_n_items (); i++) {
        var monitor = (Monitor) model.get_item (i);
        active_monitors.add (monitor);
        if (!bars.has_key (monitor))create_bar (monitor);
      }

      // Remove stale bars
      var stale_monitors = new ArrayList<Monitor>();

      foreach (var monitor in bars.keys) {
        if (!active_monitors.contains (monitor))
          stale_monitors.add (monitor);
      }

      foreach (var monitor in stale_monitors)
        destroy_bar (monitor);
    }

    /**
     * Create bar safely
     */
    private void create_bar (Monitor monitor) {

      var bar = new Bar (this, monitor);
      bars.set (monitor, bar);

      // Auto-remove from HashMap when bar destroyed Prevents stale references
      bar.close_request.connect (() => {
        if (bars.has_key (monitor)) {
          bars.unset (monitor);
          debug ("Auto-removed bar for monitor %p", monitor);
        }
        return false; // allow closing
      });

      // Detect monitor geometry changes
      monitor.notify["geometry"].connect (() => {
        if (bars.has_key (monitor)) {
          var existing_bar = bars.get (monitor);
          if (existing_bar != null)existing_bar.queue_allocate ();
        }
      });

      bar.present ();
      debug ("Created bar for monitor %p", monitor);
    }

    /**
     * Destroy bar safely
     */
    private void destroy_bar (Monitor monitor) {
      var bar = bars.get (monitor);
      if (bar == null)return;

      // destroy signal will auto-remove from HashMap
      bar.destroy ();
      debug ("Destroyed bar for monitor %p", monitor);
    }

    /**
     * Destroy everything safely
     */
    private void destroy_all_bars () {
      var monitors = new ArrayList<Monitor>();
      foreach (var monitor in bars.keys)monitors.add (monitor);
      foreach (var monitor in monitors)destroy_bar (monitor);
    }
  }
}
