"""Nautilus extension for safeai (optional).

Right click a file or folder: "AI agent: open / read-only / close", under a greyed line saying
what it is now ("Now: open, something closed inside").
Emblems show what the agent can do with that very item: red - closed, blue eye - read only,
no emblem - it reads and writes. A two-color emblem reads left to right: the left half is the
folder itself, the right half something inside it. Red | green: a closed folder where the agent
reaches only what you opened inside. Green | red: an open folder with something you closed
inside (at any depth); blue | red: the same in a read-only folder. .env files that safeai closes
by itself do not count: there is one in almost every project, with its own red emblem. Turn
emblems off in `safeai settings`.
Actions call the `safeai` command. Installed into
~/.local/share/nautilus-python/extensions/ (needs the nautilus-python package).
"""
import os
import re
import pwd
import shutil
import struct

from gi.repository import Gio, GObject, Nautilus

HOME = os.path.expanduser("~")
SAFEAI = shutil.which("safeai") or "/usr/local/bin/safeai"
CONF = f"{HOME}/.config/safeai"
LISTS = {"closed": f"{CONF}/closed", "read": f"{CONF}/read-only", "work": f"{CONF}/write-dirs"}
EMBLEMS = {"none": "safeai-closed", "read": "safeai-readonly", "pass": "safeai-partly",
           "full+closed": "safeai-open-closed", "read+closed": "safeai-read-closed"}
if not os.path.exists(f"{HOME}/.local/share/icons/hicolor/scalable/emblems/safeai-open-closed.svg"):
    EMBLEMS = {"none": "emblem-unreadable", "read": "view-reveal-symbolic", "pass": "emblem-important",
               "full+closed": "emblem-important", "read+closed": "emblem-important"}
SAMPLES = ("example", "sample", "template", "dist", "default", "defaults")
PROFILE = os.path.exists("/etc/apparmor.d/safeai-agent")


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
    """none / pass / read / full: what the agent can do with path itself, from the permissions
    (with the search right on every parent) and the AppArmor profile, which refuses .env-like
    names whatever the permissions (the same names as bin/safeai profile_refuses)."""
    if AGENT_UID is None:
        return "full"
    d = os.path.dirname(path)
    while True:
        if not agent_bits(d) & 1:
            return "none"
        if d == "/":
            break
        d = os.path.dirname(d)
    n = os.path.basename(path)
    if PROFILE and (n.endswith(".env") or (n.startswith(".env.") and len(n) > 5 and n[5:] not in SAMPLES)):
        return "none"
    bits = agent_bits(path)
    if bits & 2 and (bits & 1 or not os.path.isdir(path)):
        return "full"  # it can change it, whether it can read it or not
    if os.path.isdir(path):
        if not bits & 1:
            return "none"
        if not bits & 4:
            return "pass"  # it can go through to what is open inside, not list it
    elif not bits & 4:
        return "none"
    return "full" if bits & 2 else "read"


# .env-like names safeai closes by itself (the same as bin/safeai is_env)
ENV_NAME = re.compile(r"^(\.env(\..+)?|.+\.env)$")
ENV_SAMPLE = re.compile(r"[.-](example|sample|template|dist|defaults?)(\.env)?$", re.I)
_closed = {"mtime": None, "dirs": {}}


def is_env(p):
    n = os.path.basename(p)
    return bool(ENV_NAME.match(n)) and not ENV_SAMPLE.search(n)


def closed_inside(path):
    """Whether a rule of yours in the closed list closes something inside folder path, at any depth.
    The list is read again when it changes; .env files are left out (safeai closes them by itself,
    there is one in almost every project), and so are rules for paths that are gone."""
    try:
        mtime = os.stat(LISTS["closed"]).st_mtime_ns
    except OSError:
        return False
    if mtime != _closed["mtime"]:
        dirs = {}
        try:
            with open(LISTS["closed"]) as f:
                for line in f:
                    q = line.strip().rstrip("/")
                    if not q.startswith(HOME + "/") or is_env(q):
                        continue
                    d = os.path.dirname(q)
                    while d.startswith(HOME + "/"):
                        dirs.setdefault(d, []).append(q)
                        d = os.path.dirname(d)
        except OSError:
            pass
        _closed.update(mtime=mtime, dirs=dirs)
    return any(os.path.lexists(q) for q in _closed["dirs"].get(path, ()))


def emblem_of(path):
    """The emblem for path (a key of EMBLEMS), or None for open with nothing closed inside."""
    acc = agent_access(path)
    if acc in ("full", "read") and os.path.isdir(path) and closed_inside(path):
        return f"{acc}+closed"
    return None if acc == "full" else acc


NOW = {None: "open", "read": "read-only", "none": "closed", "pass": "closed, something open inside",
       "full+closed": "open, something closed inside", "read+closed": "read-only, something closed inside"}


def status_of(path):
    """The greyed line above the actions: what the agent can do with path now, as its emblem says."""
    return f"Now: {NOW[emblem_of(path)]}"


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
        # a rule set from the terminal changes a folder's emblem without touching the folder itself:
        # the folders shown are refreshed when your lists change
        self.shown = {}
        try:
            self.monitor = Gio.File.new_for_path(CONF).monitor_directory(Gio.FileMonitorFlags.NONE, None)
            self.monitor.connect("changed", self.rules_changed)
        except Exception:  # no lists yet: emblems refresh as Files shows the folders again
            self.monitor = None

    def rules_changed(self, _monitor, f, _other, _event):
        if f.get_basename() in ("closed", "read-only", "write-dirs"):
            for info in list(self.shown.values()):
                info.invalidate_extension_info()

    def update_file_info(self, info):
        p = home_path(info) if self.emblems else None
        if p:
            e = emblem_of(p)
            if e:
                info.add_emblem(EMBLEMS[e])
            if info.is_directory():
                self.shown.pop(p, None)
                self.shown[p] = info
                if len(self.shown) > 5000:
                    self.shown.pop(next(iter(self.shown)))
        return Nautilus.OperationResult.COMPLETE

    def get_file_items(self, files):
        paths = [home_path(f) for f in files]
        if not paths or None in paths:
            return []
        modes = listed()
        cur = [modes.get(p) for p in paths]
        # an action on a folder covers everything in it, your rules inside included: worth offering
        # even when the folder itself already has that state (.env files are not rules of yours)
        inner = any(q.startswith(p + "/") and not is_env(q) for p in paths for q in modes)
        folder = any(os.path.isdir(p) for p in paths)
        everything = " everything in it" if folder else ""
        items = []
        now = {status_of(p) for p in paths} if AGENT_UID is not None else set()
        if len(now) == 1:  # none for a selection of items that differ
            items.append(Nautilus.MenuItem(name="SafeAI::now", label=now.pop(), sensitive=False))
        if inner or any(m != "work" for m in cur):
            items.append(self.item("open", "AI agent: open", f"The agent may read and write{everything}", files, paths))
        if inner or any(m != "read" for m in cur):
            items.append(self.item("read", "AI agent: read-only", f"The agent reads{everything}, cannot change it",
                                   files, paths))
        if inner or any(m != "closed" for m in cur):
            items.append(self.item("close", "AI agent: close", f"The agent can neither read nor enter{everything}",
                                   files, paths))
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
