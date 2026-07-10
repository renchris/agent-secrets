# assets/demo.tape — VHS script for the hero demo GIF (Charm VHS).
# Regenerate: scripts/record-demo.sh   (seeds an isolated store, then `vhs assets/demo.tape`).
# NAMES-ONLY: the store is pre-seeded with FAKE names outside the recording; no secret value is
# ever typed or shown. The real login Keychain is untouched (mock `security` on PATH).

Output assets/demo.gif

Set Shell "bash"
Set FontSize 20
Set FontFamily "JetBrainsMono Nerd Font"
Set Width 1280
Set Height 840
Set Padding 28
Set Margin 18
Set MarginFill "#0d1117"
Set BorderRadius 12
Set Theme { "name": "agsec", "black": "#0d1117", "red": "#ff6b6b", "green": "#3fb950", "yellow": "#d4af37", "blue": "#58a6ff", "magenta": "#bc8cff", "cyan": "#39c5cf", "white": "#e6edf3", "brightBlack": "#6e7681", "brightRed": "#ff7b72", "brightGreen": "#56d364", "brightYellow": "#e3b341", "brightBlue": "#79c0ff", "brightMagenta": "#d2a8ff", "brightCyan": "#56d4dd", "brightWhite": "#f0f6fc", "background": "#0d1117", "foreground": "#e6edf3", "selection": "#264f78", "cursor": "#d4af37" }
Set TypingSpeed 55ms
Set PlaybackSpeed 1.0

# --- invisible setup: isolated synthetic HOME + mock-isolated Keychain ---
Hide
Type `export AGENT_SECRETS_HOME=/tmp/agsec-demoenv` Enter
Type `export PATH="/Users/chrisren/Development/agent-secrets/tests/mocks:/Users/chrisren/Development/agent-secrets/bin:/opt/homebrew/bin:$PATH"` Enter
Type `export PS1="\[\033[38;5;179m\]❯\[\033[0m\] "` Enter
Type "clear" Enter
Show

Sleep 700ms
Type "agent-secrets --version" Sleep 400ms Enter Sleep 1.4s

# names-only: list shows NAMES + rotate dates, never a value
Type "agent-secrets list" Sleep 400ms Enter Sleep 2.6s

# JIT injection: the value reaches the process but is NEVER displayed — we only count its bytes
Type "agent-secrets run -- printenv ANTHROPIC_API_KEY | wc -c" Sleep 400ms Enter Sleep 1.8s

# categorized health check
Type "agent-secrets doctor" Sleep 400ms Enter Sleep 3.0s

Sleep 1.2s
