# Sourced (not executed) by the headless runner scripts (prep-run.sh, reply-classify-run.sh).
# The app launches those scripts with a minimal PATH that excludes fnm/nvm shim dirs. The
# claude CLI they resolve further down spawns its own hooks (e.g. the SessionEnd cleanup
# hook) as child processes, which inherit that same minimal PATH and silently fail to find
# node (#636). Prepending a real node's directory here, before claude ever launches, fixes
# it for every hook those runs spawn without each runner script duplicating this lookup.
NODE_BIN=""
for n in "$(command -v node 2>/dev/null || true)" "/opt/homebrew/bin/node" "/usr/local/bin/node"; do
  if [ -n "$n" ] && [ -x "$n" ]; then NODE_BIN="$n"; break; fi
done
if [ -n "$NODE_BIN" ]; then
  PATH="$(dirname "$NODE_BIN"):$PATH"
  export PATH
  echo "node resolved: $NODE_BIN"
else
  echo "node not found on PATH; hooks that need node may fail" >&2
fi
