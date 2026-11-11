using Gee;

namespace Topbar {
  // com.canonical.dbusmenu is not the org.gtk.Menus protocol used by
  // GLib.DBusMenuModel. Keep its layout and actions local to the panel.
  public class TrayMenu : Object {
    private const string INTERFACE = "com.canonical.dbusmenu";
    private const string[] LAYOUT_PROPERTIES = {
      "label", "enabled", "visible", "children-display", "type",
      "toggle-type", "toggle-state", "icon-name", "icon-data"
    };
    private const string[] PRESENTATION_PROPERTIES = {
      "label", "type", "visible", "children-display", "icon-name", "icon-data", "toggle-type"
    };
    private DBusConnection connection;
    private string bus_name;
    private string object_path;
    private HashMap<int, MenuNode> nodes = new HashMap<int, MenuNode> ();
    private MenuNode root;
    private SimpleActionGroup actions = new SimpleActionGroup ();
    private Cancellable? visible_cancellable;
    private uint subscription_id;
    private uint visible_count;
    private uint generation;
    private uint updates_serial;
    private uint request_serial;
    private uint applied_serial;
    private bool root_opened;
    private RootOpening? root_opening;
    private bool stopped;
    private bool refreshing;
    private bool refresh_again;

    public MenuModel menu_model { get { return root.model; } }
    public ActionGroup action_group { get { return actions; } }

    internal TrayMenu (DBusConnection connection, string bus_name, string object_path) {
      this.connection = connection;
      this.bus_name = bus_name;
      this.object_path = object_path;
      root = new MenuNode (0);
      nodes[0] = root;
    }

    // Every prepare, including one still in flight or returning an error, owns
    // one visibility reference. Its caller must eventually balance it with close.
    public async void prepare () throws Error {
      if (stopped)
        throw new IOError.CLOSED ("The tray menu has been removed");

      if (visible_count++ == 0) {
        generation++;
        visible_cancellable = new Cancellable ();
        weak TrayMenu owner = this;
        subscription_id = connection.signal_subscribe (
          bus_name, INTERFACE, null, object_path, null, DBusSignalFlags.NONE,
          (conn, sender, path, iface, name, parameters) => {
            if (owner != null)
              owner.handle_signal (name, parameters);
          });
      }

      uint current = generation;
      var cancellable = visible_cancellable;
      yield about_to_show (0, cancellable);
      ensure_current (current);
      yield load_layout (current, cancellable);
      ensure_current (current);
      yield open_root (current, cancellable);
    }

    private async void open_root (uint current, Cancellable? cancellable) throws Error {
      var opening = root_opening;
      if (opening == null) {
        opening = new RootOpening ();
        root_opening = opening;
        root_opened = true;
        try {
          yield send_event (0, "opened", cancellable);
        } catch (Error error) {
          opening.error = error;
        }
        opening.done = true;
        opening.finished ();
      } else if (!opening.done) {
        SourceFunc resume = open_root.callback;
        ulong handler = opening.finished.connect (() => { resume (); });
        yield;
        opening.disconnect (handler);
      }
      ensure_current (current);
      if (opening.error != null)
        throw opening.error.copy ();
    }

    public void close () {
      if (visible_count == 0)
        return;
      if (--visible_count != 0)
        return;

      generation++;
      visible_cancellable.cancel ();
      visible_cancellable = null;
      root_opening = null;
      if (subscription_id != 0) {
        connection.signal_unsubscribe (subscription_id);
        subscription_id = 0;
      }
      foreach (var node in nodes.values)
        close_submenu (node);
      if (root_opened) {
        root_opened = false;
        dispatch_event (0, "closed");
      }
    }

    // TrayItem calls stop on removal/replacement, not merely when a popup closes.
    public void stop () {
      if (stopped)
        return;
      stopped = true;
      if (visible_count != 0) {
        visible_count = 1;
        close ();
      }
      foreach (var node in nodes.values)
        remove_action (node);
      root.model.remove_all ();
      nodes.clear ();
    }

    protected override void dispose () {
      stop ();
      base.dispose ();
    }

    private bool is_current (uint current) {
      return !stopped && visible_count != 0 && generation == current;
    }

    private void ensure_current (uint current) throws IOError {
      if (!is_current (current))
        throw new IOError.CANCELLED ("The tray menu was closed");
    }

    private async bool about_to_show (int id, Cancellable? cancellable) throws Error {
      var reply = yield connection.call (
        bus_name, object_path, INTERFACE, "AboutToShow", new Variant ("(i)", id),
        new VariantType ("(b)"), DBusCallFlags.NONE, -1, cancellable);
      return reply.get_child_value (0).get_boolean ();
    }

