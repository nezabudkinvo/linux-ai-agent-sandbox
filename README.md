# linux-ai-agent-sandbox

[README in Russian](README.ru.md)

**Guard rails, not a jail:** your AI agent keeps working in your real folders,
and the Linux kernel keeps it out of what you close.

AI moves fast, and many people already let coding agents such as Claude Code or
Codex work with everything on their computer. That speed brings a risk: an agent
may read or use files you would rather keep to yourself, confidential ones
included. Protecting them costs a little convenience, and tools like this one
will only get more common.

When an agent works under your own account, nothing can tell it apart from you.
It reads everything you can read; an encrypted folder is open to it as soon as
you unlock it; the "don't touch" rules in the agent's own settings do not bind
the scripts it runs. Only the kernel can draw that line, and only between two
users. So this project gives the agent its own Linux account and short commands
to decide, folder by folder, what it may see and change.

The first version is managed from the terminal or from Files (Nautilus, the file
manager of Ubuntu). A desktop app for it already exists and is being tested by
the author.

> Status: early. Tested on fresh Ubuntu 24.04, Debian 12 and Arch Linux virtual
> machines. [SECURITY.md](SECURITY.md) lists what it protects and what it does not.

## Who it is for

People who work with an AI agent every day and mostly trust it, but want some
things kept out of its hands:

- **what it must not read:** personal documents, keys, passwords, `.env` files;
- **what it must not change:** your git settings and hooks, `~/.bashrc`, the
  configs of your editor and other agents - everything that later runs as you.

The agent keeps working in your real project folders, with its usual tools and
network access: no containers, no copies of your projects, nothing to mount. The
line holds whatever program the agent runs, which covers both its own mistakes
and instructions hidden in a web page or a README it happens to read.

It is not a jail: whatever you leave open to the agent, it can send out, like
any program with network access. For code you do not trust at all, or data that
must never leave the machine, use a virtual machine.

## In short

- The agent gets its own Linux user. It works in your real folders, but only
  where you allow it: the kernel checks every file access, whatever program the
  agent uses.
- For each folder or file you choose: **open** (the agent reads and writes),
  **read-only**, or **closed** (it cannot even see it).
- Out of the box the agent sees nothing in your home: you open the project
  folders it should work in (`safeai` offers it the first time). Or choose the
  relaxed mode at install: your folders open, and only what must never leak or
  change is protected (`.env` files, keys and passwords closed; settings and the
  places code runs from, like `~/.bashrc`, `~/bin`, `.git`, read-only).
- Your own `claude`, `codex` and VS Code keep working as you, exactly as before.
  The agent runs only where you ask for it: `safeai` opens a terminal as the
  agent; VS Code can be switched to it too.
- Everything can be removed without a trace: `sudo /usr/local/lib/safeai/uninstall.sh`.

## How it looks

```
$ safeai close ~/Documents/taxes             # the agent never sees this
$ safeai read ~/bin                          # it may run these, not change them
$ cd ~/Projects/website && safeai            # a terminal as the agent, here
aiagent$ claude                              # Claude, working as the agent
$ safeai ls ~/Projects/website
write   /home/me/Projects/website
closed  .env                        (.env)
read    .vscode/
$ safeai log                                 # what it tried and was refused
09-28 21:12     2x  open             cat            ~/Documents/taxes/2025.pdf
```

## Install

```
git clone https://github.com/nezabudkinvo/linux-ai-agent-sandbox
cd linux-ai-agent-sandbox
git checkout v0.1.1     # the latest release; GitHub shows its tag as Verified (signed)
./install.sh --plan     # see every change first; nothing is modified, no sudo
./install.sh            # questions, the plan, then sudo for exactly that plan
```

The installer runs as you: it asks for a language (English or Russian), the name
of the agent's user, the mode and which options to enable, and shows the full
plan. Only after your yes does it ask for sudo, to carry out that plan and
nothing else. It downloads nothing itself (missing packages come from your
package manager). The program itself is installed into `/usr/local` (owned by root, so
nothing running as you or as the agent can change it); the downloaded copy can
be deleted afterwards.

Check the result: `/usr/local/lib/safeai/check.sh` (as yourself).

Update: `safeai settings`, then `u` (or `safeai settings update`). It installs
only a newer release signed with the project's key, which your installation
recorded when you installed it; it shows who signed it and what changed, and asks
before it runs the installer with sudo. Your rules and answers stay. By hand,
in your clone: `git fetch --tags && git checkout vX.Y.Z`, read the changes, then
`sudo ./install.sh --update`.

Want to try it first without touching your system? `tests/vm.sh test ubuntu`
runs it in a throwaway virtual machine.

