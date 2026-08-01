import dotenv from "dotenv";
import { createApp } from "./app.js";

dotenv.config();

const targets = {
  catalog: process.env.CATALOG_SERVICE_URL || "http://catalog-service.catalog.svc.cluster.local",
  user: process.env.USER_SERVICE_URL || "http://user-service.user.svc.cluster.local",
  order: process.env.ORDER_SERVICE_URL || "http://order-service.order.svc.cluster.local",
};

const app = createApp(process.env.JWT_SECRET, targets);
const APP_PORT = process.env.APP_PORT || 3000;
app.listen(APP_PORT, () => {
  console.log(`api-gateway listening on port ${APP_PORT}.`);
});
