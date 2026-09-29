# Security model

## Threat

An AI agent works on your machine with most of your abilities. It is not
malicious, but it can be steered by text it reads (prompt injection) and it
sends what it reads to a model. safeai aims to:

1. keep chosen files unreadable to the agent, whatever program it uses;
2. keep code that runs as you (git hooks, editor and agent configs, your
   scripts) out of the agent's reach;
3. stay convenient: the agent works in your real project folders.

Out of scope: root, physical access, and code the agent wrote that you then run
yourself.

## Layers

| Layer | Holds | Relies on |
|---|---|---|
| Separate user | your session (D-Bus, Wayland, ssh-agent), your processes, sudo | uid; the only sudo rule is you -> agent |
| ACLs | closed / read-only / open paths; executable places read-only | POSIX ACL entries for the agent user, default ACLs in open folders |
| Guard service | new `.env` closed and a new repo's whole `.git` (and `.vscode`, ...) made read-only at creation; agent files handed to you | root fanotify service |
| AppArmor (optional) | `.env`-like names refused at open time, no mount | profile on every agent process: login shell, editor launcher, its `systemd --user`; cron/at denied |
| Audit (optional) | a record of refused actions | kernel audit rules for the agent's uid |

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

## Modes

- `strict`: the home folder is enter-only for the agent (it cannot list it) and
  every entry in it is closed. A folder on the way to one you opened is
  enter-only too, with everything else in it closed. New entries are closed by
  the guard (folders, at once) and by the periodic check (files, within 5 minutes).
- `relaxed`: visible folders are open; hidden entries keep their own
  permissions (the agent cannot change them).

Both modes close the same secret stores and keep executable places read-only.

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
- The agent can rename your repository's `.git` directory aside (that rename is a
  property of the work folder, which is open) and drop its own `.git` in its
  place. If it drops a `.git` *file* (a gitdir pointer), `safeai check`
  quarantines it. If it drops a whole agent-owned `.git` *directory*, the
  repository is left visibly broken (your `git` reports "not a repository"), so
  it is a denial of service you would notice, not a silent code-execution path;
  closing it fully would need a sticky bit on every work folder, which breaks the
  agent's normal file edits. Re-clone or restore the renamed `.git` to recover.
- Configuration the agent authors in an open folder (a `.vscode`, `.claude`,
  `.codex`, `.mcp.json`, `.envrc` or `*.desktop` it creates) is quarantined by
  `safeai check`, so your editor or tools never load agent-controlled settings.
  Inside the agent's own repositories (marked by `safeai ls`) they stay: they are
  that project's files, and you should not run your tools there.
  Between the moment the agent creates it and the next check (at most 5 minutes)
  it exists; loading it still takes an owner action that runs it (for example a
  VS Code task, which needs a trusted workspace).
- Sample env files are readable to the agent (`.env.example`, `.env.sample`,
  `.env.template`, `.env.dist`, `.env.defaults`). Only the rarer `*.env` forms of
  samples (`config.example.env`, `app-sample.env`) are refused under AppArmor:
  its name patterns cannot leave out a sample and still cover every `NAME.env`,
  so it errs on the safe side.
- The network is shared: services you run on `localhost` (dev servers, databases,
  notebooks, local AI tools, admin panels) are reachable to the agent like to any
  local user. Protect them with authentication or stop them while the agent works.
- Secrets under other names are not caught by name: close them explicitly.
- Copies of closed files elsewhere are not closed: backups, `cp -r`, and git
  history (`safeai close` warns when a closed path is in the history).
- A process already inside a folder keeps access after you close it until it
  exits.
- Opening something inside a private folder (mode 700) lets the agent pass
  through that folder without listing it: files in it that are readable by
  everyone become reachable by name.
- `/tmp` is shared: files other programs leave there with open permissions are
  readable.
- Code in open folders that you run later (`.venv`, `node_modules`, scripts,
  services started from project folders) is code the agent could have changed.
