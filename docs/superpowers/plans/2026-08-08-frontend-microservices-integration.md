# Frontend Microservices Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the missing login/cart/checkout/order-history UI and make the frontend's cutover to `api-gateway` real, so the microservices platform (already fully working server-side) is actually usable from the browser.

**Architecture:** A shared `api.js` axios client (auth header + 401-redirect interceptors) and a `AuthContext` (localStorage-backed) get added alongside 5 new pages (`Login`, `Register`, `Cart`, `Checkout`, `Orders`) and 2 new components (`Nav`, `ProtectedRoute`). The 3 existing pages (`Books`, `Add`, `Update`) get switched from raw `axios` to the shared client so their writes carry the JWT the gateway now requires. One Kubernetes manifest changes to resolve the `api.bookstore.<domain>` ingress host collision that's been blocking the gateway from reliably serving traffic.

**Tech Stack:** React 18 (Create React App), react-router-dom v6, axios, Jest + `@testing-library/react` (CRA's built-in test runner — **not** vitest; vitest is only used in `services/*`, the frontend has always used CRA's Jest setup via `react-scripts test`).

---

## Pre-flight: what this plan touches vs. leaves alone

- **Modifies:** `client/src/` (new files under `api/`, `context/`, `components/`, `utils/`, `pages/`; edits to `App.js`, `App.test.js`, `style.scss`, `pages/Books.jsx`, `pages/Add.jsx`, `pages/Update.jsx`, `pages/config.js`), plus one line-count-shrinking edit to `k8s/base/ingress/ingress.yaml`.
- **Does NOT modify:** any `services/*` backend code (their contracts are already correct and already verified working via curl earlier this session — see `docs/superpowers/specs/2026-08-08-frontend-microservices-integration-design.md` for the exact endpoint shapes this plan relies on), `backend/`, or any other Kubernetes manifest.
- **Does NOT** touch CI secrets. `API_URL` (injected as `REACT_APP_API_URL` at build time, see `client/Dockerfile`) is already documented in `README.md`'s GitHub Secrets Reference as `https://api.bookstore.<domain>` — the same hostname the gateway now owns once the ingress fix lands. Task 15 includes an explicit verification step; only change the secret if that verification finds it wrong.
- Every new piece of non-trivial logic (the two interceptor functions, the cart/orders book-join helper, `AuthContext`'s state transitions) gets a real unit test per the spec. The 5 new pages and the 3 edited pages are UI-only changes verified by hand against the real cluster in the final task — this project has no frontend E2E infra, and building one is explicitly out of scope per the spec.

---

### Task 1: Replace the stale `App.test.js`

**Why first:** `App.test.js` currently asserts on CRA's boilerplate "learn react" text, which hasn't existed since `Books.jsx` replaced the default homepage — it's already a dead/failing test. `App.js` is about to change substantially (Task 14), so fix this now rather than carry a known-broken test through the whole plan.

**Files:**
- Modify: `client/src/App.test.js`

- [ ] **Step 1: Replace the test with one that actually matches current behavior**

Replace the full contents of `client/src/App.test.js` with:

```javascript
import { render, screen } from "@testing-library/react";
import App from "./App";

test("renders the bookstore heading on the home route", () => {
  render(<App />);
  const heading = screen.getByText(/Mindcircuit book Store/i);
  expect(heading).toBeInTheDocument();
});
```

- [ ] **Step 2: Run it and confirm it currently fails for the RIGHT reason**

Run: `cd client && CI=true npm test -- --testPathPattern=App.test.js`

Expected: passes already, actually — `Books.jsx` already renders this heading and `App.js` hasn't changed yet. Confirm it's green right now: `PASS src/App.test.js`. This step exists to lock in a real baseline before Task 14 changes `App.js`; if this fails instead, stop and investigate before continuing (something about the current `Books.jsx`/`App.js` doesn't match what the spec assumed).

- [ ] **Step 3: Commit**

```bash
git add client/src/App.test.js
git commit -m "test(client): replace stale App.test.js boilerplate assertion with a real one"
```

---

### Task 2: Shared API client with testable interceptors

**Files:**
- Create: `client/src/api/api.js`
- Test: `client/src/api/api.test.js`

- [ ] **Step 1: Write the failing tests**

Create `client/src/api/api.test.js`:

```javascript
import { attachAuthHeader, handleAuthError } from "./api";

describe("attachAuthHeader", () => {
  beforeEach(() => {
    localStorage.clear();
  });

  test("attaches Authorization header when a token is stored", () => {
    localStorage.setItem("bookstore_token", "abc123");
    const config = { headers: {} };
    const result = attachAuthHeader(config);
    expect(result.headers.Authorization).toBe("Bearer abc123");
  });

  test("does not attach a header when no token is stored", () => {
    const config = { headers: {} };
    const result = attachAuthHeader(config);
    expect(result.headers.Authorization).toBeUndefined();
  });
});

describe("handleAuthError", () => {
  beforeEach(() => {
    localStorage.clear();
    localStorage.setItem("bookstore_token", "abc123");
    localStorage.setItem("bookstore_email", "test@example.com");
    Object.defineProperty(window, "location", {
      writable: true,
      value: { href: "" },
    });
  });

  test("clears stored auth and redirects to /login on a 401", async () => {
    const error = { response: { status: 401 } };
    await expect(handleAuthError(error)).rejects.toBe(error);
    expect(localStorage.getItem("bookstore_token")).toBeNull();
    expect(localStorage.getItem("bookstore_email")).toBeNull();
    expect(window.location.href).toBe("/login");
  });

  test("leaves stored auth alone and does not redirect on other errors", async () => {
    const error = { response: { status: 500 } };
    await expect(handleAuthError(error)).rejects.toBe(error);
    expect(localStorage.getItem("bookstore_token")).toBe("abc123");
    expect(window.location.href).toBe("");
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd client && CI=true npm test -- --testPathPattern=api.test.js`
Expected: FAIL — `Cannot find module './api'` (the file doesn't exist yet).

- [ ] **Step 3: Write the implementation**

Create `client/src/api/api.js`:

```javascript
import axios from "axios";
import API_BASE_URL from "../pages/config";

// Exported separately from the axios instance so each can be unit-tested
// directly without needing a real HTTP call.
export function attachAuthHeader(config) {
  const token = localStorage.getItem("bookstore_token");
  if (token) {
    config.headers = config.headers || {};
    config.headers.Authorization = `Bearer ${token}`;
  }
  return config;
}

export function handleAuthError(error) {
  if (error.response && error.response.status === 401) {
    localStorage.removeItem("bookstore_token");
    localStorage.removeItem("bookstore_email");
    window.location.href = "/login";
  }
  return Promise.reject(error);
}

const api = axios.create({ baseURL: API_BASE_URL });

api.interceptors.request.use(attachAuthHeader);
api.interceptors.response.use((response) => response, handleAuthError);

export default api;
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd client && CI=true npm test -- --testPathPattern=api.test.js`
Expected: `PASS src/api/api.test.js`, 4 tests passing.

- [ ] **Step 5: Commit**

```bash
git add client/src/api/api.js client/src/api/api.test.js
git commit -m "feat(client): add shared API client with auth header and 401-redirect interceptors"
```

---

### Task 3: Cart/orders book-join helper

**Why:** `order-service`'s `/cart` and `/orders` responses only contain `book_id`/`quantity` (+`status` for orders) — no title, price, or cover. `Cart.jsx` and `Orders.jsx` (Tasks 9 and 11) both need to join against `/books` client-side to show anything human-readable. One shared helper, used by both.

**Files:**
- Create: `client/src/utils/joinWithBooks.js`
- Test: `client/src/utils/joinWithBooks.test.js`

- [ ] **Step 1: Write the failing tests**

Create `client/src/utils/joinWithBooks.test.js`:

```javascript
import { joinWithBooks } from "./joinWithBooks";

describe("joinWithBooks", () => {
  const books = [
    { id: 1, title: "Book One", price: "9.99", cover: "cover1.jpg" },
    { id: 2, title: "Book Two", price: "14.99", cover: "cover2.jpg" },
  ];

  test("joins matching items with their book's title/price/cover", () => {
    const items = [{ book_id: 1, quantity: 2 }];
    expect(joinWithBooks(items, books)).toEqual([
      { book_id: 1, quantity: 2, title: "Book One", price: "9.99", cover: "cover1.jpg" },
    ]);
  });

  test("preserves extra fields already on the item, e.g. order status", () => {
    const items = [{ book_id: 2, quantity: 1, status: "pending" }];
    const [result] = joinWithBooks(items, books);
    expect(result.status).toBe("pending");
    expect(result.title).toBe("Book Two");
  });

  test("fills in null title/price/cover when the book no longer exists", () => {
    const items = [{ book_id: 999, quantity: 1 }];
    const [result] = joinWithBooks(items, books);
    expect(result.book_id).toBe(999);
    expect(result.title).toBeNull();
    expect(result.price).toBeNull();
    expect(result.cover).toBeNull();
  });

  test("returns an empty array for an empty item list", () => {
    expect(joinWithBooks([], books)).toEqual([]);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd client && CI=true npm test -- --testPathPattern=joinWithBooks.test.js`
Expected: FAIL — `Cannot find module './joinWithBooks'`.

- [ ] **Step 3: Write the implementation**

Create `client/src/utils/joinWithBooks.js`:

```javascript
// order-service's /cart and /orders responses only carry book_id/quantity
// (+status for orders) -- no title/price/cover. This joins them against a
// /books response (catalog-service, via the gateway) client-side, since
// order-service deliberately doesn't denormalize catalog data.
export function joinWithBooks(items, books) {
  const bookById = new Map(books.map((book) => [book.id, book]));
  return items.map((item) => {
    const book = bookById.get(item.book_id);
    return {
      ...item,
      title: book ? book.title : null,
      price: book ? book.price : null,
      cover: book ? book.cover : null,
    };
  });
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd client && CI=true npm test -- --testPathPattern=joinWithBooks.test.js`
Expected: `PASS src/utils/joinWithBooks.test.js`, 4 tests passing.

- [ ] **Step 5: Commit**

```bash
git add client/src/utils/joinWithBooks.js client/src/utils/joinWithBooks.test.js
git commit -m "feat(client): add cart/orders-to-books join helper"
```

---

### Task 4: `AuthContext`

**Files:**
- Create: `client/src/context/AuthContext.jsx`
- Test: `client/src/context/AuthContext.test.jsx`

- [ ] **Step 1: Write the failing tests**

Create `client/src/context/AuthContext.test.jsx`:

```javascript
import { render, screen, act } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { AuthProvider, useAuth } from "./AuthContext";
import api from "../api/api";

jest.mock("../api/api");

function TestConsumer() {
  const { isAuthenticated, email, login, logout } = useAuth();
  return (
    <div>
      <span data-testid="status">{isAuthenticated ? "in" : "out"}</span>
      <span data-testid="email">{email || "none"}</span>
      <button onClick={() => login("test@example.com", "pw")}>do-login</button>
      <button onClick={logout}>do-logout</button>
    </div>
  );
}

describe("AuthContext", () => {
  beforeEach(() => {
    localStorage.clear();
    jest.clearAllMocks();
  });

  test("starts logged out when localStorage has no token", () => {
    render(
      <AuthProvider>
        <TestConsumer />
      </AuthProvider>
    );
    expect(screen.getByTestId("status")).toHaveTextContent("out");
    expect(screen.getByTestId("email")).toHaveTextContent("none");
  });

  test("restores session from localStorage on mount", () => {
    localStorage.setItem("bookstore_token", "stored-token");
    localStorage.setItem("bookstore_email", "saved@example.com");
    render(
      <AuthProvider>
        <TestConsumer />
      </AuthProvider>
    );
    expect(screen.getByTestId("status")).toHaveTextContent("in");
    expect(screen.getByTestId("email")).toHaveTextContent("saved@example.com");
  });

  test("login calls POST /auth/login and stores the returned token", async () => {
    api.post.mockResolvedValueOnce({ data: { token: "new-token" } });
    render(
      <AuthProvider>
        <TestConsumer />
      </AuthProvider>
    );
    await act(async () => {
      await userEvent.click(screen.getByText("do-login"));
    });
    expect(api.post).toHaveBeenCalledWith("/auth/login", {
      email: "test@example.com",
      password: "pw",
    });
    expect(screen.getByTestId("status")).toHaveTextContent("in");
    expect(localStorage.getItem("bookstore_token")).toBe("new-token");
    expect(localStorage.getItem("bookstore_email")).toBe("test@example.com");
  });

  test("logout clears state and localStorage", async () => {
    localStorage.setItem("bookstore_token", "stored-token");
    localStorage.setItem("bookstore_email", "saved@example.com");
    render(
      <AuthProvider>
        <TestConsumer />
      </AuthProvider>
    );
    await act(async () => {
      await userEvent.click(screen.getByText("do-logout"));
    });
    expect(screen.getByTestId("status")).toHaveTextContent("out");
    expect(localStorage.getItem("bookstore_token")).toBeNull();
  });

  test("useAuth throws when used outside an AuthProvider", () => {
    const consoleError = jest.spyOn(console, "error").mockImplementation(() => {});
    expect(() => render(<TestConsumer />)).toThrow(
      "useAuth must be used within an AuthProvider"
    );
    consoleError.mockRestore();
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd client && CI=true npm test -- --testPathPattern=AuthContext.test.jsx`
Expected: FAIL — `Cannot find module './AuthContext'`.

- [ ] **Step 3: Write the implementation**

Create `client/src/context/AuthContext.jsx`:

```javascript
import { createContext, useContext, useState } from "react";
import api from "../api/api";

const AuthContext = createContext(null);

export function AuthProvider({ children }) {
  const [token, setToken] = useState(() => localStorage.getItem("bookstore_token"));
  const [email, setEmail] = useState(() => localStorage.getItem("bookstore_email"));

  const login = async (loginEmail, password) => {
    const res = await api.post("/auth/login", { email: loginEmail, password });
    localStorage.setItem("bookstore_token", res.data.token);
    localStorage.setItem("bookstore_email", loginEmail);
    setToken(res.data.token);
    setEmail(loginEmail);
  };

  // /auth/register returns {id, email}, not a token -- the caller (Register
  // page) sends the user to /login afterwards, it does not log them in.
  const register = async (registerEmail, password) => {
    await api.post("/auth/register", { email: registerEmail, password });
  };

  const logout = () => {
    localStorage.removeItem("bookstore_token");
    localStorage.removeItem("bookstore_email");
    setToken(null);
    setEmail(null);
  };

  const value = {
    token,
    email,
    isAuthenticated: Boolean(token),
    login,
    register,
    logout,
  };

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (!context) {
    throw new Error("useAuth must be used within an AuthProvider");
  }
  return context;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd client && CI=true npm test -- --testPathPattern=AuthContext.test.jsx`
Expected: `PASS src/context/AuthContext.test.jsx`, 5 tests passing.

- [ ] **Step 5: Commit**

```bash
git add client/src/context/AuthContext.jsx client/src/context/AuthContext.test.jsx
git commit -m "feat(client): add AuthContext for login/register/logout state"
```

---

### Task 5: `ProtectedRoute` component

**Files:**
- Create: `client/src/components/ProtectedRoute.jsx`

No dedicated test — this is a 9-line declarative wrapper around `useAuth()` and `react-router`'s `Navigate`, with no branching logic beyond what `AuthContext`'s own tests (Task 4) already cover. It's exercised indirectly by the manual end-to-end verification in Task 16 (an unauthenticated visit to `/cart` must land on `/login`).

- [ ] **Step 1: Write the component**

Create `client/src/components/ProtectedRoute.jsx`:

```javascript
import { Navigate } from "react-router-dom";
import { useAuth } from "../context/AuthContext";

const ProtectedRoute = ({ children }) => {
  const { isAuthenticated } = useAuth();
  if (!isAuthenticated) {
    return <Navigate to="/login" replace />;
  }
  return children;
};

export default ProtectedRoute;
```

- [ ] **Step 2: Commit**

```bash
git add client/src/components/ProtectedRoute.jsx
git commit -m "feat(client): add ProtectedRoute wrapper"
```

---

### Task 6: `Nav` component + layout SCSS

**Files:**
- Create: `client/src/components/Nav.jsx`
- Modify: `client/src/style.scss`

**Why the SCSS change is needed, not optional:** `.app` currently has `justify-content: center` with no `flex-direction` set (defaults to `row`), which worked when `.app` only ever had one child (whatever page `<Routes>` rendered). Task 14 adds `<Nav />` as a sibling before `<Routes>`, giving `.app` two children — without `flex-direction: column`, the nav bar and the page content would sit side-by-side instead of stacked.

- [ ] **Step 1: Write the component**

Create `client/src/components/Nav.jsx`:

```javascript
import { Link, useNavigate } from "react-router-dom";
import { useAuth } from "../context/AuthContext";

const Nav = () => {
  const { isAuthenticated, email, logout } = useAuth();
  const navigate = useNavigate();

  const handleLogout = () => {
    logout();
    navigate("/");
  };

  return (
    <nav className="nav">
      <Link to="/" className="navBrand">
        Mindcircuit Book Store
      </Link>
      <div className="navLinks">
        {isAuthenticated ? (
          <>
            <span className="navEmail">{email}</span>
            <Link to="/cart">Cart</Link>
            <Link to="/orders">Orders</Link>
            <button onClick={handleLogout}>Logout</button>
          </>
        ) : (
          <>
            <Link to="/login">Login</Link>
            <Link to="/register">Register</Link>
          </>
        )}
      </div>
    </nav>
  );
};

export default Nav;
```

- [ ] **Step 2: Add layout styles**

In `client/src/style.scss`, change the `.app` block's top declarations from:

```scss
.app {
  height: 100vh;
  padding: 0 100px;
  display: flex;
  align-items: center;
  justify-content: center;
  text-align: center;
```

to:

```scss
.app {
  min-height: 100vh;
  padding: 0 100px;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: flex-start;
  text-align: center;
```

(`height: 100vh` → `min-height: 100vh` too — pages like `Cart`/`Orders` with several line items can exceed one viewport height, and a fixed `height` would clip content instead of letting the page scroll.)

Then add a `.nav` block as a new top-level rule inside `.app { ... }`, right after the opening declarations (before `.addHome`):

```scss
  .nav {
    width: 100%;
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 20px 0;
    border-bottom: 1px solid #eee;
    margin-bottom: 30px;

    .navBrand {
      font-weight: bold;
      color: inherit;
      text-decoration: none;
    }

    .navLinks {
      display: flex;
      gap: 15px;
      align-items: center;

      a {
        color: inherit;
        text-decoration: none;
      }

      button {
        border: none;
        background: none;
        cursor: pointer;
        font-weight: bold;
        color: teal;
      }
    }
  }

  .error {
    color: rgb(242, 100, 100);
  }

  .success {
    color: teal;
  }
```

- [ ] **Step 3: Verify the build still compiles**

Run: `cd client && CI=true npm run build`
Expected: builds successfully (Nav isn't wired into `App.js` yet — that's Task 14 — this just confirms the new files have no syntax errors).

- [ ] **Step 4: Commit**

```bash
git add client/src/components/Nav.jsx client/src/style.scss
git commit -m "feat(client): add Nav component and supporting layout styles"
```

---

### Task 7: `Login` page

**Files:**
- Create: `client/src/pages/Login.jsx`

- [ ] **Step 1: Write the component**

Create `client/src/pages/Login.jsx`:

```javascript
import { useState } from "react";
import { useNavigate, useLocation, Link } from "react-router-dom";
import { useAuth } from "../context/AuthContext";

const Login = () => {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const { login } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();
  const justRegistered = Boolean(location.state && location.state.registered);

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError("");
    try {
      await login(email, password);
      navigate("/");
    } catch (err) {
      if (err.response && err.response.status === 401) {
        setError("invalid email or password");
      } else {
        setError("something went wrong, try again");
      }
    }
  };

  return (
    <div className="form">
      <h1>Login</h1>
      {justRegistered && <p className="success">registered — please log in</p>}
      <input
        type="email"
        placeholder="Email"
        value={email}
        onChange={(e) => setEmail(e.target.value)}
      />
      <input
        type="password"
        placeholder="Password"
        value={password}
        onChange={(e) => setPassword(e.target.value)}
      />
      <button onClick={handleSubmit}>Login</button>
      {error && <p className="error">{error}</p>}
      <Link to="/register">Need an account? Register</Link>
    </div>
  );
};

export default Login;
```

- [ ] **Step 2: Commit**

```bash
git add client/src/pages/Login.jsx
git commit -m "feat(client): add Login page"
```

---

### Task 8: `Register` page

**Files:**
- Create: `client/src/pages/Register.jsx`

- [ ] **Step 1: Write the component**

Create `client/src/pages/Register.jsx`:

```javascript
import { useState } from "react";
import { useNavigate, Link } from "react-router-dom";
import { useAuth } from "../context/AuthContext";

const Register = () => {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const { register } = useAuth();
  const navigate = useNavigate();

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError("");
    try {
      await register(email, password);
      navigate("/login", { state: { registered: true } });
    } catch (err) {
      if (err.response && err.response.status === 409) {
        setError("email already registered");
      } else if (err.response && err.response.status === 400) {
        setError("email and password are required");
      } else {
        setError("something went wrong, try again");
      }
    }
  };

  return (
    <div className="form">
      <h1>Register</h1>
      <input
        type="email"
        placeholder="Email"
        value={email}
        onChange={(e) => setEmail(e.target.value)}
      />
      <input
        type="password"
        placeholder="Password"
        value={password}
        onChange={(e) => setPassword(e.target.value)}
      />
      <button onClick={handleSubmit}>Register</button>
      {error && <p className="error">{error}</p>}
      <Link to="/login">Already have an account? Login</Link>
    </div>
  );
};

export default Register;
```

- [ ] **Step 2: Commit**

```bash
git add client/src/pages/Register.jsx
git commit -m "feat(client): add Register page"
```

---

### Task 9: `Cart` page

**Files:**
- Create: `client/src/pages/Cart.jsx`

- [ ] **Step 1: Write the component**

Create `client/src/pages/Cart.jsx`:

```javascript
import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import api from "../api/api";
import { joinWithBooks } from "../utils/joinWithBooks";

const Cart = () => {
  const [items, setItems] = useState([]);
  const [error, setError] = useState("");
  const navigate = useNavigate();

  const loadCart = async () => {
    try {
      const [cartRes, booksRes] = await Promise.all([api.get("/cart"), api.get("/books")]);
      setItems(joinWithBooks(cartRes.data, booksRes.data));
    } catch (err) {
      console.log(err);
      setError("something went wrong, try again");
    }
  };

  useEffect(() => {
    loadCart();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const handleQuantityChange = async (bookId, rawQuantity) => {
    const quantity = parseInt(rawQuantity, 10);
    if (!Number.isInteger(quantity) || quantity <= 0) return;
    try {
      await api.post("/cart", { book_id: bookId, quantity });
      loadCart();
    } catch (err) {
      console.log(err);
      setError("something went wrong, try again");
    }
  };

  const handleRemove = async (bookId) => {
    try {
      await api.delete(`/cart/${bookId}`);
      loadCart();
    } catch (err) {
      console.log(err);
      setError("something went wrong, try again");
    }
  };

  const total = items.reduce(
    (sum, item) => sum + (item.price ? parseFloat(item.price) * item.quantity : 0),
    0
  );

  return (
    <div>
      <h1>Your Cart</h1>
      {error && <p className="error">{error}</p>}
      {items.length === 0 && !error && <p>Your cart is empty.</p>}
      <div className="books">
        {items.map((item) => (
          <div key={item.book_id} className="book">
            {item.cover && <img src={item.cover} alt="" />}
            <h2>{item.title || `Book #${item.book_id}`}</h2>
            <span>${item.price || "?"}</span>
            <input
              type="number"
              min="1"
              value={item.quantity}
              onChange={(e) => handleQuantityChange(item.book_id, e.target.value)}
            />
            <button className="delete" onClick={() => handleRemove(item.book_id)}>
              Remove
            </button>
          </div>
        ))}
      </div>
      {items.length > 0 && (
        <>
          <h2>Total: ${total.toFixed(2)}</h2>
          <button className="addHome" onClick={() => navigate("/checkout")}>
            Proceed to Checkout
          </button>
        </>
      )}
    </div>
  );
};

