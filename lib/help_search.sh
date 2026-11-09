# shellcheck shell=bash
# lib/help_search.sh — `agent-secrets help search <TEXT> [--json]`: an offline, case-insensitive
# substring search over each verb's name, summary, synopsis and examples in agsec_help_spec.
# Sourced by the dispatcher after common.sh and help.sh. The query is matched in memory only: it is
# never written to disk or logged. Only AGSEC_VERBS is searched, so the hidden smoke verb stays hidden.

AGSEC_HELP_SEARCH_MAX=10

agsec_help_search() {
  local q="" a format=text past_dd=0
  agsec_scan_json "$@"
  for a in "$@"; do
    if [ "$past_dd" -eq 0 ]; then
      case "$a" in
        --) past_dd=1; continue ;;
        --json) format=json; continue ;;
        -h|--help)
          printf '%s\n' 'Usage: agent-secrets help search <TEXT> [--json]' '' \
            'Case-insensitive search over command names, summaries, synopses and examples. Works offline.'
          return 0 ;;
        -*) agsec_unknown_option "help search" "$a" ;;
      esac
    fi
    q="${q:+$q }$a"
  done
  [ -n "$q" ] || agsec_fail usage "Missing search text for help search." "agent-secrets help search --help" "See the options"

  # The query reaches awk through its environment, not -v (which would process backslash escapes),
  # and index() matches it literally, never as a regex.
  local hits
  hits="$(agsec_help_spec | AGSEC_HS_Q="$q" AGSEC_HS_VERBS="$AGSEC_VERBS" AGSEC_HS_MAX="$AGSEC_HELP_SEARCH_MAX" \
    awk -F'\t' '
      BEGIN {
        q = tolower(ENVIRON["AGSEC_HS_Q"]); n = split(ENVIRON["AGSEC_HS_VERBS"], order, " ")
        for (i = 1; i <= n; i++) { known[order[i]] = 1; if (index(order[i], q)) hit[order[i]] = 1 }
      }
      ($1 in known) {
        if ($2 == "summary") summary[$1] = $3
        if (($2 == "summary" || $2 == "synopsis" || $2 == "example") &&
            (index(tolower($3), q) || index(tolower($4), q))) hit[$1] = 1
      }
      END {
        c = 0
        for (i = 1; i <= n && c < ENVIRON["AGSEC_HS_MAX"] + 0; i++)
          if (order[i] in hit) { print order[i] "\t" summary[order[i]]; c++ }
      }')"

  # Pipes, not heredocs: bash 3.2 backs a heredoc with a temp file.
  if [ "$format" = json ]; then
    printf '%s\n' "$hits" | {   # a subshell: verb, summary and items do not leak
      items=""
      while IFS=$'\t' read -r verb summary; do
        [ -n "$verb" ] || continue
        items="${items:+$items,}{\"path\":\"agent-secrets $(agsec_js "$verb")\",\"summary\":\"$(agsec_js "$summary")\"}"
      done
      printf '{"commands":[%s]}\n' "$items"
    } | agsec_json_out
    return 0
  fi
  if [ -z "$hits" ]; then
    # Control bytes are dropped so a pasted escape sequence cannot drive the terminal.
    printf 'No commands match "%s"\n' "$(printf '%s' "$q" | tr -d '[:cntrl:]')"
    return 0
  fi
  printf '%s\n' "$hits" | while IFS=$'\t' read -r verb summary; do
    printf '  agent-secrets %s  %s\n' "$verb" "$summary"
  done
  return 0
}
