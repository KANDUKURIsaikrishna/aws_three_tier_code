import mysql from "mysql2";
import dotenv from "dotenv";
import { createApp } from "./app.js";

dotenv.config();

// A pool, not a single createConnection -- a single Connection is an
// EventEmitter with no listener for its 'error' event anywhere in this
// codebase, so a dropped connection (RDS failover, idle wait_timeout) was an
// unhandled exception that crashed the whole process. A pool evicts and
// replaces broken connections per-query instead, surfacing the error to that
// query's own callback rather than the process.
const db = mysql.createPool({
  host: process.env.DB_HOST,
  user: process.env.DB_USERNAME,
  password: process.env.DB_PASSWORD,
  port: process.env.DB_PORT || 3306,
  database: process.env.DB_NAME || "catalog_db",
  connectionLimit: 10,
});

const app = createApp(db);
const APP_PORT = process.env.APP_PORT || 3000;
app.listen(APP_PORT, () => {
  console.log(`catalog-service listening on port ${APP_PORT}.`);
});
