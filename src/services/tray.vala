using Gee;

namespace Topbar {

  // ------------------------- Pixmap -------------------------
  public struct Pixmap {
    int width;
    int height;
    uint8[] bytes;

    internal static Pixmap from_variant (Variant variant) {
      Pixmap pixmap = Pixmap ();

      int width, height;
      Variant data;

      variant.get ("(ii@ay)", out width, out height, out data);
      pixmap.width = width;
      pixmap.height = height;
      pixmap.bytes = data.get_data_as_bytes ().get_data ();

      return pixmap;
    }

    internal static Pixmap[] array_from_variant (Variant variant) {
      Pixmap[] icons = new Pixmap[0];

      VariantIter iter = variant.iterator ();

      Variant child;
      while ((child = iter.next_value ()) != null) {
        Pixmap pm = Pixmap.from_variant (child);
        icons += pm;
      }
      return icons;
    }
  }

  // ------------------------- Tooltip -------------------------
  public struct Tooltip {
    string icon_name;
    Pixmap[] icon;
    string title;
    string description;

    internal static Tooltip from_variant (Variant variant) {
      Tooltip tooltip = Tooltip ();

      string icon_name;
      VariantIter iter;
      string title;
      string description;

      variant.get ("(sa(iiay)ss)", out icon_name, out iter, out title, out description);
      tooltip.icon_name = icon_name;
      tooltip.title = title;
      tooltip.description = description;

      Variant child;

      Pixmap[] icons = new Pixmap[0];

      while ((child = iter.next_value ()) != null) {
        Pixmap pm = Pixmap.from_variant (child);
        icons += pm;
      }

      tooltip.icon = icons;

      return tooltip;
    }
  }

  [DBus (use_string_marshalling = true)]
  public enum Category {
    [DBus (value = "ApplicationStatus"), Description (nick = "ApplicationStatus")]
    APPLICATION,

    [DBus (value = "Communications"), Description (nick = "Communications")]
    COMMUNICATIONS,

    [DBus (value = "SystemServices"), Description (nick = "SystemServices")]
    SYSTEM,

    [DBus (value = "Hardware"), Description (nick = "Hardware")]
    HARDWARE;

    public string to_nick () {
      var enumc = (EnumClass) typeof (Category).class_ref ();
      unowned var eval = enumc.get_value (this);
      return eval.value_nick;
    }

    public static extern Category from_string (string value) throws Error;
  }

  [DBus (use_string_marshalling = true)]
  public enum Status {
    [DBus (value = "Passive"), Description (nick = "Passive")]
    PASSIVE,

    [DBus (value = "Active"), Description (nick = "Active")]
    ACTIVE,

    [DBus (value = "NeedsAttention"), Description (nick = "NeedsAttention")]
    NEEDS_ATTENTION;

    public string to_nick () {
      var enumc = (EnumClass) typeof (Status).class_ref ();
      unowned var eval = enumc.get_value (this);
      return eval.value_nick;
    }

    public static extern Status from_string (string value) throws Error;
  }

  [DBus (name = "org.kde.StatusNotifierItem")]
  internal interface IItem : DBusProxy {
    public abstract async void ContextMenu (int x, int y) throws DBusError, IOError;
    public abstract async void Activate (int x, int y) throws DBusError, IOError;
    public abstract async void SecondaryActivate (int x, int y) throws DBusError, IOError;
    public abstract async void Scroll (int delta, string orientation) throws DBusError, IOError;

    public signal void NewTitle ();
    public signal void NewIcon ();
    public signal void NewAttentionIcon ();
    public signal void NewOverlayIcon ();
    public signal void NewToolTip ();
    public signal void NewStatus (string status);
  }

  // ------------------------- TrayItem -------------------------
  public class TrayItem : Object {
    private IItem proxy;
    private bool needs_update = false;
    private bool stopped;
    private Cancellable cancellable = new Cancellable ();
    private uint refresh_source;
    private ulong signal_handler;
    private ulong properties_handler;
    private ulong owner_handler;
    private static HashMap<string, string ?> icon_path_cache = new HashMap<string, string ?> ();

    /** The Title of the TrayItem */
    public string title { get; private set; }

