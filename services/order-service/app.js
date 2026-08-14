import express from "express";
import helmet from "helmet";
import morgan from "morgan";
import { Registry, collectDefaultMetrics, Counter, Histogram } from "prom-client";

const SERVICE_NAME = "order-service";

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

const notificationDispatchFailures = new Counter({
  name: "notification_dispatch_failures_total",
  help: "Count of failed fire-and-forget calls to notification-service",
  labelNames: ["service"],
  registers: [registry],
});

function requireUserId(req, res, next) {
  const userId = Number(req.headers["x-user-id"]);
  if (!userId || Number.isNaN(userId)) {
    return res.status(401).json({ error: "missing X-User-Id header" });
  }
  req.userId = userId;
  next();
}

// Fire-and-forget: called after the response is already sent. Any error here
// is caught and counted, never surfaced to the HTTP caller.
function dispatchNotification(notifyFn, orderId) {
  notifyFn(orderId).catch(() => {
    notificationDispatchFailures.labels(SERVICE_NAME).inc();
  });
}

export function createApp(db, notifyFn) {
  const app = express();
  // Behind nginx-ingress/ALB -- without this, req.ip (and anything keyed on
  // it) sees the proxy's address instead of the real client's.
  app.set("trust proxy", 1);
  app.use(helmet());
  // No cors() here: this service is only ever called server-to-server by
  // api-gateway (enforced at the network layer too, see
  // k8s/services/order-service/base/network-policy.yaml) -- it has no
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

  app.get("/cart", requireUserId, (req, res) => {
    db.query(
      "SELECT id, book_id, quantity FROM cart_items WHERE user_id = ?",
      [req.userId],
      (err, rows) => {
        if (err) {
          console.error("order-service DB error:", err);
          return res.status(500).json({ error: "internal error" });
        }
        return res.status(200).json(rows);
      }
    );
  });

  app.post("/cart", requireUserId, (req, res) => {
    const { book_id, quantity } = req.body;
    if (
      !book_id ||
      !quantity ||
      typeof book_id !== "number" ||
      typeof quantity !== "number" ||
      !Number.isInteger(book_id) ||
      book_id <= 0 ||
      !Number.isInteger(quantity) ||
      quantity <= 0
    ) {
      return res.status(400).json({ error: "book_id and quantity are required" });
    }

    db.query(
      `INSERT INTO cart_items (user_id, book_id, quantity)
       VALUES (?, ?, ?)
       ON DUPLICATE KEY UPDATE quantity = ?`,
      [req.userId, book_id, quantity, quantity],
      (err) => {
        if (err) {
          console.error("order-service DB error:", err);
          return res.status(500).json({ error: "internal error" });
        }
        return res.status(200).json({ book_id, quantity });
      }
    );
  });

  app.delete("/cart/:bookId", requireUserId, (req, res) => {
    db.query(
      "DELETE FROM cart_items WHERE user_id = ? AND book_id = ?",
      [req.userId, req.params.bookId],
      (err, result) => {
        if (err) {
          console.error("order-service DB error:", err);
          return res.status(500).json({ error: "internal error" });
        }
        return res.status(200).json(result);
      }
    );
  });

  // A real transaction, not the original per-item loop with no rollback:
  // that version left previously-succeeded inserts committed if a later
  // item's insert failed, and never cleared the cart on that path either
  // (a phantom order the user never got a response for, plus a stale cart
  // that could produce a duplicate order on retry). beginTransaction/
  // commit/rollback via db.promise() keeps every insert + the cart delete
  // atomic: any failure rolls back the whole checkout, cart included.
  const promiseDb = db.promise();

  app.post("/orders/checkout", requireUserId, async (req, res) => {
    let connection;
    try {
      const [cartItems] = await promiseDb.query(
        "SELECT book_id, quantity FROM cart_items WHERE user_id = ?",
        [req.userId]
      );
      if (cartItems.length === 0) {
        return res.status(400).json({ error: "cart is empty" });
      }

      connection = await promiseDb.getConnection();
      await connection.beginTransaction();

      const createdOrders = [];
      for (const item of cartItems) {
        const [result] = await connection.query(
          "INSERT INTO orders (user_id, book_id, quantity, status) VALUES (?, ?, ?, 'pending')",
          [req.userId, item.book_id, item.quantity]
        );
        createdOrders.push({
          id: result.insertId,
          book_id: item.book_id,
          quantity: item.quantity,
          status: "pending",
        });
      }
      await connection.query("DELETE FROM cart_items WHERE user_id = ?", [req.userId]);

      await connection.commit();
      res.status(201).json(createdOrders);
      createdOrders.forEach((order) => dispatchNotification(notifyFn, order.id));
    } catch (err) {
      if (connection) {
        await connection.rollback();
      }
      console.error("order-service DB error:", err);
      res.status(500).json({ error: "internal error" });
    } finally {
      if (connection) connection.release();
    }
  });

  app.post("/orders", requireUserId, (req, res) => {
    const { book_id, quantity } = req.body;
    if (
      !book_id ||
      !quantity ||
      typeof book_id !== "number" ||
      typeof quantity !== "number" ||
      !Number.isInteger(book_id) ||
      book_id <= 0 ||
      !Number.isInteger(quantity) ||
      quantity <= 0
    ) {
      return res.status(400).json({ error: "book_id and quantity are required" });
    }

    db.query(
      "INSERT INTO orders (user_id, book_id, quantity, status) VALUES (?, ?, ?, 'pending')",
      [req.userId, book_id, quantity],
      (err, result) => {
        if (err) {
          console.error("order-service DB error:", err);
          return res.status(500).json({ error: "internal error" });
        }
        const order = { id: result.insertId, book_id, quantity, status: "pending" };
        res.status(201).json(order);
        dispatchNotification(notifyFn, order.id);
      }
    );
  });

  app.get("/orders", requireUserId, (req, res) => {
    db.query(
      "SELECT id, book_id, quantity, status FROM orders WHERE user_id = ?",
      [req.userId],
      (err, rows) => {
        if (err) {
          console.error("order-service DB error:", err);
          return res.status(500).json({ error: "internal error" });
        }
        return res.status(200).json(rows);
      }
    );
  });

  app.get("/orders/:id", requireUserId, (req, res) => {
    db.query(
      "SELECT id, book_id, quantity, status FROM orders WHERE id = ? AND user_id = ?",
      [req.params.id, req.userId],
      (err, rows) => {
        if (err) {
          console.error("order-service DB error:", err);
          return res.status(500).json({ error: "internal error" });
        }
        if (rows.length === 0) return res.status(404).json({ error: "order not found" });
        return res.status(200).json(rows[0]);
      }
    );
  });

  return app;
}
