import express from "express";
import helmet from "helmet";
import morgan from "morgan";
import bcrypt from "bcryptjs";
import jwt from "jsonwebtoken";
import crypto from "node:crypto";
import rateLimit from "express-rate-limit";
import { Registry, collectDefaultMetrics, Counter, Histogram } from "prom-client";

const SERVICE_NAME = "user-service";

// ── Short-lived access token + refresh token ────────────────────────────────
// A bare 1h JWT with no revocation mechanism used to be the whole scheme --
// a stolen token stayed valid for the full hour no matter what. Now: the
// access token (still a JWT, still what api-gateway/user-service verify on
// every request) is short-lived, and a separate, opaque refresh token
// (random bytes, never a JWT -- it has no need to be self-describing, it's
// always looked up against the DB) is what actually lets a session keep
// working past that. Only the refresh token's SHA-256 hash is ever stored
// (same principle as password hashing -- a stolen DB row isn't a usable
// credential on its own). Revoking a refresh token (POST /auth/logout) cuts
// off new access tokens immediately; the exposure window for an already-
// stolen access token shrinks from 1h to ACCESS_TOKEN_TTL. Refresh itself
// rotates the token (old one revoked, new one issued) so a refresh token
// can only ever be used once before being replaced -- a stolen-but-unused
// one becomes worthless the moment the real client refreshes first.
const ACCESS_TOKEN_TTL = "15m";
const REFRESH_TOKEN_TTL_MS = 7 * 24 * 60 * 60 * 1000; // 7 days

function hashToken(token) {
  return crypto.createHash("sha256").update(token).digest("hex");
}

function generateRefreshToken() {
  return crypto.randomBytes(48).toString("hex");
}

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