    /** The category this item belongs to */
    public Category category { get; private set; }

    /** The current status of this item */
    public Status status { get; private set; }

    /** The tooltip of this item */
    public Tooltip ? tooltip { get; private set; }

    /**
     * Show the context menu for this tray item.
     */
    public async void show_context_menu (int x, int y) {
      if (stopped || proxy == null || menu != null)
        return;
      try {
        yield proxy.ContextMenu (x, y);
      } catch (Error error) {
        if (!stopped)
          warning ("Failed to show tray context menu: %s", error.message);
      }
    }

    /**
     * A markup representation of the tooltip. This is basically equvivalent
     * to `tooltip.title \n tooltip.description`
     */
    public string tooltip_markup {
      owned get {
        if (tooltip == null)return "";

        var tt = Markup.escape_text (tooltip.title);
        if (tooltip.description != "")tt += "\n" + tooltip.description;

        return tt;
      }
    }

    /**
     * A text representation of the tooltip. This is basically equvivalent
     * to `tooltip.title \n tooltip.description.`
     */
    public string tooltip_text {
      owned get {
        if (tooltip == null)return "";

        var tt = tooltip.title;
        if (tooltip.description != "")tt += "\n" + tooltip.description;

        return tt;
      }
    }

    /** the id of the item. This id is specified by the tray app.*/
    public string id { get; private set; }

    /**
     * If set, this only supports the menu, so showing the menu should be prefered
     * over calling [method@TrayService.TrayItem.activate].
     */
    public bool is_menu { get; private set; default = true; }

    /**
     * The icon theme path, where to look for the [property@TrayService.TrayItem:icon-name].
     * It is recommended to use the [property@TrayService.TrayItem:gicon] property,
     * which does the icon lookups for you.
     */
    public string icon_theme_path { get; private set; }

    // icon properties from the dbus for internal use only
    private string IconName;
    private Pixmap[] IconPixmap;
    private string AttentionIconName;
    private Pixmap[] AttentionIconPixmap;
    private string OverlayIconName;
    private Pixmap[] OverlayIconPixmap;

    /**
     * The name of the icon. This should be looked up in the [property@TrayService.TrayItem:icon-theme-path]
     * if set or in the currently used icon theme otherwise.
     * It is recommended to use the [property@TrayService.TrayItem:gicon] property,
     * which does the icon lookups for you.
     */
    public string icon_name {
      owned get {
        return status == Status.NEEDS_ATTENTION
                ? AttentionIconName
                : IconName;
      }
    }

    /**
     * A pixbuf containing the icon.
     * It is recommended to use the [property@TrayService.TrayItem:gicon] property,
     * which does the icon lookups for you.
     */
    public Gdk.Pixbuf icon_pixbuf { owned get {
                                      return _get_icon_pixbuf ();
                                    } }

    /**
     * Contains the items icon. This property is intended to be used with the gicon property
     * of the Icon widget and the recommended way to display the icon.
     * This property unifies the [property@TrayService.TrayItem:icon-name],
     * [property@TrayService.TrayItem:icon-theme-path] and [property@TrayService.TrayItem:icon-pixbuf] properties.
     */
    public Icon gicon { get; private set; }

    /** The id of the item used to uniquely identify the TrayItems by this lib.*/
    public string item_id { get; private set; }

    /** The object path to the dbusmenu */
    public ObjectPath menu_path { get; private set; }

    /** The locally translated com.canonical.dbusmenu, if exported by the item. */
    public TrayMenu? menu { get; private set; }

    public signal void changed ();
    public signal void ready ();

    internal TrayItem (string service, string path) {
      item_id = service + path;
      setup_proxy.begin (service, path, (_, res) => setup_proxy.end (res));
    }

    private async void setup_proxy (string service, string path) {
      try {
        var item_proxy = yield Bus.get_proxy<IItem> (
          BusType.SESSION, service, path, DBusProxyFlags.NONE, cancellable);
        if (stopped)
          return;
        proxy = item_proxy;
        signal_handler = proxy.g_signal.connect (handle_signal);
        properties_handler = proxy.g_properties_changed.connect (() => queue_refresh ());
        owner_handler = proxy.notify["g-name-owner"].connect (() => {
          if (menu != null) {
            menu.stop ();
            menu = null;
          }
          // A replacement owner must get a fresh menu even at the same path.
          menu_path = (ObjectPath) "/";
          queue_refresh ();
        });
        yield refresh_all_properties ();
        if (!stopped)
          ready ();
      } catch (Error error) {
        if (!stopped)
          warning ("Failed to initialize tray item: %s", error.message);
      }
    }

