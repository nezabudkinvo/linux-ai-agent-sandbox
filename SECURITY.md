# Security model

## Threat

An AI agent works on your machine with most of your abilities. It is not
malicious, but it can be steered by text it reads (prompt injection) and it
sends what it reads to a model. safeai aims to:

1. keep chosen files unreadable to the agent, whatever program it uses;
2. keep code that runs as you (git hooks, editor and agent configs, your
   scripts) out of the agent's reach;
3. stay convenient: the agent works in your real project folders.

Out of scope: root, physical access, and code the agent wrote or changed that
you then run yourself (a test, a build script, a dependency in your project):
safeai protects your personal files, your secrets and the places that run code as
you automatically, not the project code you choose to run.

## Layers

| Layer | Holds | Relies on |
|---|---|---|
| Separate user | your session (D-Bus, Wayland, ssh-agent), your processes, sudo | uid; the only sudo rule is you -> agent |
| ACLs | closed / read-only / open paths; executable places read-only | POSIX ACL entries for the agent user, default ACLs in open folders |
| Guard service | new `.env` closed and a new repo's whole `.git` (and `.vscode`, ...) made read-only at creation; agent files handed to you | root fanotify service |
| AppArmor (optional) | `.env`-like names refused at open time, no mount | profile on every agent process: login shell, editor launcher, its `systemd --user`; cron/at denied |
| Audit (optional) | a record of refused actions | kernel audit rules for the agent's uid |
| Launchers | the agent starts only as the agent, only while the guard (and the profile, if installed) are up | `safeai`, `safeai-run`; VS Code settings point at `safeai-run` |
| Questions (`safeai ask`) | the agent asks you on screen; you decide | a root-owned socket only the agent's group can reach, answered by a service running as you |

ACLs are the base: they follow the file (inode), not the path, and cover every
process of the agent user. AppArmor is path-based and is a second layer for the
moment before ACLs catch up.

## Invariants

- The agent user is in no group of yours and has no sudo rule.
- safeai itself, its lists (`~/.config/safeai`, mode 700) and installed files
  are not writable by the agent.
- Anything run as you is read-only to the agent: a repository's whole `.git`
  (its `config`, `hooks`, `modules`, `worktrees`), `.vscode`, `.envrc`,
  `.claude`, `.codex`, `.mcp.json`, `*.desktop`. The `.git` directory itself is
  read-only, not only the files inside it, so the agent cannot replace them by
  renaming them aside. The agent therefore cannot commit in your repositories,
  only read them; in a repository the agent created itself (its own `.git`) it
  has full control, and you should not run git there.
- safeai never runs your git (or other tools) inside a folder the agent can
  write: file ownership is not enough there, the agent can rename its own
  content into place. Git operations for checks run as the agent.
- Owner-private files (no read for "others") are not opened to the agent
  unless you list them.
- The rule on the nearest path decides. An action on a folder replaces every rule
  of the owner's inside it; secret stores, `.env` files, owner-private files and
  places that run code as the owner keep their protection, which is not a rule.
- A folder that is closed but holds something allowed is partly open: enter-only
  (it cannot be listed, nothing can be added to or removed from it), everything
  else in it closed; it closes again when nothing inside is allowed any more.
- The emblems in Files are computed from what the agent can actually do with each
  item (permissions on it and on every folder above it, and the AppArmor names),
  not from the owner's rules. The one exception is the right half of a two-color
  emblem on an open or read-only folder: it says that a rule of yours closes
  something inside (.env files closed by safeai itself are not counted).
- Nothing that fails while deciding who runs a chat makes it run as you: a
  chat runs as you only when you said so (the status bar switch) or when it
  continues a chat you started as yourself, and never next to Claude Code or Codex
  settings the agent made.

## Modes

- `strict`: the home folder is enter-only for the agent (it cannot list it) and
  every entry in it is closed. A folder on the way to one you opened is
  enter-only too, with everything else in it closed. New entries directly in
  your home are closed by the guard as they appear; new entries next to an
  opened folder, by the periodic check (within 5 minutes).
- `relaxed`: visible folders are open; hidden entries keep their own
  permissions (the agent cannot change them).

Both modes close the same secret stores and keep executable places read-only. A
store that appears after the install (a new `~/.aws`, `~/.config/gh`) is closed by
the guard as it appears, and the periodic check adds it to the closed list.

## VS Code