export default Cart;
```

- [ ] **Step 2: Commit**

```bash
git add client/src/pages/Cart.jsx
git commit -m "feat(client): add Cart page"
```

---

### Task 10: `Checkout` page

**Files:**
- Create: `client/src/pages/Checkout.jsx`

- [ ] **Step 1: Write the component**

Create `client/src/pages/Checkout.jsx`:

```javascript
import { useEffect, useState } from "react";
import { useNavigate, Link } from "react-router-dom";
import api from "../api/api";
import { joinWithBooks } from "../utils/joinWithBooks";

const Checkout = () => {
  const [items, setItems] = useState([]);
  const [error, setError] = useState("");
  const [placing, setPlacing] = useState(false);
  const navigate = useNavigate();

  useEffect(() => {
    const loadCart = async () => {
      try {
        const [cartRes, booksRes] = await Promise.all([api.get("/cart"), api.get("/books")]);
        setItems(joinWithBooks(cartRes.data, booksRes.data));
      } catch (err) {
        console.log(err);
        setError("something went wrong, try again");
      }
    };
    loadCart();
  }, []);

  const total = items.reduce(
    (sum, item) => sum + (item.price ? parseFloat(item.price) * item.quantity : 0),
    0
  );

  const handlePlaceOrder = async () => {
    setError("");
    setPlacing(true);
    try {
      await api.post("/orders/checkout");
      navigate("/orders");
    } catch (err) {
      if (err.response && err.response.status === 400) {
        setError("your cart is empty");
      } else {
        setError("something went wrong, try again");
      }
      setPlacing(false);
    }
  };

  return (
    <div>
      <h1>Checkout</h1>
      {error && (
        <p className="error">
          {error}
          {error === "your cart is empty" && (
            <>
              {" "}
              <Link to="/cart">Back to cart</Link>
            </>
          )}
        </p>
      )}
      <div className="books">
        {items.map((item) => (
          <div key={item.book_id} className="book">
            {item.cover && <img src={item.cover} alt="" />}
            <h2>{item.title || `Book #${item.book_id}`}</h2>
            <span>
              ${item.price || "?"} x {item.quantity}
            </span>
          </div>
        ))}
      </div>
      {items.length > 0 && <h2>Total: ${total.toFixed(2)}</h2>}
      <button className="addHome" onClick={handlePlaceOrder} disabled={placing || items.length === 0}>
        {placing ? "Placing order..." : "Place Order"}
      </button>
    </div>
  );
};

