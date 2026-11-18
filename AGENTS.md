# Agent Instructions

Shell profiles select compilers, analyzers, and targets for builds and tests,
mainly for sentry-native.

## Running Profiles

- Agent shells do not have the `profile` function; run `bash ~/.profile.d/profile.sh` directly.
- Always pass a command after `--`; without one, the profile opens an interactive shell and blocks.
- Run from the target repository; the command runs in the current directory and keeps its exit status.

| Task | Command |
|------|---------|
| List profiles for this platform and missing dependencies | `bash ~/.profile.d/profile.sh --list` |
| Run a command in a profile | `bash ~/.profile.d/profile.sh <name> [<name> ...] -- <command> [args...]` |

## Choosing Profiles

- Pick profiles whose platform, compiler, analyzer, runtime, or target matches the task.
- Combine one compiler, one target, and any analyzers, or use a preset that names the combination.
- Run the project's build or test command through the profile so its environment takes effect.
- Entering a profile with a missing dependency fails; report what's missing instead of working around it.
