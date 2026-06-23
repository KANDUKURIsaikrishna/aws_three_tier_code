import express from "express";
import cors from "cors";
import morgan from "morgan";

export function createApp(db) {
  const app = express();
  app.use(cors());
  app.use(express.json());
  app.use(morgan("common"));

  app.get("/", (_req, res) => {
    res.json("hello");
  });

  app.get("/books", (_req, res) => {
    db.query("SELECT * FROM books", (err, data) => {
      if (err) { console.log(err); return res.json(err); }
      return res.json(data);
    });
  });

  app.post("/books", (req, res) => {
    const q = "INSERT INTO books(`title`, `desc`, `price`, `cover`) VALUES (?)";
    const values = [req.body.title, req.body.desc, req.body.price, req.body.cover];
    db.query(q, [values], (err, data) => {
      if (err) return res.send(err);
      return res.json(data);
    });
  });

  app.delete("/books/:id", (req, res) => {
    db.query(" DELETE FROM books WHERE id = ? ", [req.params.id], (err, data) => {
      if (err) return res.send(err);
      return res.json(data);
    });
  });

  app.put("/books/:id", (req, res) => {
    const q = "UPDATE books SET `title`= ?, `desc`= ?, `price`= ?, `cover`= ? WHERE id = ?";
    const values = [req.body.title, req.body.desc, req.body.price, req.body.cover];
    db.query(q, [...values, req.params.id], (err, data) => {
      if (err) return res.send(err);
      return res.json(data);
    });
  });

  return app;
}