    internal void stop () {
      if (stopped)
        return;
      stopped = true;
      cancellable.cancel ();
      if (refresh_source != 0) {
        Source.remove (refresh_source);
        refresh_source = 0;
      }
      if (proxy != null) {
        if (signal_handler != 0)
          proxy.disconnect (signal_handler);
        if (properties_handler != 0)
          proxy.disconnect (properties_handler);
        if (owner_handler != 0)
          proxy.disconnect (owner_handler);
      }
      if (menu != null) {
        menu.stop ();
        menu = null;
      }
    }

    protected override void dispose () {
      stop ();
      base.dispose ();
    }

    private void update_gicon () {
      if ((icon_name != null) && (icon_name != "")) {
        if (FileUtils.test (icon_name, FileTest.EXISTS)) {
          gicon = new FileIcon (File.new_for_path (icon_name));
        } else if ((icon_theme_path != null) && (icon_theme_path != "")) {
          string path = find_icon_in_theme (icon_name, icon_theme_path);
          if (path != null) {
            gicon = new FileIcon (File.new_for_path (path));
          } else {
            gicon = new ThemedIcon (icon_name);
          }
        } else {
          gicon = new ThemedIcon (icon_name);
        }
      } else {
        Pixmap[] pixmaps = (status == Status.NEEDS_ATTENTION)
                ? AttentionIconPixmap
                : IconPixmap;
        gicon = pixmap_to_pixbuf (pixmaps);
      }
    }

    private void handle_signal (DBusProxy proxy, string ? sender_name, string signal_name,
                                Variant parameters) {
      queue_refresh ();
    }

    private void queue_refresh () {
      if (stopped || needs_update)
        return;
      needs_update = true;
      refresh_source = Timeout.add (10, () => {
        refresh_source = 0;
        needs_update = false;
        if (!stopped)
          refresh_all_properties.begin ();
        return Source.REMOVE;
      });
    }

    private void set_dbus_property (string prop_name, Variant prop_value) {
      try {
        switch (prop_name) {
          case "Category" : {
              var new_category = Category.from_string (prop_value.get_string ());
              if (category != new_category) {
                category = new_category;
              }
              break;
          }
          case "Id" : {
              var new_id = prop_value.get_string ();
              if (id != new_id) {
                id = new_id;
              }
              break;
          }
          case "Title" : {
              var new_title = prop_value.get_string ();
              if (title != new_title) {
                title = new_title;
              }
              break;
          }
          case "Status" : {
              var new_status = Status.from_string (prop_value.get_string ());
              if (status != new_status) {
                status = new_status;
                update_gicon ();
              }
              break;
          }
          case "ToolTip" : {
              tooltip = Tooltip.from_variant (prop_value);
              break;
          }
          case "IconThemePath": {
            var new_path = prop_value.get_string ();
            if (icon_theme_path != new_path) {
              icon_theme_path = new_path;
              update_gicon ();
            }
            break;
          }
          case "ItemIsMenu": {
            var new_is_menu = prop_value.get_boolean ();
            if (is_menu != new_is_menu) {
              is_menu = new_is_menu;
            }
            break;
          }
          case "Menu": {
            if (!prop_value.is_of_type (VariantType.OBJECT_PATH))break;

            var new_menu_path = (ObjectPath) prop_value.get_string ();
            if (new_menu_path != menu_path) {
              if (menu != null)
                menu.stop ();
              menu_path = new_menu_path;
              menu = menu_path != "/" && proxy.g_name_owner != null
                ? new TrayMenu (proxy.g_connection, proxy.g_name_owner, menu_path)
                : null;
            }
            break;
          }
          case "IconName": {
            var new_icon_name = prop_value.get_string ();
            if (IconName != new_icon_name) {
              IconName = new_icon_name;
              notify_property ("icon-name");
              update_gicon ();
            }
            break;
          }
          case "IconPixmap": {
            IconPixmap = Pixmap.array_from_variant (prop_value);
            update_gicon ();
            notify_property ("icon-pixbuf");
            break;
          }
          case "AttentionIconName": {
            var new_attention_icon_name = prop_value.get_string ();
            if (AttentionIconName != new_attention_icon_name) {
              AttentionIconName = new_attention_icon_name;
              update_gicon ();
              notify_property ("icon-name");
            }
            break;
          }
          case "AttentionIconPixmap": {
            AttentionIconPixmap = Pixmap.array_from_variant (prop_value);
            update_gicon ();
            notify_property ("icon-pixbuf");
            break;
          }
          case "OverlayIconName": {
            var new_overlay_icon_name = prop_value.get_string ();
            if (OverlayIconName != new_overlay_icon_name) {
              OverlayIconName = new_overlay_icon_name;
              update_gicon ();
              notify_property ("icon-name");
            }
            break;
          }
          case "OverlayIconPixmap": {
            OverlayIconPixmap = Pixmap.array_from_variant (prop_value);
            update_gicon ();
            notify_property ("icon-pixbuf");
            break;
          }
        }
      } catch (Error e) {
        // silently ignore
      }
    }