    private async void send_event (int id, string name, Cancellable? cancellable) throws Error {
      yield connection.call (
        bus_name, object_path, INTERFACE, "Event",
        new Variant ("(isvu)", id, name, new Variant.int32 (0),
                     (uint32) (GLib.get_monotonic_time () / 1000)),
        new VariantType ("()"), DBusCallFlags.NONE, -1, cancellable);
    }

    private void dispatch_event (int id, string name) {
      // Closed events must outlive the visibility cancellable they just closed.
      send_event.begin (id, name, null, (obj, result) => {
        try {
          send_event.end (result);
        } catch (Error error) {
          warning ("Tray menu %s event failed: %s", name, error.message);
        }
      });
    }

    private async void load_layout (uint current, Cancellable? cancellable) throws Error {
      while (true) {
        ensure_current (current);
        uint updates = updates_serial;
        uint request = ++request_serial;
        unowned string[] properties = LAYOUT_PROPERTIES;
        var reply = yield connection.call (
          bus_name, object_path, INTERFACE, "GetLayout",
          new Variant ("(ii^as)", 0, -1, properties),
          new VariantType ("(u(ia{sv}av))"), DBusCallFlags.NONE, -1, cancellable);
        ensure_current (current);
        // A property/layout signal received during the request can be newer than
        // its snapshot. Fetch again instead of overwriting that signal's changes.
        if (updates != updates_serial)
          continue;
        if (request < applied_serial)
          return;
        var seen = new HashSet<int> ();
        var layout = parse_layout (reply.get_child_value (1), seen);
        if (layout.id != 0)
          throw new IOError.INVALID_DATA ("The tray menu layout has no root item");
        apply_layout (layout);
        applied_serial = request;
        return;
      }
    }

    private LayoutNode parse_layout (Variant value, HashSet<int> seen) throws Error {
      if (!value.is_of_type (new VariantType ("(ia{sv}av)")))
        throw new IOError.INVALID_DATA ("Invalid tray menu layout");
      int id = value.get_child_value (0).get_int32 ();
      if (!seen.add (id))
        throw new IOError.INVALID_DATA ("Duplicate tray menu item %d", id);
      var layout = new LayoutNode (id);
      var properties = value.get_child_value (1).iterator ();
      string name;
      Variant property;
      while (properties.next ("{sv}", out name, out property))
        layout.properties[name] = property;
      var children = value.get_child_value (2).iterator ();
      Variant? child;
      while ((child = children.next_value ()) != null)
        layout.children.add (parse_layout (child.get_variant (), seen));
      return layout;
    }

    private void apply_layout (LayoutNode layout) {
      var next = new HashMap<int, MenuNode> ();
      var dirty = new HashSet<MenuNode> ();
      reconcile (layout, null, next, dirty);
      foreach (var node in nodes.values) {
        if (!next.has_key (node.id)) {
          close_submenu (node);
          remove_action (node);
        }
      }
      nodes = next;
      foreach (var node in dirty)
        render_children (node);
    }

    private MenuNode reconcile (LayoutNode layout, MenuNode? parent,
                                HashMap<int, MenuNode> next, HashSet<MenuNode> dirty) {
      var node = nodes[layout.id];
      if (node == null)
        node = new MenuNode (layout.id);
      bool was_submenu = node.is_submenu ();
      bool presentation_changed = !same_presentation (node.properties, layout.properties);
      bool children_changed = node.children.size != layout.children.size;
      if (!children_changed) {
        for (int i = 0; i < node.children.size; i++) {
          if (node.children[i].id != layout.children[i].id) {
            children_changed = true;
            break;
          }
        }
      }
      node.properties = layout.properties;
      node.parent = parent;
      next[node.id] = node;
      var children = new ArrayList<MenuNode> ();
      foreach (var child in layout.children)
        children.add (reconcile (child, node, next, dirty));
      node.children = children;
      if (children_changed)
        dirty.add (node);
      if (parent != null && (presentation_changed || was_submenu != node.is_submenu ()))
        dirty.add (parent);
      sync_action (node);
      return node;
    }

    private static bool same_presentation (HashMap<string, Variant> first,
                                           HashMap<string, Variant> second) {
      foreach (var name in PRESENTATION_PROPERTIES) {
        var a = first[name];
        var b = second[name];
        if ((a == null) != (b == null) || (a != null && !a.equal (b)))
          return false;
      }
      return true;
    }

    private void remove_action (MenuNode node) {
      if (node.action == null)
        return;
      node.action.disconnect (node.action_handler);
      actions.remove_action (node.action.name);
      node.action = null;
      node.action_handler = 0;
      node.action_kind = "";
    }

