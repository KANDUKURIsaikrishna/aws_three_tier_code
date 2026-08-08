# Frontend Microservices Integration — Design

## Goal

Build the missing React frontend for the microservices platform (login, cart, checkout, order history) and make the frontend's cutover to `api-gateway` real — currently the gateway and all 5 microservices work end-to-end (verified via curl), but the only UI that exists is the old CRUD-only `Books`/`Add`/`Update` pages talking to the old monolith `backend/`, with no way to log in, add to cart, or check out.

## Background

- All 5 microservices are built and live: `catalog-service`, `user-service`, `order-service`, `notification-service`, `api-gateway`. `api-gateway` proxies `/books` (GET public, writes require JWT), `/auth` (public), `/users` (JWT), `/orders` and `/cart` (JWT) to the right backend service.
- `catalog-service`'s `/books` schema (`title`, `desc`, `price`, `cover`) is identical to the old backend's — no field changes needed for `Add`/`Update`.
- `order-service`'s `/cart` and `/orders` store only `book_id` + `quantity` (+ `status` for orders) — no denormalized title/price/cover. The frontend has to cross-reference against `/books` client-side to display anything human-readable. This is correct microservices data ownership, not a bug to route around.
- `user-service`'s `/auth/login` returns a JWT (`expiresIn: "1h"`), no refresh token exists or is planned. `/auth/register` returns `{id, email}`, no token — the client must register then log in separately.
- **The frontend currently points at the old monolith backend.** Two separate `Ingress` objects (`k8s/base/ingress/ingress.yaml` and `k8s/services/api-gateway/base/ingress.yaml`) both currently claim the host `api.bookstore.<domain>` — a real collision, tracked in `FUTURE_IMPROVEMENTS.md` gap #12. This spec's cutover to the gateway requires that collision actually resolved (old rule trimmed), not just documented as a known issue.

## Non-goals

- No payment integration, no shipping address collection — `order-service`'s checkout endpoint takes no body and has no such fields; inventing frontend fields for data the backend doesn't accept would be pure scope creep.
- No refresh-token / silent re-auth. On JWT expiry (1h), the user is logged out and redirected to `/login`. This matches the backend's actual design.
- No retrofit of test coverage for the pre-existing `Books`/`Add`/`Update` pages beyond what's needed to route their write calls through the new shared API client.
- No design-system/UI-framework adoption — stays consistent with the existing plain CSS/SCSS, no-framework style already in `client/src/style.scss`.
- Full `backend/` retirement (deleting the monolith) is explicitly **not** part of this spec — only the one ingress rule collision blocking the gateway is resolved here.

## Architecture

```
client/src/
  api/
    api.js            -- shared axios instance: base URL = gateway, request
                         interceptor attaches Authorization header from
                         localStorage, response interceptor logs out +
                         redirects to /login on any 401
  context/
    AuthContext.jsx   -- token + email state, localStorage-backed, exposes
                         login()/register()/logout()/isAuthenticated
  components/
    Nav.jsx             -- shared header, shown on every route
    ProtectedRoute.jsx  -- redirects to /login if not authenticated
  pages/
    config.js    -- (edit) API_BASE_URL now points at the gateway
    Books.jsx    -- (edit) uses api.js, adds "Add to Cart" button
    Add.jsx      -- (edit) uses api.js (adds auth header)
    Update.jsx   -- (edit) uses api.js (adds auth header)
    Login.jsx      -- new
    Register.jsx   -- new
    Cart.jsx        -- new
    Checkout.jsx    -- new
    Orders.jsx      -- new
  App.js  -- (edit) wraps app in AuthProvider + Nav, adds routes for the
            5 new pages, wraps /cart, /checkout, /orders in ProtectedRoute
```

`config.js`'s `API_BASE_URL` changes from the old backend's URL to the gateway's — since both are reachable at the same hostname (`api.bookstore.<domain>`, the source of the ingress collision), **no CI secret change is expected to be needed**; `API_URL` in GitHub Secrets should already hold this exact hostname. Confirm this during implementation before assuming it needs updating.

## Components

**`api.js`** — one axios instance, used by every page (old and new). Request interceptor reads the token from `localStorage` (key: `bookstore_token`) and sets `Authorization: Bearer <token>` when present; does nothing when absent (GET `/books` stays public). Response interceptor: on `401`, clears `localStorage` and redirects to `/login` — handles both "never logged in" (though `ProtectedRoute` should catch that first) and "token expired mid-session."

