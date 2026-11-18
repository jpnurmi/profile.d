export SENTRY_E2E_DSN="${SENTRY_DSN_NATIVE:-}"
export SENTRY_E2E_ORG=sentry-sdks
export SENTRY_E2E_PROJECT=sentry-native

if [[ -z ${SENTRY_E2E_AUTH_TOKEN:-} ]]; then
    tools+=(python3)
    files+=("$HOME/.sentryclirc")
    if command -v python3 >/dev/null 2>&1 && [[ -r $HOME/.sentryclirc ]]; then
        SENTRY_E2E_AUTH_TOKEN=$(python3 - <<'PY'
import configparser
from pathlib import Path

config = configparser.ConfigParser(interpolation=None)
config.read(Path.home() / ".sentryclirc")
print(config.get("e2e", "token", fallback="") or config.get("auth", "token", fallback=""))
PY
        ) || return $?
    fi
fi
export SENTRY_E2E_AUTH_TOKEN

[[ -n $SENTRY_E2E_DSN ]] || errors+=("SENTRY_DSN_NATIVE")
[[ -n ${SENTRY_E2E_AUTH_TOKEN:-} ]] || errors+=("SENTRY_E2E_AUTH_TOKEN ([e2e] or [auth] token in ~/.sentryclirc)")
