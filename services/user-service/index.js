import mysql from "mysql2";
import dotenv from "dotenv";
import { createApp } from "./app.js";

dotenv.config();

// A pool, not a single createConnection -- see catalog-service/index.js's
// comment for why (unhandled 'error' event on a bare Connection crashes the
// process; a pool evicts and replaces broken connections per-query instead).
const db = mysql.createPool({
  host: process.env.DB_HOST,
  user: process.env.DB_USERNAME,
  password: process.env.DB_PASSWORD,
  port: process.env.DB_PORT || 3306,
  database: process.env.DB_NAME || "user_db",
  connectionLimit: 10,
});

const app = createApp(db, process.env.JWT_SECRET);
const APP_PORT = process.env.APP_PORT || 3000;
app.listen(APP_PORT, () => {
  console.log(`user-service listening on port ${APP_PORT}.`);
});
