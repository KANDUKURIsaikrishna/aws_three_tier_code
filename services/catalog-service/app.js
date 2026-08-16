import express from "express";
import helmet from "helmet";
import morgan from "morgan";
import { Registry, collectDefaultMetrics, Counter, Histogram } from "prom-client";

const SERVICE_NAME = "catalog-service";

const registry = new Registry();
registry.setDefaultLabels({ service: SERVICE_NAME });
collectDefaultMetrics({ register: registry });

const httpRequests = new Counter({
  name: "http_requests_total",
  help: "Total HTTP requests",
  labelNames: ["method", "route", "status"],
  registers: [registry],
});

const httpDuration = new Histogram({
  name: "http_request_duration_seconds",
  help: "HTTP request duration in seconds",
  labelNames: ["method", "route", "status"],
  buckets: [0.01, 0.05, 0.1, 0.5, 1, 2],
  registers: [registry],
});

export function createApp(db) {
  const app = express();
  // Behind nginx-ingress/ALB -- without this, req.ip (and anything keyed on
  // it) sees the proxy's address instead of the real client's.
  app.set("trust proxy", 1);
  app.use(helmet());
  // No cors() here: this service is only ever called server-to-server by
  // api-gateway (enforced at the network layer too, see
  // k8s/services/catalog-service/base/network-policy.yaml) -- it has no
  // legitimate browser-facing origin to allow.
  app.use(express.json());
  app.use(morgan("common"));

  app.use((req, res, next) => {
    const start = Date.now();
    res.on("finish", () => {
      const route = req.route ? req.route.path : req.path;
      const duration = (Date.now() - start) / 1000;
      httpRequests.labels(req.method, route, String(res.statusCode)).inc();
      httpDuration.labels(req.method, route, String(res.statusCode)).observe(duration);
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

  // Defense in depth: api-gateway already blocks non-admin edits/deletes
  // (requireAdminForDestructiveMutation) and sets x-user-role after
  // verifying the JWT itself -- this is the same "trust an internal header
  // set by the gateway" pattern order-service already uses for x-user-id,
  // applied here so catalog-service isn't relying solely on the
  // gateway/NetworkPolicy boundary to enforce it. Deliberately NOT applied
  // to POST /books -- adding a new book only requires being logged in
  // (gateway's protectMutations already covers that), only editing/deleting
  // an existing book requires admin.
  function requireAdminForDestructiveMutation(req, res, next) {
    if (req.headers["x-user-role"] !== "admin") {
      return res.status(403).json({ error: "admin role required" });
    }
    next();
  }

  app.get("/books", (_req, res) => {
    db.query("SELECT * FROM books", (err, data) => {
      if (err) { console.log(err); return res.status(500).json({ error: "Failed to fetch books" }); }
      return res.json(data);
    });
  });

  app.get("/books/:id", (req, res) => {
    db.query("SELECT * FROM books WHERE id = ?", [req.params.id], (err, data) => {
      if (err) { console.log(err); return res.status(500).json({ error: "Failed to fetch book" }); }
      if (data.length === 0) return res.status(404).json({ error: "Book not found" });
      return res.json(data[0]);
    });
  });

  app.post("/books", (req, res) => {
    const q = "INSERT INTO books(`title`, `desc`, `price`, `cover`) VALUES (?)";
    const values = [req.body.title, req.body.desc, req.body.price, req.body.cover];
    db.query(q, [values], (err, data) => {
      if (err) { console.log(err); return res.status(500).json({ error: "Failed to create book" }); }
      return res.json(data);
    });
  });

  app.delete("/books/:id", requireAdminForDestructiveMutation, (req, res) => {
    db.query(" DELETE FROM books WHERE id = ? ", [req.params.id], (err, data) => {
      if (err) { console.log(err); return res.status(500).json({ error: "Failed to delete book" }); }
      return res.json(data);
    });
  });

  app.put("/books/:id", requireAdminForDestructiveMutation, (req, res) => {
    const q = "UPDATE books SET `title`= ?, `desc`= ?, `price`= ?, `cover`= ? WHERE id = ?";
    const values = [req.body.title, req.body.desc, req.body.price, req.body.cover];
    db.query(q, [...values, req.params.id], (err, data) => {
      if (err) { console.log(err); return res.status(500).json({ error: "Failed to update book" }); }
      return res.json(data);
    });
  });

  return app;
}
