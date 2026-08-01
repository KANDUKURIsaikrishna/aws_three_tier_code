import express from "express";
import cors from "cors";
import morgan from "morgan";
import jwt from "jsonwebtoken";
import { createProxyMiddleware } from "http-proxy-middleware";
import { Registry, collectDefaultMetrics, Counter, Histogram } from "prom-client";

const SERVICE_NAME = "api-gateway";

const registry = new Registry();
registry.setDefaultLabels({ service: SERVICE_NAME });
collectDefaultMetrics({ register: registry });

const httpRequests = new Counter({
  name: "http_requests_total",
  help: "Total HTTP requests",
  labelNames: ["method", "route", "status", "service"],
  registers: [registry],
});

const httpDuration = new Histogram({
  name: "http_request_duration_seconds",
  help: "HTTP request duration in seconds",
  labelNames: ["method", "route", "status", "service"],
  buckets: [0.01, 0.05, 0.1, 0.5, 1, 2],
  registers: [registry],
});

const KNOWN_PREFIXES = ["/books", "/auth", "/users", "/orders", "/cart", "/health", "/metrics"];

// Collapse raw request paths (e.g. /books/123) down to their known mount
// point (e.g. /books) so the Prometheus "route" label stays bounded to a
// fixed, small set of values instead of growing per unique resource id.
function routeLabel(path) {
  const match = KNOWN_PREFIXES.find((prefix) => path === prefix || path.startsWith(`${prefix}/`));
  return match || "/other";
}

function verifyJwt(jwtSecret) {
  return (req, res, next) => {
    const header = req.headers.authorization;
    if (!header || !header.startsWith("Bearer ")) {
      return res.status(401).json({ error: "missing or invalid Authorization header" });
    }
    const token = header.slice("Bearer ".length);
    try {
      const decoded = jwt.verify(token, jwtSecret, { algorithms: ["HS256"] });
      req.headers["x-user-id"] = String(decoded.userId);
      next();
    } catch {
      return res.status(401).json({ error: "invalid or expired token" });
    }
  };
}

// GET is public (book browsing); every other method requires a valid JWT.
function protectMutations(jwtSecret) {
  return (req, res, next) => {
    if (req.method === "GET") return next();
    return verifyJwt(jwtSecret)(req, res, next);
  };
}

// targets = { catalog: url, user: url, order: url }
export function createApp(jwtSecret, targets) {
  const app = express();
  app.use(cors());
  app.use(morgan("common"));
  // Deliberately NO express.json() here — every sibling service uses
  // app.use(express.json()), but the gateway must not. http-proxy-middleware
  // forwards the raw incoming request stream to the upstream service; if
  // express.json() (or any body-parsing middleware) ran first, it would
  // fully consume that stream to populate req.body, leaving nothing to
  // forward — POST/PUT bodies would silently arrive empty downstream.
  // The gateway parses no body at all — it only reads headers
  // (Authorization) and forwards everything else untouched.

  app.use((req, res, next) => {
    const start = Date.now();
    res.on("finish", () => {
      const duration = (Date.now() - start) / 1000;
      const route = routeLabel(req.path);
      httpRequests.labels(req.method, route, String(res.statusCode), SERVICE_NAME).inc();
      httpDuration.labels(req.method, route, String(res.statusCode), SERVICE_NAME).observe(duration);
    });
    next();
  });

  app.get("/metrics", async (_req, res) => {
    res.set("Content-Type", registry.contentType);
    res.end(await registry.metrics());
  });

  app.get("/health", (_req, res) => {
    res.status(200).json({ status: "ok" });
  });

  app.use(
    "/books",
    protectMutations(jwtSecret),
    createProxyMiddleware({ target: targets.catalog, changeOrigin: true })
  );

  app.use("/auth", createProxyMiddleware({ target: targets.user, changeOrigin: true }));

  app.use(
    "/users",
    verifyJwt(jwtSecret),
    createProxyMiddleware({ target: targets.user, changeOrigin: true })
  );

  app.use(
    ["/orders", "/cart"],
    verifyJwt(jwtSecret),
    createProxyMiddleware({ target: targets.order, changeOrigin: true })
  );

  return app;
}
