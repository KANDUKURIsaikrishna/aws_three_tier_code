# Application UML

UML of the **application layer** only (not infrastructure — see `ARCHITECTURE_DIAGRAM_PROMPT.md`/`CICD_DIAGRAM_PROMPT.md` for that). Rendered with Mermaid, native in this file on GitHub/GitLab/most Markdown viewers. Verified against real source as of 2026-08-14: `services/{api-gateway,catalog-service,user-service,order-service,notification-service}` (flat single-file Express apps — one `app.js` factory + `index.js` entrypoint each, no `routes/`/`controllers/`/`models/` subdirs, no ORM, raw `mysql2` SQL) and `client/src/` (React, react-router-dom v6).

---

## 1. Component diagram — services

```mermaid
flowchart LR
  Browser(["Browser — React SPA"])
  GW["api-gateway\n«reverse proxy», no DB"]
  US["user-service"]
  CS["catalog-service"]
  OS["order-service"]
  NS["notification-service"]
  UDB[("user_db")]
  CDB[("catalog_db")]
  ODB[("order_db")]
  NDB[("notification_db")]

  Browser -- "HTTPS" --> GW
  GW -- "/auth/* — no auth" --> US
  GW -- "/users/* — verifyJwt" --> US
  GW -- "GET /books — public\nwrites — verifyJwt" --> CS
  GW -- "/cart/*, /orders/* — verifyJwt\ninjects x-user-id" --> OS
  OS -- "fetch POST /notify\nfire-and-forget, 2s timeout" --> NS
  US --> UDB
  CS --> CDB
  OS --> ODB
  NS --> NDB
```

