-- services.lua — example lumon config
-- Manages a web server and a background worker

return {
  {
    name    = "web",
    cmd     = "./server",
    args    = {"--port", "8080", "--workers", "4"},
    restart = "always",
    health  = {
      cmd      = "curl -sf http://localhost:8080/health",
      interval = 10,
    },
    env = {
      PORT     = "8080",
      APP_ENV  = "production",
    },
    pre_stop = "curl -sf -X POST http://localhost:8080/shutdown",
  },

  {
    name         = "worker",
    cmd          = "./worker",
    args         = {"--queue", "default", "--concurrency", "2"},
    restart      = "on-failure",
    max_restarts = 5,
    env = {
      QUEUE_URL = "redis://localhost:6379",
      APP_ENV   = "production",
    },
  },

  {
    name    = "metrics",
    cmd     = "./metrics-exporter",
    restart = "always",
    health  = {
      cmd      = "curl -sf http://localhost:9100/metrics",
      interval = 30,
    },
  },
}