    private void sync_action (MenuNode node) {
      if (node.id == 0)
        return;
      string kind = node.string_property ("type") == "separator" ? "separator"
        : node.is_submenu () ? "submenu" : node.string_property ("toggle-type");
      if (kind != "separator" && kind != "submenu" && kind != "checkmark" && kind != "radio")
        kind = "plain";
      if (node.action_kind != kind) {
        close_submenu (node);
        remove_action (node);
        node.action_kind = kind;
        int id = node.id;
        string name = "item%d".printf (id);
        weak TrayMenu owner = this;
        if (kind == "separator")
          return;
        if (kind == "submenu") {
          node.action = new SimpleAction.stateful (name, null, new Variant.boolean (false));
          node.action_handler = node.action.change_state.connect ((state) => {
            if (owner != null && state != null)
              owner.set_submenu_open (id, state.get_boolean ());
          });
        } else {
          if (kind == "checkmark")
            node.action = new SimpleAction.stateful (name, null, new Variant.boolean (false));
          else if (kind == "radio")
            node.action = new SimpleAction.stateful (name, VariantType.STRING, new Variant.string (""));
          else
            node.action = new SimpleAction (name, null);
          node.action_handler = node.action.activate.connect (() => {
            if (owner != null)
              owner.activate_item (id);
          });
        }
        actions.add_action (node.action);
      }
      if (node.action == null)
        return;
      node.action.set_enabled (node.bool_property ("enabled", true) && node.bool_property ("visible", true));
      if (!node.action.enabled)
        close_submenu (node);
      if (kind == "checkmark")
        node.action.set_state (new Variant.boolean (node.int_property ("toggle-state") == 1));
      else if (kind == "radio")
        node.action.set_state (new Variant.string (node.int_property ("toggle-state") == 1 ? "selected" : ""));
    }

    private void render_children (MenuNode node) {
      node.model.remove_all ();
      var section = new GLib.Menu ();
      foreach (var child in node.children) {
        if (!child.bool_property ("visible", true))
          continue;
        if (child.string_property ("type") == "separator") {
          if (section.get_n_items () != 0) {
            node.model.append_section (null, section);
            section = new GLib.Menu ();
          }
          continue;
        }
        var item = new GLib.MenuItem (child.string_property ("label"), null);
        string action_name = "dbusmenu.item%d".printf (child.id);
        if (child.is_submenu ()) {
          item.set_submenu (child.model);
          item.set_attribute ("submenu-action", "s", action_name);
        } else {
          item.set_action_and_target_value (action_name,
            child.action_kind == "radio" ? new Variant.string ("selected") : null);
        }
        string icon_name = child.string_property ("icon-name");
        if (icon_name != "") {
          item.set_icon (new ThemedIcon (icon_name));
        } else {
          var data = child.properties["icon-data"];
          if (data != null && data.is_of_type (new VariantType ("ay")))
            item.set_icon (new BytesIcon (data.get_data_as_bytes ()));
        }
        section.append_item (item);
      }
      if (section.get_n_items () != 0)
        node.model.append_section (null, section);
    }

    private void activate_item (int id) {
      var node = nodes[id];
      if (stopped || visible_count == 0 || node == null || node.action == null || !node.action.enabled)
        return;
      // The exporter remains the authority on toggle/radio state.
      dispatch_event (id, "clicked");
    }

    private void set_submenu_open (int id, bool open) {
      var node = nodes[id];
      if (node == null || node.action_kind != "submenu")
        return;
      if (!open) {
        close_submenu (node);
        return;
      }
      if (stopped || visible_count == 0 || !node.action.enabled || node.submenu_open)
        return;
      node.submenu_open = true;
      node.action.set_state (new Variant.boolean (true));
      uint current = generation;
      uint submenu_generation = ++node.submenu_generation;
      open_submenu.begin (node, current, submenu_generation, visible_cancellable, (obj, result) => {
        try {
          open_submenu.end (result);
        } catch (Error error) {
          if (!(error is IOError.CANCELLED))
            warning ("Failed to open tray submenu: %s", error.message);
          if (submenu_current (node, current, submenu_generation))
            close_submenu (node);
        }
      });
    }

    private async void open_submenu (MenuNode node, uint current, uint submenu_generation,
                                     Cancellable? cancellable) throws Error {
      bool changed = yield about_to_show (node.id, cancellable);
      if (!submenu_current (node, current, submenu_generation))
        return;
      if (changed || node.children.size == 0)
        yield load_layout (current, cancellable);
      if (!submenu_current (node, current, submenu_generation))
        return;
      node.submenu_opened = true;
      yield send_event (node.id, "opened", cancellable);
    }

    private bool submenu_current (MenuNode node, uint current, uint submenu_generation) {
      return is_current (current) && nodes[node.id] == node && node.submenu_open
        && node.submenu_generation == submenu_generation;
    }