Remove: `sudo /usr/local/lib/safeai/uninstall.sh` - see
[What the installer changes](#what-the-installer-changes).

## Use

```
safeai                          a terminal as the agent, in this folder (offers to open it)
safeai status                   mode and every rule you set
safeai settings                 settings in a menu: mode, VS Code, Files; there, r drops
                                all your rules, u installs a newer signed release (both ask)
safeai ls [PATH]                what the agent can do with each entry here
safeai open PATH...             the agent reads and writes
                                (asks y/N first for settings and places that run code as you)
safeai read PATH...             the agent reads, cannot change
safeai close PATH...            the agent can neither read nor enter
safeai check [--fix]            verify and repair (runs every 5 minutes)
safeai log [HOURS|all]          refused actions (with the audit option)
```

Run the agent:

```
cd ~/Projects/website
safeai                 # a terminal as the agent (asks to open this folder the first time)
claude                 # in it: Claude as the agent (or codex, or any other agent CLI)
```

The agent has its own copies of AI tools and signs in with its own account. The
first time you type `claude` (or `codex`, `gemini`) in the agent's terminal, it
shows the one command that installs it for the agent, no sudo needed. Tools
installed for the whole system work for the agent as they are. In VS Code
nothing needs installing: the extensions bring their own.

When the agent needs something it cannot reach, it stops and asks you, with the
exact command (`safeai open PATH` or `safeai read PATH`); for secrets it asks you
to make the change yourself. The installer gives it these instructions
(`~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` of the agent user).

## Details

### Modes

For everything you did not set yourself (switch in `safeai settings`):

- `strict` (the default): the agent sees nothing in your home (not even its
  list of files) until you open or allow reading something.
- `relaxed`: your folders are open, new ones too; hidden settings and program
  folders like `~/bin` are read-only. Convenient, but everything you did not
  close (`~/Documents` too) is open to the agent.

In both modes:

- closed: known secret stores (`~/.ssh`, `~/.gnupg`, browser profiles, keyrings,
  cloud, git and package-registry credentials, other AI tools' logins) and every
  `.env`-like file, the moment it appears;
- read-only even inside open folders, from the moment they appear (a new
  `git init` or `git clone` too): the whole `.git` of your repositories,
  `.vscode`, `.envrc`, `.claude`, `.codex`, `.mcp.json` - so the agent cannot
  plant code that you or your tools later run as yourself. `safeai open` on
  them asks first, default no. The agent reads your repositories (`git status`,
  `log`, `diff`) but does not commit in them: you commit its changes. In a
  repository it cloned or created itself, it commits as usual; do not run
  your own git there (`safeai ls` and `safeai status` mark such repositories);
- files you made private yourself (mode 600/700) stay private;
- files the agent creates in open folders become yours.

The agent's network is not restricted: it uses the system's routing like any
other program (the agents' own sandboxes, such as Claude Code's `/sandbox`,
do not run inside safeai: they need to mount file systems, which safeai's
AppArmor profile refuses). It shares `localhost` with you: a dev server it starts opens in
your browser as usual, and services you run locally are reachable to it like to
any user of the machine, so keep those behind a password.

### VS Code and Files

- VS Code, in `safeai settings`: the Claude Code and Codex extensions always
  run as the agent; a folder closed to it is refused, never silently run as
  you. Off by default.
- Files (Nautilus): right-click menu (open / read-only / close) and emblems. The
  installer offers it when Files is your default file manager; to add it later,
  install `nautilus` and `python3-nautilus` and run the installer again.

### Requirements

Linux with systemd, a home folder on a filesystem with ACLs (ext4, btrfs, xfs),
Python 3.8+, sudo; apt, dnf or pacman to add missing packages.

Optional:

- AppArmor, to refuse `.env` files to the agent at open time. It is on by
  default in Ubuntu, Debian and openSUSE; on Arch enable it first (see the Arch
  wiki, "AppArmor") and run the installer again. Without it the guard service
  closes new `.env` files right after they appear.
- auditd, for `safeai log`.
- nautilus-python, for the Files extension.

### What the installer changes

- It records every file, user, service and package it creates in
  `/var/lib/safeai/manifest` and backs up every existing file it changes.
- If a step fails, it reverts everything it did.
- It never touches the network, other users, your groups or your login.
- `uninstall.sh` reverts the manifest: restores the backed-up files, removes what
  was created, removes the ACL entries it put on your files and gives your files
  back their permissions, deletes your safeai lists. It asks whether to delete
  the agent user with its home (its logins and chat history), the packages it
  installed and the downloaded copy; the default is yes. `--yes` removes
  everything but the downloaded copy without asking.
  Files the agent made in your folders stay, as yours.

Please read `install.sh` before you agree to its plan - it is short on purpose.

### How it works

- `bin/safeai` - the command; runs as you and changes ACLs on your own files.
- `libexec/safeai-guard` - a small root service (fanotify): hands the agent's
  new files to you, closes new `.env` files at once, applies the mode to new
  folders in your home.
- `libexec/safeai-run` - starts a program as the agent with a clean environment
  (no tokens, no session sockets), inside the AppArmor profile.
- `libexec/safeai-shell` - the agent's login shell: everything it starts runs
  inside the profile.
- `share/apparmor/safeai-agent.in` - the profile: everything is allowed except
  secret-looking file names outside `/tmp`, mounts and profile changes.
- A systemd timer runs `safeai check --fix` every 5 minutes.

### Testing

`tests/vm.sh test ubuntu [strict|relaxed]` (also `debian`, `arch`) boots a
throwaway virtual machine (QEMU/KVM, no root needed), installs this checkout and
runs the checks there. `tests/vm.sh clean ubuntu` installs, uses and removes
safeai, then compares the machine with how it was before.

## Acknowledgements

Thanks to Claude Code (Anthropic) for the analysis of existing approaches and
help with writing and reviewing the code.

## License

MIT, see [LICENSE](LICENSE).