    private async void refresh_all_properties () {
      if (stopped || proxy == null || proxy.g_name_owner == null)
        return;
      string owner = proxy.g_name_owner;
      this.freeze_notify ();
      try {
        Variant parameters = yield proxy.g_connection.call (owner,
                                                            proxy.g_object_path,
                                                            "org.freedesktop.DBus.Properties",
                                                            "GetAll",
                                                            new Variant("(s)",
                                                                        proxy.g_interface_name),
                                                            new VariantType("(a{sv})"),
                                                            DBusCallFlags.NONE,
                                                            -1,
                                                            cancellable);
        if (stopped || proxy.g_name_owner != owner) {
          this.thaw_notify ();
          return;
        }

        VariantIter prop_iter;
        parameters.get ("(a{sv})", out prop_iter);

        string prop_key;
        Variant prop_value;

        while (prop_iter.next ("{sv}", out prop_key, out prop_value)) {
          set_dbus_property (prop_key, prop_value);
        }
      } catch (Error e) {
        if (!stopped && !(e is IOError.CANCELLED))
          warning ("Failed to refresh tray item: %s", e.message);
      }
      this.thaw_notify ();
      if (!stopped)
        this.changed ();
    }


    /**
     * Send an activate request to the tray app.
     */
    public void activate (int x, int y) {
      if (stopped || proxy == null)
        return;
      proxy.Activate.begin (x, y, (obj, result) => {
        try {
          proxy.Activate.end (result);
        } catch (Error error) {
          if (!stopped && !error.matches (DBusError.quark (), DBusError.UNKNOWN_METHOD))
            warning ("Failed to activate tray item: %s", error.message);
        }
      });
    }

    /**
     * Send a secondary activate request to the tray app.
     */
    public void secondary_activate (int x, int y) {
      if (stopped || proxy == null)
        return;
      proxy.SecondaryActivate.begin (x, y, (obj, result) => {
        try {
          proxy.SecondaryActivate.end (result);
        } catch (Error error) {
          if (!stopped && !error.matches (DBusError.quark (), DBusError.UNKNOWN_METHOD))
            warning ("Failed to secondary activate tray item: %s", error.message);
        }
      });
    }

    /**
     * Send a scroll request to the tray app.
     * valid values for the orientation are "horizontal" and "vertical".
     */
    public void scroll (int delta, string orientation) {
      if (stopped || proxy == null)
        return;
      proxy.Scroll.begin (delta, orientation, (obj, result) => {
        try {
          proxy.Scroll.end (result);
        } catch (Error error) {
          if (!stopped && !error.matches (DBusError.quark (), DBusError.UNKNOWN_METHOD))
            warning ("Failed to scroll tray item: %s", error.message);
        }
      });
    }

