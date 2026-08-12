import express from "express";
import cors from "cors";
import morgan from "morgan";
import bcrypt from "bcryptjs";
import jwt from "jsonwebtoken";
import rateLimit from "express-rate-limit";
import { Registry, collectDefaultMetrics, Counter, Histogram } from "prom-client";

const SERVICE_NAME = "user-service";

// The timing-safe dummy-hash compare below only protects against
// enumeration-by-timing, not raw brute force -- nothing else in this
// service throttled repeated attempts against the same IP.
const authRateLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: 20,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: "too many attempts, try again later" },
});

// Computed once at startup; compared against on every login where the email
// isn't found, so that branch takes comparable time to the real-user path
// and doesn't leak account existence via response timing.
const DUMMY_HASH = bcrypt.hashSync("dummy-password-for-timing-safety", 10);

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

function verifyJwt(jwtSecret) {
  return (req, res, next) => {
    const header = req.headers.authorization;
    if (!header || !header.startsWith("Bearer ")) {
      return res.status(401).json({ error: "missing or invalid Authorization header" });
    }
    const token = header.slice("Bearer ".length);
    try {
      // Algorithm pinned to match api-gateway's equivalent check on this
      // same secret (services/api-gateway/app.js) -- verifying an HMAC
      // secret with no algorithms restriction is the standard setup for
      // JWT algorithm-confusion issues.
      req.user = jwt.verify(token, jwtSecret, { algorithms: ["HS256"] });
      next();
    } catch {
      return res.status(401).json({ error: "invalid or expired token" });
    }
  };
}

export function createApp(db, jwtSecret) {
  const app = express();
  app.use(cors());
  app.use(express.json());
  app.use(morgan("common"));

  app.use((req, res, next) => {
    const start = Date.now();
    res.on("finish", () => {
      const route = req.route ? req.route.path : req.path;
      const duration = (Date.now() - start) / 1000;
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

  app.post("/auth/register", authRateLimiter, (req, res) => {
    const { email, password } = req.body;
    if (!email || !password || typeof email !== "string" || typeof password !== "string") {
      return res.status(400).json({ error: "email and password are required" });
    }

    db.query("SELECT id FROM users WHERE email = ?", [email], async (err, existing) => {
      try {
        if (err) {
          console.error("user-service DB error:", err);
          return res.status(500).json({ error: "internal error" });
        }
        if (existing.length > 0) {
          return res.status(409).json({ error: "email already registered" });
        }

        const passwordHash = await bcrypt.hash(password, 10);
        db.query(
          "INSERT INTO users (email, password_hash) VALUES (?, ?)",
          [email, passwordHash],
          (insertErr, result) => {
            if (insertErr) {
              console.error("user-service DB error:", insertErr);
              return res.status(500).json({ error: "internal error" });
            }
            return res.status(201).json({ id: result.insertId, email });
          }
        );
      } catch (e) {
        console.error("user-service DB error:", e);
        return res.status(500).json({ error: "internal error" });
      }
    });
  });

  app.post("/auth/login", authRateLimiter, (req, res) => {
    const { email, password } = req.body;
    if (!email || !password || typeof email !== "string" || typeof password !== "string") {
      return res.status(400).json({ error: "email and password are required" });
    }

    db.query("SELECT id, email, password_hash FROM users WHERE email = ?", [email], async (err, rows) => {
      try {
        if (err) {
          console.error("user-service DB error:", err);
          return res.status(500).json({ error: "internal error" });
        }
        if (rows.length === 0) {
          // No such user: still run a compare against a fixed dummy hash so
          // this branch costs about the same as the real-user path below,
          // preventing email enumeration via response timing.
          await bcrypt.compare(password, DUMMY_HASH);
          return res.status(401).json({ error: "invalid email or password" });
        }

        const user = rows[0];
        const valid = await bcrypt.compare(password, user.password_hash);
        if (!valid) {
          return res.status(401).json({ error: "invalid email or password" });
        }

        const token = jwt.sign({ userId: user.id, email: user.email }, jwtSecret, { expiresIn: "1h" });
        return res.status(200).json({ token });
      } catch (e) {
        console.error("user-service DB error:", e);
        return res.status(500).json({ error: "internal error" });
      }
    });
  });

  app.get("/users/me", verifyJwt(jwtSecret), (req, res) => {
    db.query(
      "SELECT id, email, created_at FROM users WHERE id = ?",
      [req.user.userId],
      (err, rows) => {
        if (err) {
          console.error("user-service DB error:", err);
          return res.status(500).json({ error: "internal error" });
        }
        if (rows.length === 0) return res.status(404).json({ error: "user not found" });
        return res.status(200).json(rows[0]);
      }
    );
  });

  return app;
}
