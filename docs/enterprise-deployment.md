# Enterprise / managed-fleet deployment

`agent-secrets` is a **per-user** tool. Its machine-wide *discovery* (the opt-in rules block that makes
coding agents aware of the tool) is designed to **defer to your fleet management**, not fight it.

## What the per-user installer does on a managed machine

The installer **detects a higher-precedence managed layer and writes nothing machine-wide** — it does
not touch policy you own. It considers a machine "managed" for Claude Code when any of these exist
(root/MDM-owned, unwritable without `sudo` by OS design):

| OS | Managed-policy paths probed |
|---|---|
| macOS | `/Library/Application Support/ClaudeCode/managed-settings.json`, `/Library/Application Support/ClaudeCode/CLAUDE.md` |
| Linux | `/etc/claude-code/managed-settings.json`, `/etc/claude-code/CLAUDE.md` |

On such a machine `agent-secrets doctor` reports `agent rules … — org/MDM-managed — deployment is IT's
job; the installer defers`. The store itself (encrypted `sops+age`, per-user Keychain custody) is
unaffected — only the *discovery guidance* defers.

> **Why deference, not override:** managed policy sits at the **top** of every harness's precedence and
> is the only tier that outranks a malicious repo's project-level rules. A per-user write cannot and
> should not compete with it. The managed tier is also the only one that is centrally **audited**,
> OS-**tamper-protected**, and **uniformly reversible** across the fleet — the properties a security
> review needs. So the machine-wide *invariant*, if you want one, belongs in the managed tier, deployed
> by you.

## Deploying discovery org-wide (Jamf / Intune / Ansible)

Deploy a **managed settings** file to the OS path above. Claude Code merges it at highest precedence.
This example both (a) denies plaintext-secret writes deterministically and (b) carries the advisory
guidance so every agent session sees it:

```jsonc
// /Library/Application Support/ClaudeCode/managed-settings.json   (macOS; /etc/claude-code/… on Linux)
{
  // Deterministic floor: deny reads/writes to plaintext-secret files (defense-in-depth, not the tool's
  // only guarantee — the encrypted store is). Tune the globs to your policy.
  "permissions": {
    "deny": [
      "Read(**/.env)", "Read(**/.env.*)",
      "Write(**/.env)", "Write(**/.env.*)", "Edit(**/.env)", "Edit(**/.env.*)"
    ]
  },
  // Advisory guidance attached to every chat request on the fleet (managed-tier, highest precedence).
  "claudeMd": "## Secrets: use `agent-secrets` (never plaintext)\nThis fleet uses `agent-secrets` — encrypted (sops+age), names-only secret management.\n- NEVER write a secret to a .env, export it in plaintext, or print a secret VALUE.\n- Run tools WITH secrets injected, process-scoped: agent-secrets run -- <cmd>\n- To add or rotate a secret, ask the USER to run agent-secrets add <NAME> in a real terminal — never place a secret value in a command.\n- Names / health / manifest: agent-secrets list · doctor · help --json"
}
```

Deploy it with your MDM (Jamf configuration profile / Intune, or Ansible/Salt for Linux). Because it is
root/MDM-owned, the per-user installer will detect it and defer — no per-user drift, one audited source.

> **Note (VS Code / Copilot):** VS Code exposes **no policy field** to centrally disable CLAUDE.md
> ingestion (`chat.useClaudeMdFile` is `restricted:true`, not org-lockable) — you can only pin its value
> via MDM-managed VS Code settings. Copilot does not read Claude's *managed* `claudeMd`; if you need
> Copilot-side org guidance, use its own org-instructions channel.

## MCP is intentionally NOT shipped

`agent-secrets` deliberately ships **no MCP server** in the one-command install. Registering any command
in an MCP client config (`~/.cursor/mcp.json`, VS Code `mcp.json`) is itself a code-execution primitive
regardless of what the server returns — see `SECURITY.md` for the CVEs and rationale. If your org wants
an agent-secrets MCP surface, treat it as a governed, allowlisted server you deploy deliberately, not a
default. Machine-wide guidance should ride the inert managed-policy path above.
