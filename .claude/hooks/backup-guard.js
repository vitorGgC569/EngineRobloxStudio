#!/usr/bin/env node
/**
 * PreToolUse backup guard for the RQE repository.
 *
 * Blocks mass destructive operations (bulk delete/overwrite of Luau sources,
 * place files or artifacts) unless a fresh backup marker exists.
 * Adapted from the BloxAI backup-guard pattern; TTL 30 minutes.
 *
 * Marker contract: any tool that completes a verified backup writes
 * `.rqe/.last-backup` containing an ISO timestamp. The guard fails closed:
 * a missing/unreadable marker counts as stale.
 *
 * Claude Code hook wiring (.claude/settings.json):
 * {
 *   "hooks": { "PreToolUse": [ { "matcher": "Bash",
 *     "hooks": [ { "type": "command", "command": "node .claude/hooks/backup-guard.js" } ] } ] }
 * }
 */

const fs = require("fs");
const path = require("path");

const TTL_MS = 30 * 60 * 1000;
const MARKER = path.join(process.cwd(), ".rqe", ".last-backup");

const DESTRUCTIVE = [
  /\brm\s+(-[a-zA-Z]*\s+)*(\.\.|~|\/)\b/,
  /git\s+(clean\s+-[a-zA-Z]*f|reset\s+--hard)/,
  /(Remove-Item|del|erase)\s+[^\n]*(roblox|forge|artifacts|contracts)[^\n]*-Recurse/i,
  /\b(del|rm)\b[^\n]*\.rbxlx?\b/i,
];

const input = JSON.parse(fs.readFileSync(0, "utf8") || "{}");
const command = ((input.tool_input || {}).command || "").toString();

function isDestructive(cmd) {
  return DESTRUCTIVE.some((re) => re.test(cmd));
}

function hasFreshBackup() {
  try {
    const stamp = new Date(fs.readFileSync(MARKER, "utf8").trim());
    return Date.now() - stamp.getTime() <= TTL_MS;
  } catch {
    return false;
  }
}

if (!isDestructive(command)) {
  process.exit(0);
}

if (hasFreshBackup()) {
  console.log("[backup-guard] fresh backup marker present; allowing.");
  process.exit(0);
}

console.error(
  "[backup-guard] BLOCKED: mass destructive operation without a fresh backup " +
    "(marker .rqe/.last-backup older than 30 min or missing). " +
    "Run a backup and write the marker timestamp first."
);
process.exit(2); // block the tool call