- The VS Code setting switches only the AI processes (Claude Code's `claude`, the
  Codex extension's `codex`). The rest of the window runs as you: its terminal,
  tasks, debugger, notebooks and other extensions. A test or script the agent
  changed runs as you when you start it there.
- Tools of the editor itself: the Claude Code extension gives a chat a tool that
  reads VS Code's diagnostics (errors and warnings of the files you have open),
  run by the extension as you; an agent chat sees those messages, including for
  a file that is closed to it but open in your editor. Version 2.1.285 of the
  extension also contains notebook and debugger tools that would run as you; they
  are switched off in it. The editor's own server for terminal `claude` (with code
  execution in Jupyter) needs a key in your `~/.claude/ide`, which the agent
  cannot read. Check this again after extension updates, and do not turn on
  notebook or debugger tools in agent chats.
- The status bar switch, per window, makes what starts there (a chat, a window's
  Codex) run as you, until you switch back; what runs keeps whoever started it.
  Such a chat does not start next to Claude Code or Codex settings the agent made
  before it starts (hooks, MCP servers: they would run as you). But a chat as you
  in a folder the agent can write is only as safe as that folder: the agent can add
  such settings *during* the chat (a running Claude or Codex may pick them up), and
  the chat reads what the agent wrote as it would any file. The chat is told to
  treat the agent's files and web content as data, not instructions, which lowers
  the risk but does not remove it. **For work as yourself - fixing the system,
  changing safeai, editing your own rules for agents - use a folder the agent
  cannot write (keep it closed or read-only to it), not one you also give the
  agent.** Read the agent's results as untrusted.
- Codex runs one process per VS Code window, so for Codex the choice is per
  window, made when the window starts; Claude Code chooses per chat.
- The agent's chats are copied, read-only, into your `~/.claude/projects` so that
  VS Code lists them; VS Code continues them as the agent. Your own terminal
  `claude --resume` would continue such a copy as you, with the agent's text in
  it: continue agent chats in VS Code or with `safeai claude --resume`.

## Questions from the agent

`safeai ask read|open PATH [WHY]` shows you the agent's question on screen. It is
your decision, not a check: allowing gives the agent exactly what `safeai read` or
`safeai open` would. What keeps it honest:

- only places the agent cannot rearrange are offered: none of the folders on the
  way to it may be writable by the agent (otherwise it could move another item
  into that name between your answer and the change). For an item inside its own
  open project, the agent asks in the chat and you decide in a terminal;
- the path is resolved once and shown resolved; the change is made only if the same
  file or folder is still there, with no link on the way;
- secrets (and folders that hold secret stores) and `.git` are never offered on
  screen; neither is changing settings, hidden folders or program folders
  (`~/bin`, conda, ...);
- one question at a time; after a no (or no answer) the same path is not asked
  again for 10 minutes; at most 10 questions in 10 minutes;
- the agent's reason and the path are shown as plain text, cut short, without
  control, direction-changing or line-separator characters; with kdialog, "No" is
  preselected. The reason is the agent's own words.

## Installer

- Shows the full plan and changes nothing until you agree (`--plan` only prints it).
- Refuses to run from a folder the agent can write to, and refuses to reuse an
  existing user it did not create.
- Records everything in `/var/lib/safeai/manifest`, backs up every existing file
  it modifies, reverts on any failed step; `uninstall.sh` reverts the manifest
  and asks before deleting the agent user and the packages.
- The sudo rule is checked with `visudo` before it is installed.

## Updates

`safeai settings update` works like a package manager's upgrade:

- It installs only a git tag `vX.Y.Z` newer than the running version, and only if
  the tag verifies against the release key that was installed with safeai
  (`/usr/local/lib/safeai/allowed_signers`, root-owned). The key in the download
  is never used, so a change pushed to the repository, or a compromised hosting
  account, cannot produce an update your machine accepts; only the holder of the
  signing key can.
- The tag's `VERSION` must match its name; older or equal versions are refused.
- The download goes to a private temporary folder (mode 700); the signer and the
  list of changes are shown, and nothing runs with sudo before you say yes.
- There are no automatic or background updates.
- If the release key ever changes, updates stop with a clear message; install
  the new version by hand after checking it.

## Known limits

- Without AppArmor, an agent process watching a folder can race the guard: open
  a new `.env` before it is closed (the guard kills such processes) or rename it
  away first. With the profile, both are refused.
- A new repository's `.git` is made read-only to the agent by the guard right
  after it appears (git init, git clone). AppArmor does not cover it, so an agent
  racing the guard in those first milliseconds is not stopped; `safeai check`
  re-asserts it and quarantines anything the agent planted there.
- Without AppArmor, the agent can rename your repository's `.git` directory aside
  (that rename is a property of the work folder, which is open) and drop its own
  `.git` in its place. A `.git` *file* (a gitdir pointer) is quarantined by
  `safeai check`; a whole agent-owned `.git` *directory* leaves the repository
  visibly broken (your `git` reports "not a repository"). With the AppArmor
  profile the agent can neither rename nor create a `.git` anywhere in your home,
  so its own repositories live in its own home.