// /auth/refresh is called automatically by the frontend, often across
// multiple open tabs -- a materially different usage pattern than a human
// typing a password, so it gets its own, looser limit rather than sharing
// authRateLimiter's 20/15min (which real background refresh traffic could
// hit on its own). Also covers /auth/logout, called far less often.
const refreshRateLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: 60,
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
  // Behind nginx-ingress/ALB -- without this, req.ip (and anything keyed on
  // it, e.g. authRateLimiter above) sees the proxy's address instead of the
  // real client's, silently breaking per-client rate limiting.
  app.set("trust proxy", 1);
  app.use(helmet());
  // No cors() here: this service is only ever called server-to-server by
  // api-gateway (enforced at the network layer too, see
  // k8s/services/user-service/base/network-policy.yaml) -- it has no
  // legitimate browser-facing origin to allow.
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

        // The very first account ever created becomes admin automatically --
        // this is what actually gates catalog mutations (see api-gateway's
        // requireAdminForMutation), so it has to happen here, atomically with
        // the row that will hold it, not as a separate promotion step.
        db.query("SELECT COUNT(*) AS count FROM users", async (countErr, countRows) => {
          if (countErr) {
            console.error("user-service DB error:", countErr);
            return res.status(500).json({ error: "internal error" });
          }
          const role = countRows[0].count === 0 ? "admin" : "customer";
          const passwordHash = await bcrypt.hash(password, 10);
          db.query(
            "INSERT INTO users (email, password_hash, role) VALUES (?, ?, ?)",
            [email, passwordHash, role],
            (insertErr, result) => {
              if (insertErr) {
                console.error("user-service DB error:", insertErr);
                return res.status(500).json({ error: "internal error" });
              }
              return res.status(201).json({ id: result.insertId, email, role });
            }
          );
        });
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

    db.query("SELECT id, email, password_hash, role FROM users WHERE email = ?", [email], async (err, rows) => {
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

        const token = jwt.sign({ userId: user.id, email: user.email, role: user.role }, jwtSecret, {
          expiresIn: ACCESS_TOKEN_TTL,
        });
        const refreshToken = generateRefreshToken();
        db.query(
          "INSERT INTO refresh_tokens (user_id, token_hash, expires_at) VALUES (?, ?, ?)",
          [user.id, hashToken(refreshToken), new Date(Date.now() + REFRESH_TOKEN_TTL_MS)],
          (rtErr) => {
            if (rtErr) {
              console.error("user-service DB error:", rtErr);
              return res.status(500).json({ error: "internal error" });
            }
            return res.status(200).json({ token, refreshToken, role: user.role });
          }
        );
      } catch (e) {
        console.error("user-service DB error:", e);
        return res.status(500).json({ error: "internal error" });
      }
    });
  });

  app.post("/auth/refresh", refreshRateLimiter, (req, res) => {
    const { refreshToken } = req.body;
    if (!refreshToken || typeof refreshToken !== "string") {
      return res.status(400).json({ error: "refreshToken is required" });
    }

    db.query(
      "SELECT id, user_id FROM refresh_tokens WHERE token_hash = ? AND revoked_at IS NULL AND expires_at > NOW()",
      [hashToken(refreshToken)],
      (err, rows) => {
        if (err) {
          console.error("user-service DB error:", err);
          return res.status(500).json({ error: "internal error" });
        }
        if (rows.length === 0) {
          return res.status(401).json({ error: "invalid or expired refresh token" });
        }
        const existing = rows[0];

        db.query("SELECT id, email, role FROM users WHERE id = ?", [existing.user_id], (userErr, userRows) => {
          if (userErr) {
            console.error("user-service DB error:", userErr);
            return res.status(500).json({ error: "internal error" });
          }
          // The user row backing this refresh token is gone (deleted
          // account) -- treat exactly like an invalid token, don't leak
          // that the token itself was well-formed.
          if (userRows.length === 0) {
            return res.status(401).json({ error: "invalid or expired refresh token" });
          }
          const user = userRows[0];

          // Rotate: revoke the token that was just used, issue a fresh one.
          // A stolen-but-not-yet-used refresh token is now worthless the
          // instant the real client refreshes first.
          const newRefreshToken = generateRefreshToken();
          db.query("UPDATE refresh_tokens SET revoked_at = NOW() WHERE id = ?", [existing.id], (revokeErr) => {
            if (revokeErr) {
              console.error("user-service DB error:", revokeErr);
              return res.status(500).json({ error: "internal error" });
            }
            db.query(
              "INSERT INTO refresh_tokens (user_id, token_hash, expires_at) VALUES (?, ?, ?)",
              [user.id, hashToken(newRefreshToken), new Date(Date.now() + REFRESH_TOKEN_TTL_MS)],
              (insertErr) => {
                if (insertErr) {
                  console.error("user-service DB error:", insertErr);
                  return res.status(500).json({ error: "internal error" });
                }
                const newAccessToken = jwt.sign({ userId: user.id, email: user.email, role: user.role }, jwtSecret, {
                  expiresIn: ACCESS_TOKEN_TTL,
                });
                return res.status(200).json({ token: newAccessToken, refreshToken: newRefreshToken, role: user.role });
              }
            );
          });
        });
      }
    );
  });

  app.post("/auth/logout", refreshRateLimiter, (req, res) => {
    const { refreshToken } = req.body;
    // Nothing to revoke, but logout is still "successful" from the client's
    // perspective either way -- don't error on an already-cleared session.
    if (!refreshToken || typeof refreshToken !== "string") {
      return res.status(200).json({ success: true });
    }

    db.query(
      "UPDATE refresh_tokens SET revoked_at = NOW() WHERE token_hash = ? AND revoked_at IS NULL",
      [hashToken(refreshToken)],
      (err) => {
        if (err) {
          console.error("user-service DB error:", err);
          return res.status(500).json({ error: "internal error" });
        }
        // Always 200, whether or not a matching row existed -- don't leak
        // whether a given refresh token was ever valid.
        return res.status(200).json({ success: true });
      }
    );
  });

  app.get("/users/me", verifyJwt(jwtSecret), (req, res) => {
    db.query(
      "SELECT id, email, role, created_at FROM users WHERE id = ?",
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