export default Checkout;
```

- [ ] **Step 2: Commit**

```bash
git add client/src/pages/Checkout.jsx
git commit -m "feat(client): add Checkout page"
```

---

### Task 11: `Orders` page

**Files:**
- Create: `client/src/pages/Orders.jsx`

- [ ] **Step 1: Write the component**

Create `client/src/pages/Orders.jsx`:

```javascript
import { useEffect, useState } from "react";
import api from "../api/api";
import { joinWithBooks } from "../utils/joinWithBooks";

const Orders = () => {
  const [orders, setOrders] = useState([]);
  const [error, setError] = useState("");

  useEffect(() => {
    const loadOrders = async () => {
      try {
        const [ordersRes, booksRes] = await Promise.all([api.get("/orders"), api.get("/books")]);
        setOrders(joinWithBooks(ordersRes.data, booksRes.data));
      } catch (err) {
        console.log(err);
        setError("something went wrong, try again");
      }
    };
    loadOrders();
  }, []);

  return (
    <div>
      <h1>Your Orders</h1>
      {error && <p className="error">{error}</p>}
      {orders.length === 0 && !error && <p>You haven't placed any orders yet.</p>}
      <div className="books">
        {orders.map((order) => (
          <div key={order.id} className="book">
            {order.cover && <img src={order.cover} alt="" />}
            <h2>{order.title || `Book #${order.book_id}`}</h2>
            <span>
              ${order.price || "?"} x {order.quantity}
            </span>
            <span className="status">{order.status}</span>
          </div>
        ))}
      </div>
    </div>
  );
};

export default Orders;
```

- [ ] **Step 2: Commit**

```bash
git add client/src/pages/Orders.jsx
git commit -m "feat(client): add Orders page"
```

---

### Task 12: Wire `Books.jsx` to the shared client + add "Add to Cart"

**Files:**
- Modify: `client/src/pages/Books.jsx`

- [ ] **Step 1: Replace the full contents**

Replace `client/src/pages/Books.jsx` with:

```javascript
import React from "react";
import { useEffect } from "react";
import { useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import api from "../api/api";
import { useAuth } from "../context/AuthContext";

const Books = () => {
  const [books, setBooks] = useState([]);
  const [addedId, setAddedId] = useState(null);
  const { isAuthenticated } = useAuth();
  const navigate = useNavigate();

  useEffect(() => {
    const fetchAllBooks = async () => {
      try {
        const res = await api.get("/books");
        setBooks(res.data);
      } catch (err) {
        console.log(err);
      }
    };
    fetchAllBooks();
  }, []);

  const handleDelete = async (id) => {
    try {
      await api.delete(`/books/${id}`);
      window.location.reload();
    } catch (err) {
      console.log(err);
    }
  };

  const handleAddToCart = async (id) => {
    if (!isAuthenticated) {
      navigate("/login");
      return;
    }
    try {
      await api.post("/cart", { book_id: id, quantity: 1 });
      setAddedId(id);
      setTimeout(() => setAddedId(null), 1500);
    } catch (err) {
      console.log(err);
    }
  };

  return (
    <div>
      <h1>Mindcircuit book Store</h1>
      <div className="books">
        {books.map((book) => (
          <div key={book.id} className="book">
            <img src={book.cover} alt="" />
            <h2>{book.title}</h2>
            <p>{book.desc}</p>
            <span>${book.price}</span>
            <button className="addToCart" onClick={() => handleAddToCart(book.id)}>
              {addedId === book.id ? "Added!" : "Add to Cart"}
            </button>
            <button className="delete" onClick={() => handleDelete(book.id)}>
              Delete
            </button>
            <button className="update">
              <Link to={`/update/${book.id}`} style={{ color: "inherit", textDecoration: "none" }}>
                Update
              </Link>
            </button>
          </div>
        ))}
      </div>

      <button className="addHome">
        <Link to="/add" style={{ color: "inherit", textDecoration: "none" }}>
          Add new book
        </Link>
      </button>
    </div>
  );
};

export default Books;
```

(`console.log(books)` from the original is dropped — it was debug output left in, not needed going forward.)

- [ ] **Step 2: Commit**

```bash
git add client/src/pages/Books.jsx
git commit -m "feat(client): wire Books to shared API client, add Add-to-Cart"
```

---

### Task 13: Wire `Add.jsx` and `Update.jsx` to the shared client

**Files:**
- Modify: `client/src/pages/Add.jsx`
- Modify: `client/src/pages/Update.jsx`

**Why:** both currently `import axios from "axios"` and call it directly with a manually-built URL — once the gateway requires a JWT for `POST`/`PUT` on `/books` (Task 15 makes this live), these calls need the `Authorization` header the shared client attaches automatically.

- [ ] **Step 1: Edit `Add.jsx`**

In `client/src/pages/Add.jsx`, replace the top two lines:

```javascript
import axios from "axios";
import React from "react";
import { useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import API_BASE_URL from "./config";
```

with:

```javascript
import React from "react";
import { useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import api from "../api/api";
```

Then replace the request line inside `handleClick`:

```javascript
      await axios.post(`${API_BASE_URL}/books`, book);
```

with:

```javascript
      await api.post("/books", book);
```

- [ ] **Step 2: Edit `Update.jsx`**

In `client/src/pages/Update.jsx`, replace the top two lines:

```javascript
import axios from "axios";
import React, { useState } from "react";
import { Link, useLocation, useNavigate } from "react-router-dom";
import API_BASE_URL from "./config";
```

with:

```javascript
import React, { useState } from "react";
import { Link, useLocation, useNavigate } from "react-router-dom";
import api from "../api/api";
```

Then replace the request line inside `handleClick`:

```javascript
      await axios.put(`${API_BASE_URL}/books/${bookId}`, book);
```

with:

```javascript
      await api.put(`/books/${bookId}`, book);
```

- [ ] **Step 3: Verify the build compiles**

Run: `cd client && CI=true npm run build`
Expected: builds successfully, no unused-import warnings for `axios` or `API_BASE_URL` in either file.

- [ ] **Step 4: Commit**

```bash
git add client/src/pages/Add.jsx client/src/pages/Update.jsx
git commit -m "feat(client): wire Add/Update to shared API client so writes carry the JWT"
```

---

### Task 14: Wire everything into `App.js`

**Files:**
- Modify: `client/src/App.js`

- [ ] **Step 1: Replace the full contents**

Replace `client/src/App.js` with:

```javascript
import { BrowserRouter, Routes, Route } from "react-router-dom";
import { AuthProvider } from "./context/AuthContext";
import Nav from "./components/Nav";
import ProtectedRoute from "./components/ProtectedRoute";
import Add from "./pages/Add";
import Books from "./pages/Books";
import Update from "./pages/Update";
import Login from "./pages/Login";
import Register from "./pages/Register";
import Cart from "./pages/Cart";
import Checkout from "./pages/Checkout";
import Orders from "./pages/Orders";

function App() {
  return (
    <AuthProvider>
      <div className="app">
        <BrowserRouter>
          <Nav />
          <Routes>
            <Route path="/" element={<Books />} />
            <Route path="/add" element={<Add />} />
            <Route path="/update/:id" element={<Update />} />
            <Route path="/login" element={<Login />} />
            <Route path="/register" element={<Register />} />
            <Route
              path="/cart"
              element={
                <ProtectedRoute>
                  <Cart />
                </ProtectedRoute>
              }
            />
            <Route
              path="/checkout"
              element={
                <ProtectedRoute>
                  <Checkout />
                </ProtectedRoute>
              }
            />
            <Route
              path="/orders"
              element={
                <ProtectedRoute>
                  <Orders />
                </ProtectedRoute>
              }
            />
          </Routes>
        </BrowserRouter>
      </div>
    </AuthProvider>
  );
}

export default App;
```

- [ ] **Step 2: Run the full test suite**

Run: `cd client && CI=true npm test`

Expected: all suites pass — `App.test.js` (Task 1), `api.test.js` (Task 2), `joinWithBooks.test.js` (Task 3), `AuthContext.test.jsx` (Task 4). `App.test.js`'s render of `<App />` now exercises `AuthProvider` + `Nav` + the full route tree for the first time; if it fails here, the most likely cause is a missing `BrowserRouter`/context wrapper mismatch — fix before proceeding, don't skip.

- [ ] **Step 3: Run a production build**

Run: `cd client && CI=true npm run build`
Expected: builds successfully with no errors.

- [ ] **Step 4: Commit**

```bash
git add client/src/App.js
git commit -m "feat(client): wire AuthProvider, Nav, and the 5 new routes into App"
```

---

### Task 15: Resolve the `api.bookstore.<domain>` ingress collision

**Files:**
- Modify: `k8s/base/ingress/ingress.yaml`

**Why this has to happen for the frontend build to actually work:** `k8s/base/ingress/ingress.yaml` (old monolith, routes to `backend-service`) and `k8s/services/api-gateway/base/ingress.yaml` (new, routes to `gateway-service`) both currently declare the host `api.bookstore.<domain>`. Which one nginx actually honors is undefined when two Ingress objects claim the same host — the frontend now needs the gateway to be the one reliably answering, every time, not by accident of ingress-controller tie-breaking.

- [ ] **Step 1: Edit the manifest**

In `k8s/base/ingress/ingress.yaml`, remove `api.bookstore.b17facebook.xyz` from the `tls.hosts` list — change:

```yaml
  tls:
    - hosts:
        - bookstore.b17facebook.xyz
        - api.bookstore.b17facebook.xyz
      secretName: bookstore-tls
```

to:

```yaml
  tls:
    - hosts:
        - bookstore.b17facebook.xyz
      secretName: bookstore-tls
```

Then remove the entire second `rules` entry for that host — delete:

```yaml
    - host: api.bookstore.b17facebook.xyz
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: backend-service
                port:
                  number: 80
```

leaving only the `bookstore.b17facebook.xyz` rule under `rules:`.

(If your `terraform.tfvars`' `domain` isn't `b17facebook.xyz`, use whatever this file's existing hostnames actually say — don't hardcode a different domain than what's already there.)

- [ ] **Step 2: Verify the rendered manifest looks right**

Run: `kubectl kustomize k8s/overlays/prod | grep -A20 "kind: Ingress"`
Expected: exactly one `host:` entry (`bookstore.b17facebook.xyz`) and one `tls.hosts` entry, both for the frontend-serving hostname only.

- [ ] **Step 3: Commit**

```bash
git add k8s/base/ingress/ingress.yaml
git commit -m "fix(ingress): remove api.bookstore.<domain> rule from the old backend's ingress

Resolves the host collision with the api-gateway ingress -- gateway
is now the sole owner of api.bookstore.<domain>. See
docs/FUTURE_IMPROVEMENTS.md gap #12 and
docs/superpowers/specs/2026-08-08-frontend-microservices-integration-design.md."
```

---

### Task 16: Push, verify CI/CD, verify the ingress fix, end-to-end verification

**Files:** none (verification only)

- [ ] **Step 1: Push everything**

```bash
git push
```

This triggers CI (build/scan/push the frontend image, then the `deploy` job bumps `k8s/overlays/prod/kustomization.yaml`'s image tag and commits it — see `docs/CICD.md`). The `deploy` job needs manual approval on the `production` GitHub Environment; approve it same as every other deploy this session.

- [ ] **Step 2: Confirm the ingress fix synced**

```bash
kubectl get ingress -n bookstore -o jsonpath='{.items[0].spec.rules[*].host}{"\n"}'
```

Expected: only `bookstore.b17facebook.xyz` — if `api.bookstore.b17facebook.xyz` still appears, ArgoCD hasn't synced this change yet; force it:

```bash
kubectl -n argocd patch application bookstore --type merge -p '{"operation":{"sync":{"syncStrategy":{"hook":{}}}}}'
```

- [ ] **Step 3: Confirm the new frontend image is live**

```bash
kubectl get pods -n bookstore -l app=frontend -o jsonpath='{.items[*].spec.containers[0].image}{"\n"}'
```

Expected: the tag matches the SHA of the commit just pushed, not an older one. If pods are still on an old tag after a few minutes, check `kubectl get application bookstore -n argocd` for sync status and the `deploy` job's approval state in GitHub Actions.

- [ ] **Step 4: End-to-end verification against the live gateway**

Register, log in, browse, add to cart, check out, and view order history — for real, against the live cluster, matching this session's established "verify against AWS/EKS directly, never assume" pattern. Given this session hit real SNI-based filtering on `b17facebook.xyz` from some networks (see this session's history), run these `curl`s by IP with an explicit `Host` header if a plain hostname `curl` hangs — substitute the real gateway IP determined via `dig +short <gateway-hostname>` or `kubectl get svc -n ingress-nginx`:

```bash
GATEWAY_IP=<one of the ingress-nginx NLB's resolved IPs>

# Register
curl -sk "https://$GATEWAY_IP/auth/register" -H "Host: api.bookstore.b17facebook.xyz" \
  -H "Content-Type: application/json" \
  -d '{"email":"e2e-test@example.com","password":"testpass123"}' -w "\n%{http_code}\n"
# Expected: 201, {"id":<n>,"email":"e2e-test@example.com"}

# Login
TOKEN=$(curl -sk "https://$GATEWAY_IP/auth/login" -H "Host: api.bookstore.b17facebook.xyz" \
  -H "Content-Type: application/json" \
  -d '{"email":"e2e-test@example.com","password":"testpass123"}' | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")
echo "token: $TOKEN"
# Expected: a non-empty JWT string

# Add to cart (use a real book_id from GET /books)
curl -sk "https://$GATEWAY_IP/cart" -H "Host: api.bookstore.b17facebook.xyz" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"book_id":1,"quantity":2}' -w "\n%{http_code}\n"
# Expected: 200, {"book_id":1,"quantity":2}

# Checkout
curl -sk -X POST "https://$GATEWAY_IP/orders/checkout" -H "Host: api.bookstore.b17facebook.xyz" \
  -H "Authorization: Bearer $TOKEN" -w "\n%{http_code}\n"
# Expected: 201, an array with one order, status "pending"

# Order history
curl -sk "https://$GATEWAY_IP/orders" -H "Host: api.bookstore.b17facebook.xyz" \
  -H "Authorization: Bearer $TOKEN" -w "\n%{http_code}\n"
# Expected: 200, the order just placed

# Adding a book WITHOUT a token now correctly fails (confirms the ingress
# fix actually routed this to the gateway, not the old public backend)
curl -sk -X POST "https://$GATEWAY_IP/books" -H "Host: api.bookstore.b17facebook.xyz" \
  -H "Content-Type: application/json" \
  -d '{"title":"should be rejected","desc":"x","price":1,"cover":"x"}' -w "\n%{http_code}\n"
# Expected: 401 {"error":"missing or invalid Authorization header"}
```

If any step doesn't match its expected result, stop and investigate before considering this plan done — don't report success on an assumption.

- [ ] **Step 5: Browser verification**

Open the real site in a browser (or via the `/etc/hosts` override + browser Secure-DNS-off workaround established earlier this session if the SNI-filtering issue is still present on the testing network) and click through: Register → Login → Books → Add to Cart → Cart (verify item shows real title/price/cover, not just an ID) → Checkout → Place Order → Orders (verify it shows up with status "pending"). Also confirm an unauthenticated visit to `/cart` redirects to `/login`.

This step is also what closes the design spec's flagged open question about the `API_URL` GitHub Secret's value: `gh secret list` can only show secret *names*, never values (GitHub Secrets are write-only via the API/CLI by design), so there's no way to directly inspect it. If this browser click-through works end-to-end — every page successfully calling the gateway — that's conclusive proof `API_URL` was already correct and needed no change. If instead every API call in the browser fails while the raw `curl`s in Step 4 succeeded, that specific mismatch (works by IP, fails from the built frontend) would mean `API_URL` was baked in wrong at build time and needs updating via `gh secret set API_URL --body "https://api.bookstore.<domain>"` followed by a re-push to trigger a rebuild.

- [ ] **Step 6: Final commit if any fixes were needed during verification**

If Steps 4-5 turned up anything needing a fix, make the fix, re-verify, then:

```bash
git add -A
git commit -m "fix(client): <describe what verification caught>"
git push
```

(Only create this commit if something actually needed fixing — if verification passed clean, there's nothing to commit here.)

---

## Related

- [Design spec](../specs/2026-08-08-frontend-microservices-integration-design.md) — the approved design this plan implements
- `services/api-gateway/app.js` — exact JWT/proxy behavior this frontend integrates with
- `services/user-service/app.js`, `services/order-service/app.js` — exact endpoint contracts used throughout this plan
- `docs/FUTURE_IMPROVEMENTS.md` gap #12 — the ingress collision Task 15 resolves