- Configuration the agent authors in an open folder (a `.vscode`, `.claude`,
  `.codex`, `.mcp.json`, `.envrc` or `*.desktop` it creates) is quarantined by
  `safeai check` (moved to `~/.local/share/safeai-quarantine`; `safeai status`
  counts what is there), so your editor or tools never load agent-controlled settings.
  Inside the agent's own repositories (marked by `safeai ls`) they stay: they are
  that project's files, and you should not run your tools there.
  Between the moment the agent creates it and the next check (at most 5 minutes)
  it exists; loading it still takes an owner action that runs it (for example a
  VS Code task, which needs a trusted workspace).
- A read-only folder goes by the files' own permissions: the agent reads what
  every user of the computer may read, and nothing is written on each file, so a
  conda install or a big data folder stays fast to open, close and uninstall.
  Explicit read-only entries are set on the folder you listed, on what anyone may
  write, on an ACL entry for the agent's group, on the agent's own files and on
  places that run code as you. Something that becomes writable by anyone later
  (a `chmod 777`, a program with umask 000) is writable to the agent until the
  next `safeai check` (at most 5 minutes) sets its entry.
  A default ACL that gives the agent's group write, added to such a folder later,
  is countered at the next `safeai read` or `safeai setup`, not by that check.
- A default ACL you set on a folder that equals the folder's own permissions
  (rwx/r-x/r-x on a 755 folder) can go when safeai takes its own entries off
  (closing, then making read-only; uninstall): safeai cannot tell it from the one
  setfacl builds for safeai's entry. A default that differs (say `other::---`) stays.
- In a VS Code window switched to "me", a continued chat whose owner safeai does
  not know (no transcript yet, its record gone) runs as you, as a new chat there
  would; a chat with a transcript always continues as whoever started it.
- One owner per computer. safeai keeps the agent out of the files of the person
  who installed it; other accounts on the machine get no protection from it (the
  agent sees their files as any user does), and a second person cannot install it
  while it is installed.
- A file's mode marks it private only when your umask leaves new files readable to
  others (022, 002): then a 600 file stands out and stays closed. With a umask like
  077 every file is 600, so safeai goes by names (secret stores, `.env`) and your
  rules: a secret under another name in an open or read-only folder is open to
  the agent until you close it. The installer records your umask; after you change
  it, run `sudo ./install.sh --update`.
- Sample env files are readable to the agent (`.env.example`, `.env.sample`,
  `.env.template`, `.env.dist`, `.env.default`, `.env.defaults`). Under AppArmor
  every other `.env.SOMETHING` and every `NAME.env` is refused, so rarer forms of
  samples (`config.example.env`, `.env.local.example`) are refused too: the
  profile errs on the safe side. A `.env`-like file you open with safeai stays
  refused by the profile; `safeai open` says so instead of pretending.
- The network is shared: services you run on `localhost` (dev servers, databases,
  notebooks, local AI tools, admin panels) are reachable to the agent like to any
  local user. Protect them with authentication or stop them while the agent works.
- Secrets under other names are not caught by name: close them explicitly.
- Copies of closed files elsewhere are not closed: backups, `cp -r`, and git
  history (`safeai close` warns when a closed path is in the history).
- A process already inside a folder keeps access after you close it until it
  exits.
- Rules name paths. Inside a folder the agent can change, it can rename an item
  you closed there: the item keeps its closed entry, but the rule no longer names
  it, and opening the folder again later (or an update re-applying the rules)
  opens it. Close whole folders the agent does not work in, rather than single
  items inside its open folders.
- Opening something inside a private folder (mode 700) lets the agent pass
  through that folder without listing it: files in it that are readable by
  everyone become reachable by name.
- `/tmp` is shared: files other programs leave there with open permissions are
  readable.
- Code in open folders that you run later (`.venv`, `node_modules`, scripts,
  services started from project folders, a test you run in the VS Code terminal)
  is code the agent could have changed.
- The agent sees every folder that is open to it at once, not only the project of
  the current chat.

## Review

The depth of the protection was checked before release over several review rounds
by Claude Opus 5.5 and by Astra 6, an independent Codex-based reviewer, besides the
author. Their findings were fixed, each with a regression test in `tests/check.sh`,
and the fixes were checked on Ubuntu, Debian and Arch virtual machines, including
uninstall and power cuts during install. This raises confidence but is not a
professional security audit: before relying on safeai to keep an agent away from
important data, have it audited, and read "Known limits" above.
