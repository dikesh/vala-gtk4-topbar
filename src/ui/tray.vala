using Gee;
using Gtk;

namespace Topbar {
  /**
   * A single tray item button widget
   */
  public class TrayItemWidget : Box {
    private Button button;
    private TrayItem _item;
    private Image image;
    private bool item_connected;
    private PopoverMenu? popover;
    private TrayMenu? open_menu;
    private uint menu_request;
    private Gtk.Window? keyboard_window;
    private GtkLayerShell.KeyboardMode previous_keyboard_mode;
    // One active popup across all bars, including menus still being prepared.
    private static weak TrayItemWidget? active_popup;

    public TrayItem item {
      get {
        return _item;
      }
      set {
        if (_item == value)return;

        dismiss_menu ();
        disconnect_item ();
        _item = value;

        if (_item != null) {
          if (get_root () != null)
            connect_item ();
          update_widget ();
        }
      }
    }

    construct {
      orientation = Orientation.HORIZONTAL;

      image = new Image ();

      button = new Button ();
      button.add_css_class ("tray-item");
      button.set_cursor_from_name ("pointer");
      button.clicked.connect (on_left_click);
      button.set_child (image);

      var context_click = new GestureClick ();
      context_click.set_button (Gdk.BUTTON_SECONDARY);
      context_click.set_propagation_phase (PropagationPhase.CAPTURE);
      context_click.pressed.connect ((gesture, n_press, x, y) => {
        gesture.set_state (EventSequenceState.CLAIMED);
        show_menu ((int) x, (int) y);
      });
      button.add_controller (context_click);

      var keys = new EventControllerKey ();
      keys.key_pressed.connect ((keyval, keycode, state) => {
        if (keyval == Gdk.Key.Menu ||
            (keyval == Gdk.Key.F10 && (state & Gdk.ModifierType.SHIFT_MASK) != 0)) {
          show_menu (0, 0);
          return true;
        }
        return false;
      });
      button.add_controller (keys);

      append (button);
      notify["root"].connect (() => {
        if (get_root () != null)
          connect_item ();
      });
    }

    public TrayItemWidget (TrayItem item) {
      Object ();
      this.item = item;
    }


    public override void unroot () {
      dismiss_menu ();
      disconnect_item ();
      base.unroot ();
    }

    private void connect_item () {
      if (item_connected || _item == null)
        return;
      _item.changed.connect (on_item_changed);
      _item.notify["menu"].connect (on_menu_changed);
      item_connected = true;
    }

    private void disconnect_item () {
      if (!item_connected)
        return;
      _item.changed.disconnect (on_item_changed);
      _item.notify["menu"].disconnect (on_menu_changed);
      item_connected = false;
    }

    private void on_menu_changed () {
      dismiss_menu ();
    }

    private void show_menu (int x, int y) {
      if (_item == null || get_root () == null)
        return;

      // Toggle the same item, or close a menu on another monitor first.
      if (active_popup == this) {
        dismiss_menu ();
        return;
      }
      if (active_popup != null)
        active_popup.dismiss_menu ();

      var menu = _item.menu;
      if (menu == null) {
        _item.show_context_menu.begin (x, y);
        return;
      }

      active_popup = this;
      open_menu = menu;
      uint request = ++menu_request;
      menu.prepare.begin ((obj, result) => {
        try {
          menu.prepare.end (result);
        } catch (Error error) {
          if (request == menu_request) {
            warning ("Unable to open tray menu: %s", error.message);
            dismiss_menu ();
          }
          return;
        }

        // A removal, replacement, dismissal, or newer request owns cleanup.
        if (request != menu_request || open_menu != menu || get_root () == null)
          return;

        popover = new PopoverMenu.from_model_full (menu.menu_model, PopoverMenuFlags.NESTED);
        popover.add_css_class ("traymenu");
        popover.set_cursor_from_name ("default");
        popover.insert_action_group ("dbusmenu", menu.action_group);
        popover.set_has_arrow (false);
        popover.set_position (PositionType.BOTTOM);
        popover.set_offset (0, 12);
        popover.set_parent (button);
        popover.closed.connect (on_popover_closed);
        enable_menu_keyboard ();
        popover.popup ();
        popover.grab_focus ();
      });
    }

