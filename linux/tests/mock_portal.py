#!/usr/bin/env python3
"""A stand-in xdg-desktop-portal, just real enough to exercise Boo's clients.

Implements org.freedesktop.portal.GlobalShortcuts and .RemoteDesktop on a real
session bus, following the genuine Request/Response protocol: a method returns a
Request object path, and the result arrives later as a Response signal on that
path.

The point: this mock *independently derives* the request path from the caller's
unique bus name and handle_token. Boo predicts the same path and subscribes to it
before calling. If Boo's prediction were wrong — the classic portal bug — it would
never see a Response and would hang forever. A passing run therefore proves the
prediction is right, which is exactly what cannot be checked on macOS.

Built on GDBus rather than dbus-python because both interfaces expose a method
named CreateSession, and dbus-python dispatches on the Python function name, so
one silently shadows the other. GDBus dispatches on (interface, method).

Emits one JSON line per observed event, for the test to assert on.
"""

import json
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

BUS_NAME = "org.freedesktop.portal.Desktop"
OBJ_PATH = "/org/freedesktop/portal/desktop"
IFACE_GS = "org.freedesktop.portal.GlobalShortcuts"
IFACE_RD = "org.freedesktop.portal.RemoteDesktop"
IFACE_SESSION = "org.freedesktop.portal.Session"
IFACE_CONTROL = "com.boo.MockControl"

NODE_XML = f"""
<node>
  <interface name='{IFACE_GS}'>
    <method name='CreateSession'>
      <arg type='a{{sv}}' name='options' direction='in'/>
      <arg type='o' name='handle' direction='out'/>
    </method>
    <method name='BindShortcuts'>
      <arg type='o' name='session_handle' direction='in'/>
      <arg type='a(sa{{sv}})' name='shortcuts' direction='in'/>
      <arg type='s' name='parent_window' direction='in'/>
      <arg type='a{{sv}}' name='options' direction='in'/>
      <arg type='o' name='handle' direction='out'/>
    </method>
    <method name='ListShortcuts'>
      <arg type='o' name='session_handle' direction='in'/>
      <arg type='a{{sv}}' name='options' direction='in'/>
      <arg type='o' name='handle' direction='out'/>
    </method>
    <signal name='Activated'>
      <arg type='o' name='session_handle'/>
      <arg type='s' name='shortcut_id'/>
      <arg type='a{{sv}}' name='options'/>
    </signal>
  </interface>
  <interface name='{IFACE_RD}'>
    <method name='CreateSession'>
      <arg type='a{{sv}}' name='options' direction='in'/>
      <arg type='o' name='handle' direction='out'/>
    </method>
    <method name='SelectDevices'>
      <arg type='o' name='session_handle' direction='in'/>
      <arg type='a{{sv}}' name='options' direction='in'/>
      <arg type='o' name='handle' direction='out'/>
    </method>
    <method name='Start'>
      <arg type='o' name='session_handle' direction='in'/>
      <arg type='s' name='parent_window' direction='in'/>
      <arg type='a{{sv}}' name='options' direction='in'/>
      <arg type='o' name='handle' direction='out'/>
    </method>
    <method name='NotifyKeyboardKeysym'>
      <arg type='o' name='session_handle' direction='in'/>
      <arg type='a{{sv}}' name='options' direction='in'/>
      <arg type='i' name='keysym' direction='in'/>
      <arg type='u' name='state' direction='in'/>
    </method>
  </interface>
  <interface name='{IFACE_SESSION}'>
    <method name='Close'/>
  </interface>
  <interface name='{IFACE_CONTROL}'>
    <method name='FireShortcut'>
      <arg type='s' name='shortcut_id' direction='in'/>
      <arg type='b' name='ok' direction='out'/>
    </method>
  </interface>
</node>
"""


def emit(event, **kw):
    print(json.dumps({"event": event, **kw}), flush=True)


def sanitize(sender):
    """':1.42' -> '1_42' — the spec's object-path component rule."""
    return sender.lstrip(":").replace(".", "_")


