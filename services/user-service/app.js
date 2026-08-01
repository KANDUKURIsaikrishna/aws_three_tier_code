import express from "express";
import cors from "cors";
import morgan from "morgan";
import bcrypt from "bcryptjs";
import jwt from "jsonwebtoken";
import { Registry, collectDefaultMetrics, Counter, Histogram } from "prom-client";

const SERVICE_NAME = "user-service";

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
      req.user = jwt.verify(token, jwtSecret);
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

  app.post("/auth/register", (req, res) => {
    const { email, password } = req.body;
    if (!email || !password) {
      return res.status(400).json({ error: "email and password are required" });
    }

    db.query("SELECT id FROM users WHERE email = ?", [email], (err, existing) => {
      if (err) return res.status(500).json({ error: "internal error" });
      if (existing.length > 0) {
        return res.status(409).json({ error: "email already registered" });
      }

      const passwordHash = bcrypt.hashSync(password, 10);
      db.query(
        "INSERT INTO users (email, password_hash) VALUES (?, ?)",
        [email, passwordHash],
        (insertErr, result) => {
          if (insertErr) return res.status(500).json({ error: "internal error" });
          return res.status(201).json({ id: result.insertId, email });
        }
      );
    });
  });

  app.post("/auth/login", (req, res) => {
    const { email, password } = req.body;
    if (!email || !password) {
      return res.status(400).json({ error: "email and password are required" });
    }

    db.query("SELECT id, email, password_hash FROM users WHERE email = ?", [email], (err, rows) => {
      if (err) return res.status(500).json({ error: "internal error" });
      if (rows.length === 0) {
        return res.status(401).json({ error: "invalid email or password" });
      }

      const user = rows[0];
      const valid = bcrypt.compareSync(password, user.password_hash);
      if (!valid) {
        return res.status(401).json({ error: "invalid email or password" });
      }

      const token = jwt.sign({ userId: user.id, email: user.email }, jwtSecret, { expiresIn: "1h" });
      return res.status(200).json({ token });
    });
  });

  app.get("/users/me", verifyJwt(jwtSecret), (req, res) => {
    db.query(
      "SELECT id, email, created_at FROM users WHERE id = ?",
      [req.user.userId],
      (err, rows) => {
        if (err) return res.status(500).json({ error: "internal error" });
        if (rows.length === 0) return res.status(404).json({ error: "user not found" });
        return res.status(200).json(rows[0]);
      }
    );
  });

  return app;
}
