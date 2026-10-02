// safeai in VS Code: a status bar switch, per window, for who runs the AI sessions that start there,
// Claude Code and Codex alike (the AI agent or you), and "AI agent" in the Explorer menu (open, read
// only, close, what can it do here).
// Everything goes through the safeai command; this file keeps no state of its own.
const vscode = require("vscode");
const { execFile } = require("child_process");
const fs = require("fs");

const SAFEAI = "/usr/local/bin/safeai";
const RUNTIME = `/run/user/${process.getuid()}`;
let item, log;

function run(args) {
  return new Promise((resolve) =>
    execFile(SAFEAI, args, { timeout: 15 * 60 * 1000, env: { ...process.env, NO_COLOR: "1" } }, (err, out, errout) =>
      resolve({ ok: !err, text: `${out || ""}${errout || ""}`.trim() || (err ? String(err.message) : "") })
    )
  );
}

// The switch is per window, by its folders: who runs the AI sessions that start there from now on.
// _who FOLDER... prints agent, me, or off (VS Code does not go through safeai: every chat is yours).
let state;
const folders = () => (vscode.workspace.workspaceFolders || []).filter((f) => f.uri.scheme === "file").map((f) => f.uri.fsPath);

// safeai learns this window's folders from here: Codex starts in your home, not in the project, and
// the launcher finds its window by this extension host
const tell = () => run(["_window", ...folders()]);

async function refresh() {
  state = folders().length ? (await run(["_who", ...folders()])).text.split(/\s+/)[0] : "agent";
  const look = {
    agent: ["$(shield) AI: agent", undefined, "AI sessions that start in this window run as the AI agent. Click: as you."],
    me: ["$(account) AI: me", new vscode.ThemeColor("statusBarItem.warningBackground"),
         "AI sessions that start in this window run as you, until you click again."],
    off: ["$(account) AI: me", undefined, "VS Code does not go through safeai: everything runs as you (safeai settings)."],
  }[state] || ["$(warning) AI: ?", undefined, "safeai did not answer."];
  [item.text, item.backgroundColor, item.tooltip] = look;
  if (!folders().length) item.tooltip = "Open a folder: the switch is per window, by its folder.";
  if (state === "agent" || state === "me") item.tooltip += " Codex follows after a window reload; chats already open keep their own.";
}

// one click: agent <-> me. Codex and the chats already running follow after a window reload: offered,
// never done for you (something there may be unsaved)
async function who() {
  if (state === "off" || !folders().length) return;
  const r = await run(["_who", state === "me" ? "agent" : "me", ...folders()]);
  if (!r.ok) return vscode.window.showErrorMessage(`safeai: ${r.text}`);
  await refresh();
  const b = await vscode.window.showInformationMessage(
    `AI: ${state} for new chats here. Reload the window to apply it to Codex too.`, "Reload window");
  if (b) vscode.commands.executeCommand("workbench.action.reloadWindow");
}

function target(uri) {
  const u = uri || vscode.window.activeTextEditor?.document.uri;
  return u && u.scheme === "file" ? u.fsPath : undefined;
}

function report(r) {
  log.appendLine(r.text);
  const first = r.text.split("\n")[0];
  (r.ok ? vscode.window.showInformationMessage : vscode.window.showWarningMessage)(`safeai: ${first}`);
}

async function set(kind, uri) {
  const p = target(uri);
  if (!p) return;
  let r = await run([kind, p]);
  // places that run code as you, or hold secrets: only after you say so, here as in a terminal
  if (!r.ok && kind === "open" && /runs code as you|holds secrets/.test(r.text)) {
    const b = await vscode.window.showWarningMessage(
      /holds secrets/.test(r.text)
        ? `${p} holds keys or passwords. The agent could read them and send them anywhere.`
        : `${p} holds settings or code that run as you. If the agent can change it, it can act as you.`,
      { modal: true },
      "Open anyway"
    );
    if (!b) return;
    r = await run(["open", "--force", p]);
  }
  report(r);
}

async function why(uri) {
  const p = target(uri);
  if (!p) return;
  const r = await run(["why", p]);
  log.appendLine(r.text);
  vscode.window.showInformationMessage(r.text.split("\n").slice(0, 3).join(" "), "Details").then((b) => b && log.show());
}

function activate(context) {
  log = vscode.window.createOutputChannel("safeai");
  item = vscode.window.createStatusBarItem("safeai.who", vscode.StatusBarAlignment.Right, 100);
  item.name = "safeai";
  item.command = "safeai.who";
  item.show();
  context.subscriptions.push(
    log,
    item,
    vscode.commands.registerCommand("safeai.who", who),
    vscode.commands.registerCommand("safeai.open", (u) => set("open", u)),
    vscode.commands.registerCommand("safeai.read", (u) => set("read", u)),
    vscode.commands.registerCommand("safeai.close", (u) => set("close", u)),
    vscode.commands.registerCommand("safeai.why", why),
    vscode.window.onDidChangeWindowState((s) => s.focused && refresh()),
    vscode.workspace.onDidChangeWorkspaceFolders(() => tell().then(refresh))
  );
  // the switch can change outside this window (another window, a chat that used "next", the time ran out)
  try {
    const w = fs.watch(RUNTIME, (_e, name) => name === "safeai-me" && refresh());
    context.subscriptions.push({ dispose: () => w.close() });
  } catch (_e) {
    // no session folder: the window focus and the timer below still refresh it
  }
  const t = setInterval(refresh, 30 * 1000);
  context.subscriptions.push({ dispose: () => clearInterval(t) });
  tell().then(refresh);
}

function deactivate() {}

module.exports = { activate, deactivate };
