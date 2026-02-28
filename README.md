# lumon

Process supervisor with Lua config. Manage long-running services, restart on crash, health-check, rotate logs.

```sh
lumon services.lua
```

Config is a plain Lua file:

```lua
return {
  {
    name    = "web",
    cmd     = "./server",
    args    = {"--port", "8080"},
    restart = "always",
    health  = { cmd = "curl -sf http://localhost:8080/health", interval = 10 },
  },
  {
    name         = "worker",
    cmd          = "./worker",
    restart      = "on-failure",
    max_restarts = 5,
  },
}
```

## Install

Requires Zig 0.13+.

```sh
git clone https://github.com/wholovesalife/lumon
cd lumon
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/lumon /usr/local/bin/
```

## Usage

```
lumon [OPTIONS] <services.lua>

Options:
  --log-level <level>   debug|info|warn|error  (default: info)
  --log-file  <path>    Write structured logs to a file
  --log-max   <bytes>   Rotate log at this size (default: 10MB)
  --help
```

## Config reference

### Service fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | string | required | Service identifier (used in logs) |
| `cmd` | string | required | Executable to run |
| `args` | string[] | `{}` | Command-line arguments |
| `restart` | string | `"on-failure"` | `"always"`, `"on-failure"`, `"never"` |
| `max_restarts` | number | unlimited | Stop restarting after N failures |
| `health` | table | nil | Health check configuration |
| `env` | table | `{}` | Extra environment variables |
| `cwd` | string | inherited | Working directory |
| `pre_stop` | string | nil | Shell command to run before SIGTERM |

### Health check fields

```lua
health = {
  cmd      = "curl -sf http://localhost:8080/health",
  interval = 10,   -- check every N seconds
}
```

If the health check command exits non-zero, the service is restarted.

### Restart policies

| Policy | Behavior |
|--------|----------|
| `"always"` | Restart whenever the process exits, regardless of exit code |
| `"on-failure"` | Restart only when exit code != 0 |
| `"never"` | Never restart |

`max_restarts` caps the total number of restarts. Once exceeded, the service is marked `failed` and left stopped.

### Environment variables in config

```lua
env = {
  DATABASE_URL = "postgres://localhost/myapp",
  SECRET_KEY   = "...",
}
```

Environment is merged with the parent process environment.

### Pre-stop hook

```lua
pre_stop = "curl -X POST http://localhost:8080/graceful-shutdown"
```

Runs before SIGTERM. lumon waits up to 5 seconds for the process to exit after SIGTERM before sending SIGKILL.

## Behaviour

### Startup

All services are started in config order at launch. If a service fails to start (executable not found, permission denied), lumon logs the error and continues starting the rest.

### Supervisor loop

Every 500ms lumon polls all running processes. If a process has exited:

1. The exit is logged.
2. If the restart policy permits, lumon waits with exponential backoff (1s, 2s, 4s … max 30s) then restarts.
3. If `max_restarts` is exceeded, the service is marked `failed`.

### Health checks

Health checks run every 10 seconds. A failing health check (non-zero exit) causes an immediate restart.

### Shutdown

On SIGTERM or SIGINT, lumon:

1. Runs each service's `pre_stop` hook (if configured).
2. Sends SIGTERM to each running process.
3. Waits up to 5 seconds for graceful exit.
4. Sends SIGKILL to any that haven't exited.
5. Exits cleanly.

### Log rotation

When `--log-file` is set, lumon rotates the log file when it exceeds `--log-max` bytes. The current log is renamed to `<path>.1` and a new file is opened.

## Log format

```
1745234100.123 [INFO ] [web]    started (pid=12345)
1745234100.456 [INFO ] [worker] started (pid=12346)
1745234115.000 [WARN ] [worker] exited (restarts=0)
1745234116.001 [INFO ] [worker] restarting in 1s (attempt 1)
```

## Comparison with alternatives

| Feature | lumon | supervisord | s6 |
|---------|-------|-------------|-----|
| Config format | Lua | INI | filesystem |
| Binary size | ~200 KB | Python | ~100 KB |
| Dependencies | none | Python | none |
| Health checks | yes | no | yes |
| Pre-stop hook | yes | no | yes |
| Log rotation | built-in | no | no |

## Planned

- HTTP API for status / control
- `lumon restart <name>` CLI
- Dependency ordering (`after = {"db"}`)
- systemd socket activation
- Config reload without restart (`lumon reload`)