    private string ? find_icon_in_theme (string icon_name, string theme_path) {
      if ((icon_name == null) || (theme_path == null) || (icon_name == "") || (theme_path == "")) {
        return null;
      }

      var cache_key = icon_name + "\x00" + theme_path;
      if (icon_path_cache.has_key (cache_key))
        return icon_path_cache[cache_key];

      string ? result = null;

      try {
        Dir dir = Dir.open (theme_path, 0);
        string ? name = null;

        while ((name = dir.read_name ()) != null) {
          var path = Path.build_filename (theme_path, name);

          if (FileUtils.test (path, FileTest.IS_DIR)) {
            string ? icon = find_icon_in_theme (icon_name, path);
            if (icon != null) {
              result = icon;
              break;
            } else {
              continue;
            }
          }

          int dot_index = name.last_index_of (".");
          if (dot_index != -1) {
            name = name.substring (0, dot_index);
          }

          if (name == icon_name) {
            result = path;
            break;
          }
        }
      } catch (FileError err) {
        // leave result as null
      }

      icon_path_cache[cache_key] = result;
      return result;
    }

    private Gdk.Pixbuf ? _get_icon_pixbuf () {
      Pixmap[] pixmaps = (status == Status.NEEDS_ATTENTION)
            ? AttentionIconPixmap
            : IconPixmap;

      return pixmap_to_pixbuf (pixmaps);
    }

    private Gdk.Pixbuf ? pixmap_to_pixbuf (Pixmap[] pixmaps) {
      if ((pixmaps == null) || (pixmaps.length <= 0))return null;

      Pixmap pixmap = pixmaps[0];

      for (int i = 0; i < pixmaps.length; i++) {
        if (pixmap.width < pixmaps[i].width)pixmap = pixmaps[i];
      }

      uint8[] image_data = pixmap.bytes.copy ();

      for (int i = 0; i < pixmap.width * pixmap.height * 4; i += 4) {
        uint8 alpha = image_data[i];
        image_data[i] = image_data[i + 1];
        image_data[i + 1] = image_data[i + 2];
        image_data[i + 2] = image_data[i + 3];
        image_data[i + 3] = alpha;
      }

      return new Gdk.Pixbuf.from_bytes (
        new Bytes (image_data),
        Gdk.Colorspace.RGB,
        true,
        8,
        (int) pixmap.width,
        (int) pixmap.height,
        (int) (pixmap.width * 4)
      );
    }

    public string to_json_string () {
      var generator = new Json.Generator ();
      generator.set_root (to_json ());
      return generator.to_data (null);
    }

    internal Json.Node to_json () {
      return new Json.Builder ()
              .begin_object ()
              .set_member_name ("item_id").add_string_value (item_id)
              .set_member_name ("id").add_string_value (id)
              .set_member_name ("bus_name").add_string_value (proxy.g_name)
              .set_member_name ("object_path").add_string_value (proxy.g_object_path)
              .set_member_name ("title").add_string_value (title)
              .set_member_name ("status").add_string_value (status.to_nick ())
              .set_member_name ("category").add_string_value (category.to_nick ())
              .set_member_name ("tooltip").add_string_value (tooltip_markup)
              .set_member_name ("icon_theme_path").add_string_value (icon_theme_path)
              .set_member_name ("icon_name").add_string_value (icon_name)
              .set_member_name ("menu_path").add_string_value (menu_path)
              .set_member_name ("is_menu").add_boolean_value (is_menu)
              .end_object ()
              .get_root ();
    }
  }

  [DBus (name = "org.kde.StatusNotifierWatcher")]
  internal class StatusNotifierWatcher : Object {
    private HashMap<string, string> _items = new HashMap<string, string> ();
    private uint noc_signal_id;
    private DBusConnection bus;

    public string[] RegisteredStatusNotifierItems { owned get {
                                                      return _items.values.to_array ();
                                                    } }
    public bool IsStatusNotifierHostRegistered { get; default = true; }
    public int ProtocolVersion { get; default = 0; }

    public signal void StatusNotifierItemRegistered (string service);
    public signal void StatusNotifierItemUnregistered (string service);
    public signal void StatusNotifierHostRegistered ();
    public signal void StatusNotifierHostUnregistered ();