    private void close_submenu (MenuNode node) {
      if (!node.submenu_open)
        return;
      node.submenu_open = false;
      node.submenu_generation++;
      if (node.action != null && node.action_kind == "submenu")
        node.action.set_state (new Variant.boolean (false));
      if (node.submenu_opened) {
        node.submenu_opened = false;
        dispatch_event (node.id, "closed");
      }
    }

    private void handle_signal (string name, Variant parameters) {
      if (stopped || visible_count == 0)
        return;
      if (name == "LayoutUpdated") {
        updates_serial++;
        schedule_refresh ();
      } else if (name == "ItemsPropertiesUpdated") {
        if (!parameters.is_of_type (new VariantType ("(a(ia{sv})a(ias))"))) {
          warning ("Invalid tray menu property update");
          return;
        }
        updates_serial++;
        var touched = new HashSet<MenuNode> ();
        var dirty = new HashSet<MenuNode> ();
        var changed = parameters.get_child_value (0).iterator ();
        Variant? entry;
        while ((entry = changed.next_value ()) != null) {
          var node = nodes[entry.get_child_value (0).get_int32 ()];
          if (node == null)
            continue;
          var properties = entry.get_child_value (1).iterator ();
          string property_name;
          Variant property;
          while (properties.next ("{sv}", out property_name, out property)) {
            node.properties[property_name] = property;
            if (presentation_property (property_name) && node.parent != null)
              dirty.add (node.parent);
          }
          touched.add (node);
        }
        var removed = parameters.get_child_value (1).iterator ();
        while ((entry = removed.next_value ()) != null) {
          var node = nodes[entry.get_child_value (0).get_int32 ()];
          if (node == null)
            continue;
          var properties = entry.get_child_value (1).iterator ();
          string property_name;
          while (properties.next ("s", out property_name)) {
            node.properties.unset (property_name);
            if (presentation_property (property_name) && node.parent != null)
              dirty.add (node.parent);
          }
          touched.add (node);
        }
        foreach (var node in touched)
          sync_action (node);
        foreach (var node in dirty)
          render_children (node);
      }
    }

    private static bool presentation_property (string name) {
      return name == "label" || name == "type" || name == "visible" || name == "children-display"
        || name == "icon-name" || name == "icon-data" || name == "toggle-type";
    }

    private void schedule_refresh () {
      refresh_again = true;
      if (refreshing)
        return;
      refreshing = true;
      uint current = generation;
      refresh_background.begin (current, visible_cancellable, (obj, result) => {
        refresh_background.end (result);
        refreshing = false;
        // An old lifecycle's callback must not swallow a new popup's update.
        if (refresh_again && !stopped && visible_count != 0)
          schedule_refresh ();
      });
    }

    private async void refresh_background (uint current, Cancellable? cancellable) {
      while (is_current (current) && refresh_again) {
        refresh_again = false;
        try {
          yield load_layout (current, cancellable);
        } catch (Error error) {
          if (!(error is IOError.CANCELLED))
            warning ("Failed to refresh tray menu: %s", error.message);
          return;
        }
      }
    }

    private class MenuNode : Object {
      public int id;
      public HashMap<string, Variant> properties = new HashMap<string, Variant> ();
      public ArrayList<MenuNode> children = new ArrayList<MenuNode> ();
      public weak MenuNode? parent;
      public GLib.Menu model = new GLib.Menu ();
      public SimpleAction? action;
      public ulong action_handler;
      public string action_kind = "";
      public bool submenu_open;
      public bool submenu_opened;
      public uint submenu_generation;

      public MenuNode (int id) {
        this.id = id;
      }

      public string string_property (string name) {
        var value = properties[name];
        return value != null && value.is_of_type (VariantType.STRING) ? value.get_string () : "";
      }

      public bool bool_property (string name, bool default_value) {
        var value = properties[name];
        return value != null && value.is_of_type (VariantType.BOOLEAN) ? value.get_boolean () : default_value;
      }

      public int int_property (string name) {
        var value = properties[name];
        return value != null && value.is_of_type (VariantType.INT32) ? value.get_int32 () : 0;
      }

      public bool is_submenu () {
        return string_property ("children-display") == "submenu" || children.size != 0;
      }
    }

    private class RootOpening : Object {
      public bool done;
      public Error? error;
      public signal void finished ();
    }

    private class LayoutNode : Object {
      public int id;
      public HashMap<string, Variant> properties = new HashMap<string, Variant> ();
      public ArrayList<LayoutNode> children = new ArrayList<LayoutNode> ();

      public LayoutNode (int id) {
        this.id = id;
      }
    }
  }
}
