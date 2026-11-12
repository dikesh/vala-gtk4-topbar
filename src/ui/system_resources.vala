using Gtk;

namespace Topbar {

  // --------------- CPU --------------------------
  private class CPU : Box {

    public CPU () {
      Object (spacing: 4);
      set_css_classes ({ "system-resource-widget" });

      var cpu = CPUService.get_default ();

      var cpu_usage = new Label (cpu.avg_cpu);
      cpu.updated.connect (() => { cpu_usage.label = cpu.avg_cpu; });

      append (new Image.from_icon_name ("topbar-cpu-symbolic"));
      append (cpu_usage);
    }
  }

  // --------------- Memory --------------------------
  private class RAM : Box {

    public RAM () {
      Object (spacing: 4);
      set_css_classes ({ "system-resource-widget" });

      var memory = MemoryService.get_default ();
      set_tooltip_text (get_tooltip (memory));

      var mem_usage = new Label (memory.used_gi);
      memory.updated.connect (() => {
        mem_usage.label = memory.used_gi;
        set_tooltip_text (get_tooltip (memory));
      });

      append (new Image.from_icon_name ("topbar-memory-symbolic"));
      append (mem_usage);
    }

    private string get_tooltip (MemoryService memory) {
      return "Available: %s / %s".printf (memory.available_gi, memory.total_gi);
    }
  }

  // --------------- Temperature --------------------------
  private class Temperature : Box {

    public Temperature () {
      Object (spacing: 4);
      set_css_classes ({ "system-resource-widget" });

      var cpu_temp = TemperatureService.get_default ();

      var cpu_temp_widget = new Label ("%d°C".printf ((int) cpu_temp.temp_c));
      cpu_temp.updated.connect (() => {
        cpu_temp_widget.label = "%d°C".printf ((int) cpu_temp.temp_c);
      });

      append (new Image.from_icon_name ("topbar-temperature-symbolic"));
      append (cpu_temp_widget);
    }
  }

  // --------------- Disk Usage --------------------------
  private class DiskUsage : Box {

    public DiskUsage () {
      Object (spacing: 4);
      set_css_classes ({ "system-resource-widget" });

      var disk_service = DiskService.get_default ();
      set_tooltip_text (get_tooltip (disk_service));

      var root_usage = new Label (disk_service.available_gi);
      disk_service.updated.connect (() => {
        root_usage.label = disk_service.available_gi;
        set_tooltip_text (get_tooltip (disk_service));
      });

      append (new Image.from_icon_name ("topbar-disk-symbolic"));
      append (root_usage);
    }

    private string get_tooltip (DiskService disk_service) {
      return "%s used out of %s".printf (disk_service.used_gi, disk_service.total_gi);
    }
  }

  // --------------- System Resources --------------------------
  public class SystemResources : Gtk.Box {

    public SystemResources () {
      Object (spacing: 16);
      set_css_classes ({ "bar-section" });
      set_cursor_from_name ("pointer");

      // Append widgets
      append (new CPU ());
      append (new RAM ());
      append (new Temperature ());
      append (new DiskUsage ());

      // Open btop on box click
      var gesture = new GestureClick ();
      gesture.pressed.connect (Utils.launch_btop);
      add_controller (gesture);
    }
  }
}
