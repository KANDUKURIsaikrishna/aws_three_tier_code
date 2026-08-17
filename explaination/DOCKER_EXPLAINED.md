# The Docker Images, Explained So You Can Teach It — No Doubts Left

This covers six files: `client/Dockerfile` and five backend `Dockerfile`s (`catalog-service`, `user-service`, `notification-service`, `order-service`, `api-gateway`), plus their `nginx.conf`/`.dockerignore` companions. These are the recipes that turn source code into the actual container images `docs/CICD.md`'s pipeline builds, scans, and ships, and that `docs/KUBERNETES.md`'s Deployments run. This document is about what's *inside* the image — the Kubernetes doc covers what happens to that image once it's scheduled onto a node.

---

## Part 0: What is a container image, explained with zero jargon

Picture moving into a new apartment. You have two options. Option one: bring your entire house — the tools you used to build the furniture, the sawdust, the half-empty paint cans, the ladder — and stack all of it in the new living room next to the finished furniture. Option two: build the furniture somewhere else, then move in *only the finished furniture*, leaving every tool, offcut, and paint can behind.

A **multi-stage Docker build** is option two, mechanically. One stage (`deps` for the backend services, `builder` for the frontend) is the workshop — it has the full toolchain (`npm`, dev dependencies, a compiler for the frontend's case), and it's messy on purpose, because none of that mess ships. A second, separate stage (`runtime` / `runner`) starts completely fresh and copies over *only* the finished output — installed `node_modules` for a backend service, a folder of compiled HTML/JS/CSS for the frontend. Everything from the first stage that isn't explicitly copied over is simply discarded, gone, never present in the image that actually runs. This is why every image in this project is small and doesn't carry a full development toolchain into production — smaller means less to download, less to store, and critically, less *surface area* for something to go wrong or be attacked.

The second idea worth having solid before anything else: **why run as a non-root user at all?** By default, a container's main process runs as `root` inside that container — and "inside that container" isn't as separate from the real host machine as it sounds. A container is not a virtual machine; it's a regular process on the same Linux kernel as everything else, wrapped in isolation (namespaces, cgroups) that's strong but not absolute. If an attacker ever finds a way to break out of that isolation — a kernel bug, a misconfigured mount, a container runtime vulnerability — running as root inside the container means they land as root on the real host. Running as an unprivileged user inside the container means a breakout, if one ever happens, lands as a nobody, not an administrator. Every Dockerfile in this project creates a dedicated, unprivileged user and switches to it before the container's real work starts — this is the single security decision that shows up more than any other across all six files.

**Why does this matter enough to write a whole document about it, instead of "just install the dependencies and run the app"?** Because the shape of a Dockerfile is not neutral — every line is a decision with a real consequence, and a handful of these decisions (multi-stage builds, non-root users, deleting the package manager itself once it's no longer needed, a read-only filesystem) are exactly the kind of thing that separates "it runs" from "it runs the way a real production system should."

---

## Part 1: The inventory, and the one deliberate duplication

| File | Base image(s) | Shape |
|---|---|---|
| `client/Dockerfile` | `node:22-alpine` → `nginx:1.27-alpine` | React static build, served by nginx |
| `services/catalog-service/Dockerfile` | `node:22-alpine` → `node:22-alpine` | Express API |
| `services/user-service/Dockerfile` | `node:22-alpine` → `node:22-alpine` | Express API |
| `services/notification-service/Dockerfile` | `node:22-alpine` → `node:22-alpine` | Express API |
| `services/order-service/Dockerfile` | `node:22-alpine` → `node:22-alpine` | Express API |
| `services/api-gateway/Dockerfile` | `node:22-alpine` → `node:22-alpine` | Express API |

The five backend `Dockerfile`s are **byte-for-byte identical** — same stages, same instructions, same order, zero per-service customization. This is worth being able to defend as a deliberate choice, not sloppiness: every backend service here is the same shape of thing (a plain Express app, install dependencies, run it), so one proven template gets copy-pasted per service instead of each one slowly drifting apart on its own. `docs/CICD.md` documents the identical judgment call for the CI workflow that builds these images (copy-paste-and-rename per service instead of a matrix loop) — both decisions trade a small amount of duplication for every service's own file being fully readable on its own, with nothing hidden behind a shared template you'd have to go find and cross-reference to understand what a given service actually does.

`node:22-alpine` (Alpine Linux, not the full Debian-based `node:22`) is chosen specifically for size — Alpine's base is on the order of 5-8 MB versus Debian's ~120 MB, and a smaller base image means fewer OS packages that could ever carry a vulnerability in the first place.

---

## Part 2: The shared backend template, line by line

Applies to all five backend `Dockerfile`s at once — read it here, and you've read all five.

```dockerfile
FROM node:22-alpine AS deps

WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force

FROM node:22-alpine AS runtime

RUN apk upgrade --no-cache

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

COPY --from=deps --chown=appuser:appgroup /app/node_modules ./node_modules
COPY --chown=appuser:appgroup . .
RUN rm -f package-lock.json package.json && \
    rm -rf /usr/local/lib/node_modules/npm \
           /usr/local/bin/npm \
           /usr/local/bin/npx \
           /usr/local/bin/corepack

USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

CMD ["node", "index.js"]
```

### Stage 1 — `deps`, the workshop

`COPY package*.json ./` copies **only** `package.json` and `package-lock.json` — deliberately not the rest of the source code yet. This is a Docker build-cache trick worth being able to explain precisely: Docker caches each instruction's result, and invalidates that cache (re-running the instruction from scratch) only when its inputs change. By copying just the lockfile first and running `npm ci` against only that, the entire dependency-install step — the slowest part of any Node build, often the majority of total build time — gets **skipped entirely on rebuild** whenever only application source changed and dependencies didn't. If the full source were copied before `npm ci`, any single source-code edit (even a comment) would invalidate the cache for everything after it, including the expensive install step.

`npm ci`, not `npm install`, is the specific, correct choice for an automated pipeline. `npm install` can silently *update* the lockfile to satisfy loosely-specified version ranges; `npm ci` installs exactly, byte-for-byte, what `package-lock.json` already says, and fails loudly if the lockfile and `package.json` have drifted out of sync — the difference between "reproducible" and "whatever the latest compatible version happens to be today." `--omit=dev` skips every `devDependencies` entry (test frameworks, linters) — nothing a *running* container needs, only things needed to develop and test it. `npm cache clean --force` clears npm's own internal download cache from this stage's filesystem — it has zero effect on the final image (this whole stage gets thrown away, see below), but it does keep this intermediate layer smaller, which matters for how fast CI can push and pull cached layers between runs.

### Stage 2 — `runtime`, the finished apartment

`FROM node:22-alpine AS runtime` — a **second**, completely fresh copy of the base image, not `FROM deps`. This is the multi-stage payoff: nothing from stage 1 survives into this stage except what's explicitly `COPY --from=deps`'d over — the `deps` stage's own npm cache, any leftover build artifacts, all of it, simply doesn't exist in this image.

- `apk upgrade --no-cache` patches any OS-level package in the base image that's had a security fix released since that exact image tag was published, without leaving Alpine's own package index cached in this layer afterward.
- `addgroup -S appgroup && adduser -S appuser -G appgroup` — the non-root user, created fresh. `-S` means "system account": no password, no home directory, not meant for interactive login — exactly the shape of account a background service process needs and nothing more.
- `COPY --from=deps --chown=appuser:appgroup /app/node_modules ./node_modules` pulls in exactly the production dependencies from stage 1's install, and assigns them to the new user *at copy time* — worth noticing this is one instruction, not `COPY` followed by a separate `RUN chown`. Two separate steps would write every file to disk twice (once as root during copy, once again during the chown), doubling that layer's size for no benefit; `--chown` does both in one write.
- `COPY --chown=appuser:appgroup . .` copies the actual application source, respecting `.dockerignore` (covered below).
- The unusual line: `rm -f package-lock.json package.json && rm -rf .../npm .../npx .../corepack`. This deletes the lockfile and manifest from the final image, and then deletes `npm`, `npx`, and `corepack` **themselves** from where the base image installed them. The reasoning is worth having ready: once `npm ci` has already run in stage 1 and `node_modules` is fully populated, nothing at runtime ever calls `npm` again — `node index.js` doesn't shell out to it. Removing it is a real, if modest, attack-surface reduction: if an attacker ever achieved code execution inside this running container, there is no `npm` binary left for them to use to pull down and run an arbitrary malicious package. You can't abuse a tool that isn't there.
- `USER appuser` — every instruction after this line, and the container's actual running process, executes as this unprivileged user, not root.
- `EXPOSE 3000` is documentation for humans and tooling, not an enforced restriction — every backend Express app in this project listens on `3000` internally (a service's *public*-facing port, if different, is a Kubernetes `Service`/`Ingress` concern layered on top, not something this line controls).
- `HEALTHCHECK` is Docker's own, built-in liveness check — separate and independent from Kubernetes' `livenessProbe`/`readinessProbe` (defined per-service in `k8s/services/<name>/base/deployment.yaml`, covered in `KUBERNETES_EXPLAINED.md`). This one matters specifically for anyone running the image directly — `docker run`, `docker compose`, local development — where nothing else is watching the container's health at all. `wget` is used instead of `curl` because Alpine's minimal base doesn't ship `curl`, and adding it just for a healthcheck isn't worth an extra installed package.
- `CMD ["node", "index.js"]` — runs the app directly, no `npm start` wrapper. An `npm start` wrapper would spawn an extra process layer for no benefit, and would fail outright anyway now that `npm` has just been deleted from this image two lines earlier.

---

## Part 3: The frontend Dockerfile — a genuinely different job

`client/Dockerfile` looks structurally different from the backend template because it *is* doing something structurally different: **compile** a React app into static files, then **serve** those files with a real webserver — not run a long-lived Node process at all.

```dockerfile
FROM node:22-alpine AS builder

RUN apk upgrade --no-cache
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .

ARG REACT_APP_API_URL
ENV REACT_APP_API_URL=$REACT_APP_API_URL

RUN npm run build

FROM nginx:1.27-alpine AS runner

RUN apk upgrade --no-cache
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

COPY --from=builder /app/build /usr/share/nginx/html
COPY nginx.conf /etc/nginx/nginx.conf

RUN chown -R appuser:appgroup /usr/share/nginx/html && \
    chown -R appuser:appgroup /var/cache/nginx && \
    chown -R appuser:appgroup /var/log/nginx && \
    touch /var/run/nginx.pid && \
    chown appuser:appgroup /var/run/nginx.pid

USER appuser

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:8080/health || exit 1

CMD ["nginx", "-g", "daemon off;"]
```

### Stage 1 — `builder`

`npm ci` here installs **every** dependency, including dev dependencies — no `--omit=dev` like the backend template. A React production build genuinely needs its dev toolchain (the bundler, Babel, and friends) to actually *produce* the compiled output; none of that matters once the build finishes, since — same multi-stage principle as before — this entire stage is discarded and only its output gets copied forward.

**The one part of this file that needs real, careful explaining**, because it's easy to wrongly assume it works the same way a backend service's environment variables do: `ARG REACT_APP_API_URL` / `ENV REACT_APP_API_URL=$REACT_APP_API_URL`. A backend Express service reads `process.env.SOMETHING` fresh, every time, at *runtime* — you can change an environment variable and restart the same image, no rebuild needed. A React app built with Create React App does **not** work that way. CRA inlines every `REACT_APP_*` variable directly into the compiled JavaScript bundle at `npm run build` time — by the time that bundle is sitting in a user's browser, `REACT_APP_API_URL` is not a variable being read anymore, it's a literal string baked permanently into the file, the same way a fact printed on a physical page can't be edited after the book is bound. There is no `process.env` inside a browser at all; the browser has no idea this value was ever an environment variable in the first place. That means the API URL has to be known and locked in at **image build time**, not container start time — which is exactly what this `ARG`/`ENV` pair does: `ARG` accepts a build-time input (via `docker build --build-arg`), and `ENV` makes that same value visible to the `npm run build` process that follows (an `ARG` alone is *not* automatically exported to child processes — the `ENV` line is what actually makes it reach the build). In this project's CI, that build arg is populated from the `API_URL` GitHub secret. **The direct, practical consequence: a new frontend image must be rebuilt any time the backing API's public URL changes** — an already-built image can never be redirected at a different URL by any runtime configuration; the URL is permanently part of that specific image's compiled bundle.

### Stage 2 — `runner`

Starts fresh from `nginx:1.27-alpine` — a purpose-built webserver image, not another Node base. There's no reason to carry a full Node runtime into an image whose only job, from this point forward, is handing already-compiled static files to browsers.

- `COPY --from=builder /app/build /usr/share/nginx/html` — copies just the compiled output (typically a few hundred KB to low single-digit MB of HTML/CSS/JS). Nothing from `node_modules`, no `.jsx` source files, none of the build tooling makes it across.
- `COPY nginx.conf /etc/nginx/nginx.conf` replaces nginx's own default configuration entirely with this project's own (next section).
- The `chown -R` block, plus the separate `touch`+`chown` on the pid file, exists for one specific reason: nginx's normal startup sequence needs to **write** to `/var/cache/nginx`, `/var/log/nginx`, and its own pid file. All three need to already belong to `appuser` *before* `USER appuser` takes effect a few lines down — otherwise nginx would fail on its very first startup write, under a non-root user it has no permission to write as.
- `EXPOSE 8080` — deliberately not the conventional `80`. Binding any port below `1024` on Linux requires either root privileges or the specific `CAP_NET_BIND_SERVICE` capability, and this container's Kubernetes `securityContext` (Part 5, below) strips every capability away on purpose. `8080` needs no elevated privilege at all, and `nginx.conf` is configured to actually listen there.
- `CMD ["nginx", "-g", "daemon off;"]` runs nginx in the **foreground**. A container's process manager (Docker, and above it Kubernetes) needs to be able to see and supervise the actual running server process directly — nginx's *default* behavior is to fork itself into a background daemon and have the foreground process exit immediately, which would make the container appear to have "finished" the instant it started, and get killed and restarted in a loop.

### `nginx.conf`, the part that makes the security posture actually work

```nginx
pid /tmp/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    client_body_temp_path /tmp/client_temp;
    proxy_temp_path       /tmp/proxy_temp;
    fastcgi_temp_path     /tmp/fastcgi_temp;
    uwsgi_temp_path       /tmp/uwsgi_temp;
    scgi_temp_path        /tmp/scgi_temp;

    sendfile        on;
    keepalive_timeout 65;

    server {
        listen 8080;
        root /usr/share/nginx/html;
        index index.html;

        location / {
            try_files $uri $uri/ /index.html;
        }

        location /health {
            return 200 'ok';
            add_header Content-Type text/plain;
        }

        add_header X-Frame-Options "SAMEORIGIN";
        add_header X-Content-Type-Options "nosniff";
        add_header X-XSS-Protection "1; mode=block";
        add_header Referrer-Policy "strict-origin-when-cross-origin";
    }
}
```

Every single `*_temp_path` directive, plus the `pid` directive itself, points at `/tmp`. This is not arbitrary — nginx's own factory defaults point these at locations under `/var/run` and `/var/lib/nginx`, paths this container's Kubernetes `securityContext` (Part 5) will not let it write to at all, because the container's entire root filesystem is mounted **read-only**. Redirecting every one of these to `/tmp` — a location the pod deliberately mounts a writable scratch volume onto at runtime — is the specific detail that makes `readOnlyRootFilesystem: true` actually *survivable* for an nginx container. Without this redirection, nginx would boot fine, serve a handful of requests successfully, and then fail the moment it needed to buffer a request body or a proxied response into a temp file it has nowhere permitted to create.

`try_files $uri $uri/ /index.html` is the standard single-page-app fallback pattern: any URL that doesn't correspond to a real file on disk — a client-side route like `/cart`, typed directly into the address bar, or a page refresh mid-navigation — gets served `index.html` instead of nginx's own 404 page, letting React Router take over and render the correct page entirely client-side, in the browser.

`location /health` is what both this Dockerfile's own `HEALTHCHECK` instruction and Kubernetes' `readinessProbe`/`livenessProbe` (in `k8s/base/frontend/deployment.yaml`) actually hit — a trivial, static `200 ok` that proves nginx itself is up and answering, independent of whether any specific real page would render correctly.

The four `add_header` lines are baseline browser-security headers, each worth being able to name precisely: `X-Frame-Options: SAMEORIGIN` stops this site from ever being loaded inside another site's `<iframe>` (a clickjacking defense — without it, an attacker's page could overlay invisible buttons on top of this site and trick a user into clicking something they never saw). `X-Content-Type-Options: nosniff` stops a browser from ever guessing a *different* content type than what the server explicitly declared — without it, a browser might decide to execute an uploaded file as HTML/JS purely based on its content, a real XSS vector. `X-XSS-Protection` turns on browsers' legacy built-in reflected-XSS filter (largely superseded today, but still checked by some clients, and free to include). `Referrer-Policy: strict-origin-when-cross-origin` limits how much of this site's own URL structure leaks into the `Referer` header sent along with outbound requests to other sites.

---

## Part 4: `.dockerignore` — what never even reaches the build

Every Dockerfile's build context has a matching `.dockerignore`. The backend template's:

```
node_modules
npm-debug.log
.env
.env.*
!.env.example
.git
.gitignore
*.md
```

Worth understanding precisely what "build context" means here: when you run `docker build`, the very first thing that happens — before a single instruction executes — is the entire directory gets bundled up and sent to the Docker daemon. `.dockerignore` controls what's excluded from that bundle, and it matters for two independent reasons. **Speed:** without excluding `node_modules`, every single `docker build` would first upload a potentially enormous local `node_modules` folder to the Docker daemon, before the build even starts — and every byte of that upload gets thrown away anyway, since the image gets its own fresh, `npm ci`-installed `node_modules` inside the `deps` stage regardless. **Secret-leak defense in depth:** `.env`/`.env.*` (with `!.env.example` specifically re-including the one dotenv file that's meant to be checked into git and is safe to ship) means that even if a developer has a local `.env` file sitting in their working directory with *real* credentials in it, a stray `COPY . .` instruction has no way to accidentally pull it into an image layer — it was never even part of what got sent to the Docker daemon in the first place. This project's actual runtime secrets come from Kubernetes `ExternalSecret`s, never from a `.env` file baked into an image — this is a backstop against a mistake, not the primary mechanism.

---

## Part 5: Pairing with Kubernetes `securityContext` — the story isn't finished in the Dockerfile alone

Every Dockerfile in this project creates its own unprivileged `appuser` and switches to it with `USER appuser` — but on its own, that's only half the lock. Docker's `USER` instruction sets the *default* user a container starts as; nothing in the image itself stops a Kubernetes pod spec from overriding that back to root, and nothing in the Dockerfile prevents privilege escalation, dangerous Linux capabilities, or a writable root filesystem. The real enforcement is both halves *together* — the Dockerfile makes non-root the natural, already-working default, and each service's `securityContext` (in `k8s/services/<name>/base/deployment.yaml`, or `k8s/base/frontend/deployment.yaml` for the frontend) makes it a **hard requirement** that the Kubernetes API server rejects the pod outright for violating, not merely a convention someone could quietly bypass:

```yaml
securityContext:            # pod-level
  runAsNonRoot: true
  runAsUser: 1001           # 101 for the frontend
  runAsGroup: 1001          # 101 for the frontend
  seccompProfile:
    type: RuntimeDefault
containers:
  - securityContext:         # container-level
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
```

Each field is worth being able to explain on its own, since this exact shape appears across every service in the project:

- `runAsNonRoot: true` — Kubernetes itself refuses to even *start* the pod if the resolved user ID turns out to be `0` (root). This is the backstop against the Dockerfile's own `USER appuser` line ever being silently overridden or forgotten — a structural guarantee, not a trust exercise.
- `readOnlyRootFilesystem: true` — the entire container filesystem is mounted read-only at the OS level. This is *why* the frontend's `nginx.conf` redirects every writable path to `/tmp`, and why that same Deployment mounts three separate `emptyDir` volumes at `/tmp`, `/var/cache/nginx`, and `/var/run` — an `emptyDir` is ephemeral, node-local scratch storage Kubernetes provisions fresh per-pod, giving the container exactly the specific, narrow writable paths it genuinely needs, without making the entire filesystem mutable to get there.
- `capabilities: drop: ["ALL"]` strips every Linux capability from the container process — including ones root itself would normally hold, like binding privileged network ports or changing file ownership arbitrarily. `allowPrivilegeEscalation: false` closes the door on any `setuid`/`setgid` binary or capability-granting mechanism ever letting the process claw back privileges it didn't start with.
- `seccompProfile: RuntimeDefault` applies the container runtime's default syscall filter — blocking a wide range of rarely-needed, historically exploit-prone system calls a normal application process never legitimately needs to make.

None of this is optional or best-effort in this project: a Semgrep SAST rule in CI (`.github/workflows/ci-cd.yml`'s `sast` job) actively fails the build if any container manifest is missing a `securityContext` matching this shape. `docs/TROUBLESHOOTING.md` documents the real incident this check exists to catch — a schema-init Job that shipped with its `securityContext` entirely absent.

---

## Part 6: How CI turns these Dockerfiles into images running in production

`.github/workflows/ci-cd.yml`'s `build-and-push` job builds all six images on every push to `main`, `improvements`, or `observability`, using `docker/build-push-action` on top of `docker/setup-buildx-action` (BuildKit, not Docker's legacy builder) and GitHub Actions' own persistent build cache (`cache-from`/`cache-to: type=gha`) — a service whose dependencies haven't changed since the last run reuses that cached `deps`/`builder` layer, keeping most rebuilds fast, with each service keeping its own independent cache scope rather than sharing one across services.

**The ordering that matters most in this whole file:** every image is first built with `push: false, load: true` — built and loaded into the CI runner's own local Docker daemon, *not* pushed anywhere yet. `aquasecurity/trivy-action` then scans that specific, local, unpushed image for `CRITICAL`/`HIGH` severity CVEs (`ignore-unfixed: true`, since a CVE with no patch available anywhere yet can't be actioned by changing anything in this repo, and would otherwise leave the pipeline permanently, unfixably red). If Trivy finds anything, `exit-code: "1"` hard-fails the job right there. **Only after that scan step has already succeeded** does a separate `docker push` step run — meaning an image with a known, fixable, critical vulnerability is never pushed to ECR at all, not flagged-and-shipped-anyway, genuinely never uploaded. `docs/CICD.md` (and `CICD_EXPLAINED.md`) covers the rest of the pipeline this build step feeds into — the earlier secret-scan/lint/test gates before it, and the GitOps commit + ArgoCD sync after it.