    construct {
      try {
        bus = Bus.get_sync (BusType.SESSION);
        noc_signal_id = bus.signal_subscribe (
          null,
          "org.freedesktop.DBus",
          "NameOwnerChanged",
          null,
          null,
          DBusSignalFlags.NONE,
          (connection, sender_name, path, interface_name, signal_name, parameters) => {
          string name = null;
          string new_owner = null;
          string old_owner = null;
          parameters.get ("(sss)", &name, &old_owner, &new_owner);
          if ((new_owner == "") && _items.has_key (name)) {
            string full_path = _items[name];
            _items.unset (name);
            StatusNotifierItemUnregistered (full_path);
          }
        });
      } catch (IOError e) {
        critical (e.message);
      }
    }

    public void RegisterStatusNotifierItem (string service, BusName sender) throws DBusError,
    IOError {
      string busName;
      string path;
      if (service[0] == '/') {
        path = service;
        busName = sender;
      } else {
        busName = service;
        path = "/StatusNotifierItem";
      }

      _items[busName] = busName + path;
      StatusNotifierItemRegistered (busName + path);
    }

    public void RegisterStatusNotifierHost (string service) throws DBusError, IOError {
      /* NOTE:
          usually the watcher should keep track of registered host
          but some tray applications do not register their trayitem properly
          when hosts register/deregister. This is fixed by setting isHostRegistered
          always to true, this also makes host handling logic unneccessary.
       */
    }

    ~StatusNotifierWatcher () {
      bus.signal_unsubscribe (noc_signal_id);
    }
  }

  [DBus (name = "org.kde.StatusNotifierWatcher")]
  internal interface IWatcher : Object {
    public abstract string[] RegisteredStatusNotifierItems { owned get; }
    public abstract int ProtocolVersion { get; }

    public abstract void RegisterStatusNotifierItem (string service,
                                                     BusName sender) throws DBusError, IOError;
    public abstract void RegisterStatusNotifierHost (string service) throws DBusError, IOError;

    public signal void StatusNotifierItemRegistered (string service);
    public signal void StatusNotifierItemUnregistered (string service);
    public signal void StatusNotifierHostRegistered ();
    public signal void StatusNotifierHostUnregistered ();
  }

  // ------------------------- Tray -------------------------
  public class TrayService : Object {
    private static TrayService ? instance = null;

    public static TrayService get_default () {
      if (instance == null)instance = new TrayService ();
      return instance;
    }

    private StatusNotifierWatcher watcher;
    private IWatcher proxy;

    private HashMap<string, TrayItem> _items = new HashMap<string, TrayItem> ();

    /**
     * List of currently registered tray items
     */
    public ArrayList<TrayItem> items { owned get {
                                         return new ArrayList<TrayItem>.wrap (
                                           _items.values.to_array ());
                                       } }

    private ListStore _items_store;

    /**
     * ListModel containing the currently registered tray items.
     */
    public ListModel items_model { get {
                                     return this._items_store;
                                   } }

    /**
     * emitted when a new tray item was added.
     */
    public signal void item_added (string item_id) {
      notify_property ("items");
    }

    /**
     * emitted when a tray item was removed.
     */
    public signal void item_removed (string item_id) {
      notify_property ("items");
    }

    construct {
      this._items_store = new ListStore (typeof (TrayItem));

      // Watch for new services appearing on the bus
      try {
        var conn = Bus.get_sync (BusType.SESSION);
        conn.signal_subscribe (
          "org.freedesktop.DBus",
          "org.freedesktop.DBus",
          "NameOwnerChanged",
          "/org/freedesktop/DBus",
          null,
          DBusSignalFlags.NONE,
          on_name_owner_changed
        );
      } catch (Error e) {
        warning ("Failed to subscribe to NameOwnerChanged: %s", e.message);
      }

      try {
        Bus.own_name (
          BusType.SESSION,
          "org.kde.StatusNotifierWatcher",
          BusNameOwnerFlags.NONE,
          start_watcher,
          start_host,
          () => {
          if (proxy != null) {
            proxy = null;
          }
        });
      } catch (Error err) {
        critical (err.message);
      }
    }

