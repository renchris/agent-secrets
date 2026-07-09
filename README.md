# agent-secrets

Machine-wide secrets for coding agents — encrypted at rest (sops + age), injected
just-in-time at the process boundary, never written to configs, logs, or transcripts.
**Names-only:** the tool is built so a secret value is never displayed, logged, or stored
outside the encrypted store.

> **Status: v0.1 under construction.** This README is a placeholder; the full entry-point
> document (hero demo → the one command → reversibility → security model → FAQ) is authored
> by the docs task per the implementation plan. 
> Security model: [`SECURITY.md`](SECURITY.md) (added by the docs task).

## The one command (private beta)

While the repository is private the public `curl` one-liner 404s; install via the base-URL
override against a private mirror or a local checkout:

```sh
AGENT_SECRETS_BASE_URL=... sh -c "$(cat install.sh)"   # see
```

## Verbs

`setup` · `add <NAME>` · `list` · `run -- <cmd>` · `doctor` · `uninstall`
(`rotate`, `demo` reserved for v0.2). Run `agent-secrets help` for details.

## License

MIT — see [LICENSE](LICENSE).