---

## Questions you should be ready for

**"Why bother deleting `npm` from the final backend image — doesn't the non-root user already stop most abuse?"**
They defend against different things. The non-root user limits what an attacker can *do* if they get code execution (no root on the container, and by extension a much smaller blast radius if they ever escape the container). Deleting `npm` limits *what tools they have available* once they're in, as an unprivileged user, executing arbitrary code — even as `appuser`, a present `npm` binary would let them attempt to download and run arbitrary packages. Removing it isn't a replacement for the non-root story, it's a second, independent layer stacked on top — the same "defense in depth" idea that shows up throughout this project's design.

**"Could you configure `REACT_APP_API_URL` at container runtime instead, the way you would for a backend service?"**
No, and being able to explain precisely *why not* is the important part: Create React App inlines every `REACT_APP_*` value into the compiled JavaScript bundle at `npm run build` time, and there is no `process.env` inside a browser at all — by the time the bundle is running in a user's browser, the value isn't a variable anymore, it's a literal string permanently baked into the file. The only way to change it is to rebuild the image with a new `--build-arg` and ship a new image — there's no environment-variable trick, no config file mounted at runtime, no way around it for a CRA app specifically.

**"What's the actual difference between this Dockerfile's `USER appuser` and Kubernetes' `runAsNonRoot: true`?"**
`USER appuser` sets the *default* — what user the container process starts as, if nothing overrides it. `runAsNonRoot: true` is a Kubernetes-enforced *requirement* — the API server checks the resolved user ID before the pod is even allowed to start, and refuses outright if it resolves to root, regardless of what any Dockerfile said. One is a default; the other is a guarantee a misconfigured or malicious pod spec can't quietly bypass.