    private void start_watcher (DBusConnection conn) {
      try {
        watcher = new StatusNotifierWatcher ();
        conn.register_object ("/StatusNotifierWatcher", watcher);
        watcher.StatusNotifierItemRegistered.connect (on_item_register);
        watcher.StatusNotifierItemUnregistered.connect (on_item_unregister);
      } catch (Error err) {
        critical (err.message);
      }
    }

    private void start_host () {
      if (proxy != null)return;

      load_proxy.begin ((obj, res) => {
        load_proxy.end (res);
      });
    }

    private async void load_proxy () {
      try {
        proxy = yield Bus.get_proxy (BusType.SESSION,
                                     "org.kde.StatusNotifierWatcher",
                                     "/StatusNotifierWatcher");

        proxy.StatusNotifierItemRegistered.connect (on_item_register);
        proxy.StatusNotifierItemUnregistered.connect (on_item_unregister);

        proxy.notify["g-name-owner"].connect (() => {
          foreach (var entry in _items.entries) {
            entry.value.stop ();
            item_removed (entry.key);
          }

          _items.clear ();
          _items_store.remove_all ();

          if (proxy != null) {
            foreach (string item in proxy.RegisteredStatusNotifierItems) {
              on_item_register (item);
            }
          } else {
            foreach (string item in watcher.RegisteredStatusNotifierItems) {
              on_item_register (item);
            }
          }
        });

        foreach (string item in proxy.RegisteredStatusNotifierItems) {
          on_item_register (item);
        }
      } catch (Error err) {
        critical ("cannot get proxy: %s", err.message);
      }
    }

    private void on_name_owner_changed (DBusConnection connection,
                                        string ? sender_name,
                                        string object_path,
                                        string interface_name,
                                        string signal_name,
                                        Variant parameters) {
      string name, old_owner, new_owner;
      parameters.get ("(sss)", out name, out old_owner, out new_owner);

      // If a service just appeared (new owner, no old owner)
      if (new_owner != "" && old_owner == "") {
        // Give it time to initialize
        Timeout.add (1000, () => {
          check_and_notify_service.begin (connection, name, new_owner);
          return false;
        });
      }
    }

    private async void check_and_notify_service (DBusConnection conn, string name, string owner) {
      // Check if this service has StatusNotifierItem
      string[] paths = { "/StatusNotifierItem", "/org/ayatana/NotificationItem" };

      foreach (string path in paths) {
        try {
          yield conn.call (owner,
                           path,
                           "org.freedesktop.DBus.Properties",
                           "Get",
                           new Variant("(ss)", "org.kde.StatusNotifierItem", "Id"),
                           new VariantType("(v)"),
                           DBusCallFlags.NONE,
                           500,
                           null);

          // If we get here, the interface exists!
          // Send StatusNotifierHostRegistered signal to trigger re-registration
          conn.emit_signal (
            null,
            "/StatusNotifierWatcher",
            "org.kde.StatusNotifierWatcher",
            "StatusNotifierHostRegistered",
            null
          );

          return;
        } catch (Error e) {
          continue;
        }
      }
    }

    private void on_item_register (string service) {
      if (_items.has_key (service))return;

      var parts = service.split ("/", 2);
      TrayItem item = new TrayItem (parts[0], "/" + parts[1]);

      // Add to items immediately to prevent duplicate registration
      _items[service] = item;

      weak TrayService owner = this;
      weak TrayItem registered_item = item;
      ulong ready_handler = 0;
      ready_handler = item.ready.connect (() => {
        if (owner == null || registered_item == null)
          return;
        registered_item.disconnect (ready_handler);
        if (owner._items[service] != registered_item)
          return;
        owner._items_store.append (registered_item);
        owner.item_added (service);
      });
    }

    private void on_item_unregister (string service) {
      var item = _items[service];
      if (item == null)return;

      item.stop ();
      _items.unset (service);

      // Only try to remove from store if item exists in it
      uint pos;
      if (_items_store.find (item, out pos)) {
        _items_store.remove (pos);
      }

      item_removed (service);
    }

    /**
     * gets the TrayItem with the given item-id.
     */
    public TrayItem get_item (string item_id) {
      return _items[item_id];
    }
  }
}
