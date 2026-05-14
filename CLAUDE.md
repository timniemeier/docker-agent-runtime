# Agent Runtime Operator Notes

The user runs `agent` in parallel across many workspaces, and at least one runtime container is expected to be running at all times.

Implications:

- Do not assume `agent-*` containers are disposable or idle. Avoid broad cleanup commands such as `docker rm -f $(docker ps -aq --filter name=agent-)`, `docker container prune`, or volume removal unless the user explicitly asks for that scope.
- `./run.sh --rebuild` replaces the `agent-runtime:latest` image tag but does not stop running containers. Existing containers keep using the old image until their specific `agent-<hash>` container is removed and recreated.
- Remove or recreate only the project-specific container that the user names or that you have positively identified. Preserve other running workspaces.
- Multiple project containers may mount the same global named volumes (`agent-claude`, `agent-codex`, `agent-gh`, caches, history). Treat credential/session/cache state as shared across runtime containers.
- Because every project is mounted at `/workspace`, Claude sessions inside the shared `agent-claude` volume can appear under the same `~/.claude/projects/-workspace` key. Use `--resume` export/import paths and project context carefully when diagnosing resume behavior.
- Default dev-server host port `4321` may already be held by another always-running workspace. The launcher should fall back to another port or the user should set `AGENT_DEV_HOST_PORT=auto` or a specific free port.
- Prefer targeted inspection commands (`docker ps --filter name=agent-`, `docker inspect <container>`, `docker port <container>`) before suggesting lifecycle changes.
