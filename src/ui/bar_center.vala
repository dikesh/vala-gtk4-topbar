using Gtk;

namespace Topbar {

  // --------------------- DateTime Service --------------------------
  private class DateTimeService : Object {

    private static DateTimeService ? instance = null;

    private bool show_utc = false;
    private string date;
    private string time;

    public signal void date_updated (string date);
    public signal void time_updated (string time);

    public string current_date { get {
                                   return date;
                                 } }
    public string current_time { get {
                                   return time;
                                 } }

    public static DateTimeService get_default () {
      if (instance == null)instance = new DateTimeService ();
      return instance;
    }

    private DateTimeService () {
      update ();

      Timeout.add_seconds (1, () => {
        update ();
        return true;
      });
    }

    private void update () {
      var curr_datetime = show_utc ? new DateTime.now_utc () : new DateTime.now_local ();

      // Time changes every tick
      time = curr_datetime.format ("%T");
      time_updated (time);

      // Date only changes at midnight
      var curr_date = curr_datetime.format ("%a %d %b %Y");

      if (date != curr_date) {
        date = curr_date;
        date_updated (date);
      }
    }

    public void toggle_show_utc () {
      show_utc = !show_utc;
    }
  }

  // --------------------- Time Widget --------------------------
  private class TimeWidget : Box {

    public TimeWidget () {
      Object (spacing: 8, tooltip_text: "Click to toggle between Local and UTC time");

      var dt_service = DateTimeService.get_default ();

      var time_button = new Button.with_label (dt_service.current_time);
      append (new Image.from_icon_name ("preferences-system-time-symbolic"));
      append (time_button);

      dt_service.time_updated.connect (time => time_button.set_label (time));
      time_button.clicked.connect (dt_service.toggle_show_utc);
    }
  }

  // --------------------- Date Widget --------------------------
  private class DateWidget : Box {

    private Popover calendar_popover;

    public DateWidget () {
      Object (spacing: 8, tooltip_text: "Click to show / hide calendar");

      // Add children
      var dt_service = DateTimeService.get_default ();

      var date_button = new Button.with_label (dt_service.current_date);
      append (new Image.from_icon_name ("x-office-calendar-symbolic"));
      append (date_button);

      // Update date button label
      dt_service.date_updated.connect (date => date_button.set_label (date));

      // Show / Hide Popover
      date_button.clicked.connect (() => {
        if (calendar_popover == null)set_calendar_popover ();
        calendar_popover.popup ();
      });
    }

    private void set_calendar_popover () {
      // Calendar
      var calendar = new Calendar () {
        height_request = 450, width_request = 450, css_classes = { "calendar-container" }
      };

      // Create popover
      calendar_popover = new Popover () {
        has_arrow = false, autohide = true, focusable = true
      };
      calendar_popover.set_child (calendar);
      calendar_popover.set_offset (-60, 30);
      calendar_popover.set_parent (this);

      // Destroy popover when hidden
      calendar_popover.hide.connect (() => {
        calendar_popover.unparent ();
        calendar_popover = null;
      });
    }
  }

  public class BarCenter : Box {

    public BarCenter () {
      // Init
      Object (spacing: 8);
      set_css_classes ({ "bar-section", "clock" });

      // Add Children
      append (new TimeWidget ());
      append (new DateWidget ());
    }
  }
}