**Only real inter-service call is `order-service → notification-service`.** `catalog-service` never talks to anyone; `order-service` never calls `catalog-service` (no server-side book/price validation — the `orders` table doesn't even store price). Every service exposes `GET /health` and `GET /metrics` (prom-client) — omitted above for clarity.

---

## 2. Class diagram — service interfaces

Not object classes (there are none — every service is stateless functions over `mysql2` pools). This models each service as its public HTTP interface, `«service»` stereotype, methods = routes.

```mermaid
classDiagram
  class ApiGateway {
    <<service>>
    +GET /health
    +GET /metrics
    +ANY /auth/* : no auth → user-service
    +GET /books : public → catalog-service
    +WRITE /books/* : verifyJwt → catalog-service
    +ANY /users/* : verifyJwt → user-service
    +ANY /cart/*, /orders/* : verifyJwt → order-service
    -verifyJwt(jwtSecret) x-user-id
    -protectMutations(jwtSecret)
  }
  class UserService {
    <<service>>
    +POST /auth/register(email, password) User
    +POST /auth/login(email, password) JwtToken
    +GET /users/me() User
    -verifyJwt(jwtSecret)
    -DUMMY_HASH bcrypt
  }
  class CatalogService {
    <<service>>
    +GET /books() Book[]
    +GET /books/:id() Book
    +POST /books(title, desc, price, cover) Book
    +PUT /books/:id(title, desc, price, cover) Book
    +DELETE /books/:id()
  }
  class OrderService {
    <<service>>
    +GET /cart() CartItem[]
    +POST /cart(book_id, quantity) CartItem
    +DELETE /cart/:bookId()
    +POST /orders/checkout() Order[]
    +POST /orders(book_id, quantity) Order
    +GET /orders() Order[]
    +GET /orders/:id() Order
    -requireUserId() x-user-id header
    -dispatchNotification(orderId)
  }
  class NotificationService {
    <<service>>
    +POST /notify(order_id, channel) NotificationLog
  }
  ApiGateway ..> UserService : proxies
  ApiGateway ..> CatalogService : proxies
  ApiGateway ..> OrderService : proxies
  OrderService ..> NotificationService : fetch, fire-and-forget
```

**JWT is verified in exactly two places**: `ApiGateway.verifyJwt` (every proxied call) and `UserService.verifyJwt` on `GET /users/me` only (redundant, self-contained re-check). `CatalogService`, `OrderService`, and `NotificationService` never verify a token themselves — `OrderService` trusts the `x-user-id` header the gateway injects; `CatalogService` has zero identity awareness at all, relying entirely on the gateway to gate writes.

---

## 3. Entity-relationship diagram — data model

Four **separate physical databases** (`catalog_db`, `user_db`, `order_db`, `notification_db`), one per service, on the same shared RDS instance. No SQL `FOREIGN KEY` constraints exist anywhere — `user_id`/`book_id`/`order_id` are plain `INT` columns, cross-database references enforced only in application code. Relationships below are logical, not physical.

```mermaid
erDiagram
  BOOKS {
    int id PK
    varchar title
    text desc
    decimal price
    varchar cover
  }
  USERS {
    int id PK
    varchar email UK
    varchar password_hash
    timestamp created_at
  }
  CART_ITEMS {
    int id PK
    int user_id "soft ref -> USERS.id"
    int book_id "soft ref -> BOOKS.id"
    int quantity
    timestamp created_at
  }
  ORDERS {
    int id PK
    int user_id "soft ref -> USERS.id"
    int book_id "soft ref -> BOOKS.id"
    int quantity
    varchar status "default 'pending'"
    timestamp created_at
  }
  NOTIFICATION_LOG {
    int id PK
    int order_id "soft ref -> ORDERS.id"
    varchar channel
    varchar status
    timestamp sent_at
  }

  USERS ||--o{ CART_ITEMS : "owns (app-level only)"
  USERS ||--o{ ORDERS : "owns (app-level only)"
  BOOKS ||--o{ CART_ITEMS : "referenced by (app-level only)"
  BOOKS ||--o{ ORDERS : "referenced by (app-level only)"
  ORDERS ||--o{ NOTIFICATION_LOG : "triggers (app-level only)"
```

`CART_ITEMS` has a real DB-level constraint worth noting even though it's not a FK: `UNIQUE(user_id, book_id)`, which is what makes `POST /cart`'s `INSERT ... ON DUPLICATE KEY UPDATE quantity=?` behave as an upsert. `ORDERS` doesn't store `price` — the checkout flow never looks it up, so an order's value can only be reconstructed by joining back to `BOOKS.price` at read time (which is exactly what the frontend's `joinWithBooks.js` does).

---

## 4. Sequence — register &amp; login

```mermaid
sequenceDiagram
  participant FE as Frontend (Login.jsx)
  participant GW as api-gateway
  participant US as user-service
  participant DB as user_db

  FE->>GW: POST /auth/login {email, password}
  Note over GW: /auth/* has no verifyJwt
  GW->>US: proxy POST /auth/login
  US->>DB: SELECT id,email,password_hash WHERE email=?
  DB-->>US: row | none
  alt no matching row
    US->>US: bcrypt.compare(password, DUMMY_HASH)
    Note right of US: timing-attack defense —\nsame cost whether email exists or not
    US-->>GW: 401 invalid credentials
  else row found
    US->>US: bcrypt.compare(password, password_hash)
    alt mismatch
      US-->>GW: 401 invalid credentials
    else match
      US->>US: jwt.sign({userId, email}, JWT_SECRET, exp 1h)
      US-->>GW: 200 {token}
    end
  end
  GW-->>FE: 200 {token} | 401
  FE->>FE: localStorage["bookstore_token"] = token
  FE->>FE: navigate("/")
```

---

## 5. Sequence — checkout

```mermaid
sequenceDiagram
  participant FE as Frontend (Checkout.jsx)
  participant GW as api-gateway
  participant OS as order-service
  participant ODB as order_db
  participant NS as notification-service
  participant NDB as notification_db

  FE->>GW: POST /orders/checkout  (Bearer JWT)
  GW->>GW: verifyJwt → x-user-id header
  GW->>OS: proxy POST /orders/checkout
  OS->>ODB: SELECT cart_items WHERE user_id=?
  alt cart empty
    OS-->>GW: 400 cart is empty
    GW-->>FE: 400
  else has items
    OS->>ODB: BEGIN TRANSACTION
    loop each cart item
      OS->>ODB: INSERT INTO orders (..., status='pending')
    end
    OS->>ODB: DELETE cart_items WHERE user_id=?
    OS->>ODB: COMMIT
    OS-->>GW: 201 [orders]
    GW-->>FE: 201 [orders]
    FE->>FE: navigate("/orders")
    par fire-and-forget — after the 201 already sent
      OS->>NS: fetch POST /notify {order_id, channel:"email"}\n(2s timeout, native fetch, not axios)
      NS->>NDB: INSERT notification_log (..., status='sent')
      NS-->>OS: 201 | timeout/error
      Note right of OS: failure only increments\nnotification_dispatch_failures_total —\nnever surfaces to the client, never rolls back the order
    end
  end
```

`order-service` never calls `catalog-service` in this flow — no server-side price/stock validation happens anywhere in checkout.

---

## 6. Sequence — authenticated write (identity boundary)

Shows why `catalog-service` needs zero code changes to stay secure: the gateway is the entire enforcement point.

```mermaid
sequenceDiagram
  participant FE as Frontend
  participant GW as api-gateway
  participant CS as catalog-service
  participant CDB as catalog_db

  FE->>GW: POST /books  (Bearer JWT)
  GW->>GW: protectMutations → verifyJwt
  alt missing/invalid/expired token
    GW-->>FE: 401 (catalog-service never reached)
  else valid
    GW->>CS: proxy POST /books  (no identity check inside)
    CS->>CDB: INSERT INTO books (title, desc, price, cover)
    CS-->>GW: 201 Book
    GW-->>FE: 201 Book
  end
```

---

## 7. Frontend component diagram

```mermaid
flowchart TD
  App["App.js — react-router-dom v6"]
  Auth["AuthContext — token/email state\nlocalStorage: bookstore_token, bookstore_email"]
  Api["api.js — axios instance\n+ attachAuthHeader / handleAuthError interceptors"]
  PR["ProtectedRoute — redirects to /login"]
  Nav["Nav.jsx"]

  Books["Books.jsx  /"]
  Add["Add.jsx  /add 🔒"]
  Update["Update.jsx  /update/:id 🔒"]
  Login["Login.jsx  /login"]
  Register["Register.jsx  /register"]
  Cart["Cart.jsx  /cart 🔒"]
  Checkout["Checkout.jsx  /checkout 🔒"]
  Orders["Orders.jsx  /orders 🔒"]
  Join["joinWithBooks.js — client-side join\ncart/order rows + book rows"]

  App --> Nav
  App --> Books
  App --> Add
  App --> Update
  App --> Login
  App --> Register
  App --> Cart
  App --> Checkout
  App --> Orders
  Add -.wrapped by.-> PR
  Update -.wrapped by.-> PR
  Cart -.wrapped by.-> PR
  Checkout -.wrapped by.-> PR
  Orders -.wrapped by.-> PR
  PR --> Auth
  Login --> Auth
  Register --> Auth
  Nav --> Auth
  Books --> Api
  Add --> Api
  Update --> Api
  Cart --> Api
  Checkout --> Api
  Orders --> Api
  Auth --> Api
  Cart --> Join
  Orders --> Join
```

`🔒` = wrapped in `ProtectedRoute`, redirects to `/login` client-side if `AuthContext.isAuthenticated` is false — this is UX only, not a security boundary; the real boundary is `api-gateway`'s `verifyJwt`.

---

## Facts worth remembering when reading these diagrams

- **No ORM anywhere.** Every service uses raw SQL via `mysql2` (callback-style, except `order-service`'s checkout endpoint, which uses `.promise()` for the transaction). No Sequelize/TypeORM/Prisma.
- **No `axios` in any backend service.** `order-service → notification-service` uses native `fetch` with `AbortSignal.timeout(2000)`. `axios` is frontend-only.
- **JWT claims are minimal:** `{ userId, email, iat, exp }`, HS256, 1h expiry. `JWT_SECRET` is shared between `user-service` (sign + verify) and `api-gateway` (verify only), via a Kubernetes `ExternalSecret` synced from AWS Secrets Manager.
- **`api-gateway` deliberately has no `express.json()`** — parsing the body would consume the stream `http-proxy-middleware` needs to forward it untouched.
- **Registration does not log the user in** — `POST /auth/register` returns `{id, email}`, no token; the frontend redirects to `/login` afterward.
- **The alternate `POST /orders` endpoint (single-item, bypasses cart) exists in `order-service` but no frontend page calls it** — dead code from the UI's perspective, still live and reachable via the gateway.
- **Test runner is `vitest` + `supertest`** in every service (not `jest`, despite `jest`-style syntax being common elsewhere in the JS ecosystem).

## Related

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — narrative infra + app overview
- [`ARCHITECTURE_DIAGRAM_PROMPT.md`](ARCHITECTURE_DIAGRAM_PROMPT.md) — AWS infrastructure diagram prompt
- [`CICD_DIAGRAM_PROMPT.md`](CICD_DIAGRAM_PROMPT.md) — CI/CD pipeline diagram prompt
- [`KUBERNETES.md`](KUBERNETES.md) — how these services are deployed and networked
