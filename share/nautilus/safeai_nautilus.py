"""Nautilus extension for safeai (optional).

Right click a file or folder: "AI agent: open / read-only / close".
Emblems show what the agent can really do: a cross - no access, an eye - read only
(turn them off in `safeai settings`).
Actions call the `safeai` command. Installed into
~/.local/share/nautilus-python/extensions/ (needs the nautilus-python package).
"""
import os
import pwd
import shutil
import struct

from gi.repository import Gio, GObject, Nautilus

HOME = os.path.expanduser("~")
SAFEAI = shutil.which("safeai") or "/usr/local/bin/safeai"
CONF = f"{HOME}/.config/safeai"
LISTS = {"closed": f"{CONF}/closed", "read": f"{CONF}/read-only", "work": f"{CONF}/write-dirs"}
EMBLEMS = {"none": "emblem-unreadable", "read": "view-reveal-symbolic"}


def _agent():
    try:
        with open("/etc/safeai.conf") as f:
            for line in f:
                k, _, v = line.strip().partition("=")
                if k == "AGENT" and v:
                    return v
    except OSError:
        pass
    return "aiagent"


try:
    _a = pwd.getpwnam(_agent())
    AGENT_UID, AGENT_GID = _a.pw_uid, _a.pw_gid
except KeyError:
    AGENT_UID = AGENT_GID = None
_cache = {}


def agent_bits(path):
    """The agent's rwx bits (4/2/1) on path itself, from mode and POSIX ACL."""
    try:
        st = os.stat(path)
    except OSError:
        return 0
    key = (path, st.st_ctime_ns)  # ctime changes with permissions
    if key in _cache:
        return _cache[key]
    try:
        raw = os.getxattr(path, "system.posix_acl_access")
    except OSError:
        raw = b""
    user = mask = None
    groups, other = [], st.st_mode & 7
    if len(raw) >= 4:
        for tag, perm, uid in struct.iter_unpack("<HHI", raw[4:]):
            if tag == 0x02 and uid == AGENT_UID:
                user = perm
            elif (tag == 0x04 and st.st_gid == AGENT_GID) or (tag == 0x08 and uid == AGENT_GID):
                groups.append(perm)
            elif tag == 0x10:
                mask = perm
            elif tag == 0x20:
                other = perm
    elif st.st_gid == AGENT_GID:
        groups.append((st.st_mode >> 3) & 7)
    if st.st_uid == AGENT_UID:
        bits = (st.st_mode >> 6) & 7
    elif user is not None:
        bits = user & (7 if mask is None else mask)
    elif groups:
        bits = 0
        for g in groups:
            bits |= g
        bits &= 7 if mask is None else mask
    else:
        bits = other
    if len(_cache) > 20000:
        _cache.clear()
    _cache[key] = bits
    return bits


def agent_access(path):
    """none / read / full, walking the search (x) right on every parent."""
    if AGENT_UID is None:
        return "full"
    d = os.path.dirname(path)
    while True:
        if not agent_bits(d) & 1:
            return "none"
        if d == "/":
            break
        d = os.path.dirname(d)
    bits = agent_bits(path)
    if not bits & 4 or (os.path.isdir(path) and not bits & 1):
        return "none"
    return "full" if bits & 2 else "read"


def listed():
    out = {}
    for kind, f in LISTS.items():
        try:
            with open(f) as fh:
                out.update({l.strip().rstrip("/"): kind for l in fh if l.strip() and not l.startswith("#")})
        except OSError:
            pass
    return out


def home_path(info):
    if info.get_uri_scheme() != "file" or not info.get_location():
        return None
    p = info.get_location().get_path()
    p = os.path.realpath(p) if p else None
    return p if p and p.startswith(HOME + "/") and not p.startswith(CONF) else None


def emblems_on():
    try:
        with open(f"{CONF}/emblems") as f:
            return f.read().strip() != "off"
    except OSError:
        return True


def notify_on():
    """safeai settings can turn the notifications off; read at every action."""
    try:
        with open(f"{CONF}/notifications") as f:
            return f.read().strip() != "off"
    except OSError:
        return True


class SafeAIExtension(GObject.GObject, Nautilus.MenuProvider, Nautilus.InfoProvider):
    def __init__(self):
        super().__init__()
        self.emblems = emblems_on()  # read once; changing it in safeai settings restarts Files

    def update_file_info(self, info):
        p = home_path(info) if self.emblems else None
        if p:
            acc = agent_access(p)
            if acc != "full":
                info.add_emblem(EMBLEMS[acc])
        return Nautilus.OperationResult.COMPLETE

    def get_file_items(self, files):
        paths = [home_path(f) for f in files]
        if not paths or None in paths:
            return []
        modes = listed()
        cur = [modes.get(p) for p in paths]
        items = []
        # offer what changes something for at least one of the selected paths
        if any(m != "work" for m in cur):
            items.append(self.item("open", "AI agent: open", "The agent may read and write", files, paths))
        if any(m != "read" for m in cur):
            items.append(self.item("read", "AI agent: read-only", "The agent reads but cannot change", files, paths))
        if any(m != "closed" for m in cur):
            items.append(self.item("close", "AI agent: close", "The agent can neither read nor enter", files, paths))
        return items

    def item(self, action, label, tip, files, paths):
        mi = Nautilus.MenuItem(name=f"SafeAI::{action}", label=label, tip=tip)
        mi.connect("activate", self.run, action, files, paths)
        return mi

    def run(self, _item, action, files, paths):
        # Gio.Subprocess in Nautilus' main loop; Python threads stall inside Nautilus
        argv = [SAFEAI, action, *paths]
        proc = Gio.Subprocess.new(argv, Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE)

        def done(proc, result):
            _ok, out, err = proc.communicate_utf8_finish(result)
            # success shows in the emblems; a notification only when something needs your attention
            if notify_on() and (not proc.get_successful() or "Warning" in (out or "")):
                text = ((out or "") + (err or "")).strip() or "failed"
                Gio.Subprocess.new(["notify-send", "-a", "safeai", "safeai", text[-300:]], Gio.SubprocessFlags.NONE)
            for f in files:
                f.invalidate_extension_info()

        proc.communicate_utf8_async(None, None, done)