class MockPortal:
    def __init__(self, prebound=False):
        self.conn = None
        self.gs_session = None
        self.rd_session = None
        self.keysyms = []
        # Pretend a previous run already bound the shortcut. A real portal
        # remembers bindings per app, so this is what a second launch sees —
        # and Boo must then skip BindShortcuts, which is the call that raises
        # the approval dialog.
        self.prebound = prebound

    # -- Request/Response ------------------------------------------------

    def respond(self, sender, options, results):
        """Emit Response on the path the caller predicted, and return it."""
        token = options.get("handle_token", "unknown")
        path = f"{OBJ_PATH}/request/{sanitize(sender)}/{token}"

        def fire():
            emit("response", path=path)
            self.conn.emit_signal(
                sender,
                path,
                "org.freedesktop.portal.Request",
                "Response",
                GLib.Variant("(ua{sv})", (0, results)),
            )
            return False

        # After the method reply, matching a real portal's ordering.
        GLib.idle_add(fire)
        return path

    def session_path(self, sender, options):
        token = options.get("session_handle_token", "s")
        return f"{OBJ_PATH}/session/{sanitize(sender)}/{token}"

    # -- dispatch ---------------------------------------------------------

    def on_call(self, conn, sender, path, iface, method, params, invocation):
        args = params.unpack()

        if iface == IFACE_GS and method == "CreateSession":
            options = args[0]
            self.gs_session = self.session_path(sender, options)
            emit("gs.CreateSession", session=self.gs_session)
            handle = self.respond(
                sender, options, {"session_handle": GLib.Variant("s", self.gs_session)}
            )
            invocation.return_value(GLib.Variant("(o)", (handle,)))

        elif iface == IFACE_GS and method == "ListShortcuts":
            session, options = args
            shortcuts = []
            if self.prebound:
                shortcuts = [
                    (
                        "toggle-record",
                        {
                            "description": GLib.Variant("s", "Toggle Boo recording"),
                            "trigger_description": GLib.Variant("s", "Ctrl+Shift+Space"),
                        },
                    )
                ]
            emit("gs.ListShortcuts", prebound=self.prebound)
            handle = self.respond(
                sender,
                options,
                {
                    "shortcuts": GLib.Variant("a(sa{sv})", shortcuts),
                },
            )
            invocation.return_value(GLib.Variant("(o)", (handle,)))

        elif iface == IFACE_GS and method == "BindShortcuts":
            session, shortcuts, parent, options = args
            binds = [
                {
                    "id": sid,
                    "trigger": props.get("preferred_trigger", ""),
                    "description": props.get("description", ""),
                }
                for sid, props in shortcuts
            ]
            emit("gs.BindShortcuts", session=session, parent_window=parent, shortcuts=binds)
            handle = self.respond(sender, options, {})
            invocation.return_value(GLib.Variant("(o)", (handle,)))

        elif iface == IFACE_RD and method == "CreateSession":
            options = args[0]
            self.rd_session = self.session_path(sender, options)
            emit("rd.CreateSession", session=self.rd_session)
            handle = self.respond(
                sender, options, {"session_handle": GLib.Variant("s", self.rd_session)}
            )
            invocation.return_value(GLib.Variant("(o)", (handle,)))

        elif iface == IFACE_RD and method == "SelectDevices":
            session, options = args
            emit(
                "rd.SelectDevices",
                types=int(options.get("types", 0)),
                persist_mode=int(options.get("persist_mode", 0)),
                restore_token=options.get("restore_token", ""),
            )
            handle = self.respond(sender, options, {})
            invocation.return_value(GLib.Variant("(o)", (handle,)))

        elif iface == IFACE_RD and method == "Start":
            session, parent, options = args
            emit("rd.Start", session=session)
            # What a real portal returns once the user approves: a keyboard
            # grant plus a fresh restore token.
            handle = self.respond(
                sender,
                options,
                {
                    "devices": GLib.Variant("u", 1),  # KEYBOARD
                    "restore_token": GLib.Variant("s", "mock-restore-token"),
                },
            )
            invocation.return_value(GLib.Variant("(o)", (handle,)))

        elif iface == IFACE_RD and method == "NotifyKeyboardKeysym":
            session, options, keysym, state = args
            self.keysyms.append((keysym, state))
            emit("rd.NotifyKeyboardKeysym", keysym=keysym, state=state)
            invocation.return_value(None)

        elif iface == IFACE_SESSION and method == "Close":
            emit("session.Close", path=path)
            invocation.return_value(None)

        elif iface == IFACE_CONTROL and method == "FireShortcut":
            shortcut_id = args[0]
            if not self.gs_session:
                emit("control.FireShortcut", ok=False, reason="no gs session")
                invocation.return_value(GLib.Variant("(b)", (False,)))
                return
            emit("control.FireShortcut", ok=True, shortcut_id=shortcut_id)
            self.conn.emit_signal(
                None,
                OBJ_PATH,
                IFACE_GS,
                "Activated",
                GLib.Variant("(osa{sv})", (self.gs_session, shortcut_id, {})),
            )
            invocation.return_value(GLib.Variant("(b)", (True,)))

        else:
            invocation.return_dbus_error(
                "org.freedesktop.DBus.Error.UnknownMethod", f"{iface}.{method}"
            )

    def on_bus_acquired(self, conn, name):
        self.conn = conn
        info = Gio.DBusNodeInfo.new_for_xml(NODE_XML)
        for iface in info.interfaces:
            conn.register_object(OBJ_PATH, iface, self.on_call, None, None)
        emit("ready", bus_name=name)

    def on_name_lost(self, conn, name):
        emit("name_lost", bus_name=name)
        sys.exit(1)


def main():
    # --prebound simulates a second launch, where the portal already remembers
    # our shortcut from a previous session.
    portal = MockPortal(prebound="--prebound" in sys.argv)
    Gio.bus_own_name(
        Gio.BusType.SESSION,
        BUS_NAME,
        Gio.BusNameOwnerFlags.NONE,
        portal.on_bus_acquired,
        None,
        portal.on_name_lost,
    )
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