**"Why does the frontend's `nginx.conf` redirect so many paths to `/tmp` specifically?"**
Because `readOnlyRootFilesystem: true` (Part 5) makes the entire container filesystem read-only *except* for whatever's explicitly mounted as a writable volume — and this Deployment mounts exactly one such writable location that matters here: an `emptyDir` at `/tmp`. Every nginx directive that needs to write something at runtime (temp files for buffered/proxied responses, its own pid file) has to point somewhere inside that one writable location, or nginx fails the instant it tries to write anywhere else.

**"Why is the frontend's image built from `nginx:1.27-alpine`, and not just `node:22-alpine` running something like `serve`?"**
Because once the React app is compiled, serving it is just handing static files over HTTP — a job nginx is purpose-built for, battle-tested at, and far lighter weight for than running a Node process just to do the same thing. Carrying a full Node runtime into an image whose only remaining job is serving pre-built static files would be extra size and extra attack surface for zero functional benefit.

## Related

- [`CICD_EXPLAINED.md`](CICD_EXPLAINED.md) — how `build-and-push` builds, scans, and ships these exact images, step by step
- [`KUBERNETES_EXPLAINED.md`](KUBERNETES_EXPLAINED.md) — the Deployments and `securityContext` blocks each image runs under
- [`ARCHITECTURE_EXPLAINED.md`](ARCHITECTURE_EXPLAINED.md) — how these six images map onto the platform as a whole
- The real docs this was built from: `../docs/CICD.md`, `../docs/KUBERNETES.md`, `../docs/TROUBLESHOOTING.md` (OBS-019, OBS-033, OBS-041), and the Dockerfiles themselves — `../client/Dockerfile`, `../services/*/Dockerfile`
