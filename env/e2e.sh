export SENTRY_E2E_DSN="${SENTRY_DSN_NATIVE:-}"
export SENTRY_E2E_ORG=sentry-sdks
export SENTRY_E2E_PROJECT=sentry-native

if [[ -z ${SENTRY_E2E_AUTH_TOKEN:-} ]]; then
    tools+=(sentry)
    if command -v sentry >/dev/null 2>&1; then
        SENTRY_E2E_AUTH_TOKEN=$(sentry auth token 2>/dev/null)
    fi
fi
export SENTRY_E2E_AUTH_TOKEN

[[ -n $SENTRY_E2E_DSN ]] || errors+=("SENTRY_DSN_NATIVE")
[[ -n ${SENTRY_E2E_AUTH_TOKEN:-} ]] || errors+=("SENTRY_E2E_AUTH_TOKEN (or sentry auth login)")