**`AuthContext.jsx`** — React Context, initializes from `localStorage` on mount (so a page refresh doesn't log the user out). `login(email, password)` calls `POST /auth/login`, stores the returned token + decodes the email from the JWT payload (or just stores what was passed in — simpler, no need to decode client-side). `register(email, password)` calls `POST /auth/register`, returns success/failure, does **not** log in automatically (no token in the response). `logout()` clears state + `localStorage`.

**`Nav.jsx`** — site title/home link, then either "Login · Register" (logged out) or "`<email>` · Cart · Orders · Logout" (logged in). Rendered once in `App.js`, above the `<Routes>`, so it's present on every page including `Books`.

**`Login.jsx` / `Register.jsx`** — plain forms (email, password inputs), matching the existing `.form` SCSS class already used by `Add.jsx`. Register success routes to `/login` with a brief inline "registered — please log in" message (passed via router state, not a query param). Login success routes to `/`.

**`Cart.jsx`** — on mount, fetches `GET /cart` and `GET /books` in parallel, joins by `book_id` client-side. Renders each line with cover/title/price/quantity (quantity input, on change re-`POST`s `{book_id, quantity}` — the backend's `ON DUPLICATE KEY UPDATE` makes this a safe upsert), a remove button (`DELETE /cart/:bookId`), and a running total computed client-side (`sum(price * quantity)`). "Proceed to checkout" button navigates to `/checkout` (no cart data needs to be passed via router state — `Checkout.jsx` re-fetches).

**`Checkout.jsx`** — re-fetches cart + books (same join as `Cart.jsx` — small enough duplication to keep pages independently understandable, not worth extracting a hook for two call sites), shows a read-only summary + total, and a "Place Order" button that calls `POST /orders/checkout`. On success (`201`, array of created orders), navigates to `/orders`. On `400` ("cart is empty"), shows an inline message and a link back to `/cart` — reachable if the user checks out in two tabs or the cart was cleared elsewhere.

**`Orders.jsx`** — `GET /orders`, joins against `/books` the same way, renders each order's book/quantity/status. No actions (no cancel/edit — not supported server-side).

**`ProtectedRoute.jsx`** — wraps `children`, redirects to `/login` if `!isAuthenticated`, preserving the intended destination isn't necessary here (no deep-linking use case in a demo app — always land on `/` from `Login.jsx` regardless of where the redirect came from, keeping this component trivial).

**`Books.jsx`** (edit) — adds an "Add to Cart" button per book. If logged in: `POST /cart {book_id: book.id, quantity: 1}`, brief inline "added" confirmation. If not logged in: navigate to `/login` instead of attempting the call (avoids a guaranteed 401 round-trip).

## Data flow

```
Login/Register ──> user-service (via gateway /auth)
     │
     ▼ (JWT stored in localStorage)
Books (GET /books, public) ──> catalog-service (via gateway)
     │
     │ "Add to Cart" (requires JWT)
     ▼
Cart (GET/POST/DELETE /cart) ──> order-service (via gateway)
     │  + GET /books for display join
     ▼
Checkout (POST /orders/checkout) ──> order-service
     │  (also fires a best-effort notification per created order —
     │   already implemented server-side, nothing new needed here)
     ▼
Orders (GET /orders) ──> order-service
     + GET /books for display join
```

## Error handling

Inline, plain-text error messages under the relevant form/section — consistent with the app's existing minimal style (no toast/modal library introduced):

| Case | Handling |
|---|---|
| Register: `409` email taken | "email already registered" |
| Register: `400` bad input | "email and password are required" |
| Login: `401` | "invalid email or password" |
| Any request: `401` mid-session (expired token) | Global: clear token, redirect to `/login` — no page-level handling needed |
| Cart/checkout/orders: `400`/`500` | Generic inline "something went wrong, try again" |
| Checkout: cart empty (`400`) | "your cart is empty" + link to `/cart` |
| Cart/Orders join: `book_id` not found in `/books` (deleted book) | Render the line with `book_id` shown, no title/cover — doesn't crash the page |

## Testing

- **New unit tests** (`vitest`, matching the pattern already used in `services/*`): `AuthContext` (login/register/logout state transitions, localStorage persistence across a simulated remount), the `api.js` interceptors (auth header attached when token present, 401 triggers logout+redirect), and the cart/orders book-join helper (the one piece of nontrivial client logic, and the one most likely to have an edge-case bug — e.g. the "book was deleted" case above).
- UI rendering and the full click-through flow (register → login → browse → add to cart → checkout → see order) verified manually in the browser against the real cluster, consistent with how the existing pages have always been checked — this project has no frontend E2E test infra, and building one is out of scope here.
- No changes to `services/*`'s own test suites — this spec is frontend-only plus one Kubernetes manifest edit (the ingress collision fix).

## Infra change required for this to work

`k8s/base/ingress/ingress.yaml`'s `api.bookstore.<domain>` host rule (routing to the old `backend-service`) gets removed, leaving `k8s/services/api-gateway/base/ingress.yaml` as the sole owner of that host. The old backend's `bookstore.b17facebook.xyz` (frontend-serving) rule is untouched — this only removes the `api.` subdomain rule, since the frontend static assets still need to be served from somewhere and `backend/` itself isn't being retired in this spec. This is a small, targeted edit, not the full monolith retirement described in `docs/superpowers/plans/2026-08-01-api-gateway.md` Task 9.

## Related

- `services/api-gateway/app.js` — the JWT/proxy logic this frontend integrates with
- `services/user-service/app.js`, `services/order-service/app.js` — exact endpoint contracts used above
- `docs/FUTURE_IMPROVEMENTS.md` gap #12 — the ingress collision this spec resolves
- `docs/KUBERNETES.md` — api-gateway ingress details