    private void enable_menu_keyboard () {
      var window = get_root () as Gtk.Window;
      if (window == null || !GtkLayerShell.is_layer_window (window))
        return;
      keyboard_window = window;
      previous_keyboard_mode = GtkLayerShell.get_keyboard_mode (window);
      GtkLayerShell.set_keyboard_mode (window, GtkLayerShell.KeyboardMode.ON_DEMAND);
    }

    private void on_popover_closed () {
      // GtkModelButton closes its popover before activating its action.
      // Keep the action group and backend alive until that dispatch finishes.
      var closed_popover = popover;
      Idle.add_once (() => {
        if (popover == closed_popover)
          dismiss_menu ();
      });
    }

    private void dismiss_menu () {
      ++menu_request;
      if (active_popup == this)
        active_popup = null;

      var old_popover = popover;
      popover = null;
      if (old_popover != null) {
        old_popover.closed.disconnect (on_popover_closed);
        old_popover.popdown ();
        old_popover.insert_action_group ("dbusmenu", null);
        old_popover.unparent ();
      }

      if (keyboard_window != null) {
        GtkLayerShell.set_keyboard_mode (keyboard_window, previous_keyboard_mode);
        keyboard_window = null;
      }

      var menu = open_menu;
      open_menu = null;
      if (menu != null)
        menu.close ();
    }

    private void update_widget () {
      image.set_from_gicon (_item.gicon);
    }

    private void on_item_changed () {
      update_widget ();
    }

    private void on_left_click () {
      if (_item.is_menu)
        show_menu (0, 0);
      else
        _item.activate (0, 0);
    }
  }

  /**
   * Main system tray widget containing all tray items
   */
  public class SystemTray : Box {
    private TrayService tray;
    private HashMap<string, TrayItemWidget> widgets;
    private Revealer revealer;
    private Box box;

    public Orientation tray_orientation {
      get {
        return box.orientation;
      }
      set {
        box.orientation = value;
      }
    }

    public int widget_spacing {
      get {
        return box.spacing;
      }
      set {
        box.spacing = value;
      }
    }

    construct {
      widgets = new HashMap<string, TrayItemWidget>();
      tray = TrayService.get_default ();

      visible = false;

      box = new Box (Orientation.HORIZONTAL, 4);
      box.set_css_classes ({ "bar-section", "systray" });

      revealer = new Revealer ();
      revealer.transition_type = RevealerTransitionType.SLIDE_RIGHT;
      revealer.transition_duration = 300;
      revealer.reveal_child = false;
      revealer.set_child (box);

      append (revealer);

      // Connect to tray signals
      tray.item_added.connect (on_item_added);
      tray.item_removed.connect (on_item_removed);

      // Add existing items
      foreach (var item in tray.items) {
        add_tray_item (item);
      }
    }

    private void update_visibility () {
      bool has_items = widgets.size > 0;
      visible = has_items;
      revealer.reveal_child = has_items;
    }

    private void on_item_added (string item_id) {
      var item = tray.get_item (item_id);
      if (item != null) {
        add_tray_item (item);
      }
    }

    private void on_item_removed (string item_id) {
      var widget = widgets.get (item_id);
      if (widget != null) {
        box.remove (widget);
        widget = null;
        widgets.unset (item_id);
        update_visibility ();
      }
    }

    private void add_tray_item (TrayItem item) {
      if (widgets.has_key (item.item_id))return;

      var widget = new TrayItemWidget (item);
      widgets.set (item.item_id, widget);
      box.append (widget);
      update_visibility ();
    }
  }
}
