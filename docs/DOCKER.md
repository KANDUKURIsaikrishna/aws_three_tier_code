# Docker

How the container images in this project are built, why each Dockerfile looks the way it does, and how that pairs with the Kubernetes `securityContext` each image runs under.

## Inventory

Six Dockerfiles, two distinct shapes:

| File | Base image(s) | Shape |
|---|---|---|
| `client/Dockerfile` | `node:22-alpine` → `nginx:1.27-alpine` | React static build, served by nginx |
| `services/catalog-service/Dockerfile` | `node:22-alpine` → `node:22-alpine` | Express API |
| `services/user-service/Dockerfile` | `node:22-alpine` → `node:22-alpine` | Express API |
| `services/notification-service/Dockerfile` | `node:22-alpine` → `node:22-alpine` | Express API |
| `services/order-service/Dockerfile` | `node:22-alpine` → `node:22-alpine` | Express API |
| `services/api-gateway/Dockerfile` | `node:22-alpine` → `node:22-alpine` | Express API |

The five backend Dockerfiles are **byte-for-byte identical** — same stages, same instructions, in the same order, no per-service customization at all. This is deliberate, not an oversight: every backend service is a plain Express app with the same dependency-install-then-run shape, so one proven template is copy-pasted per service rather than each one drifting independently. `docs/CICD.md` documents the same "copy-paste-and-rename, not a matrix loop" choice for the CI workflow that builds these — both decisions trade a small amount of duplication for every service's Dockerfile (and its CI build block) being readable on its own, without cross-referencing a shared template file to understand what actually runs.

Every image is **multi-stage** (a `deps`/`builder` stage that installs dependencies or builds artifacts, discarded from the final image) and **non-root** (a dedicated `appuser`, never the container's default root user). Both are why the final images are small and don't carry a full toolchain into production.

## The shared backend template

This exact file is `services/catalog-service/Dockerfile`, `user-service/Dockerfile`, `notification-service/Dockerfile`, `order-service/Dockerfile`, and `api-gateway/Dockerfile` — read once, applies to all five.

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

**Stage 1 — `deps`.** `COPY package*.json ./` copies only `package.json` and `package-lock.json`, not the rest of the source, specifically so Docker's build cache stays valid across source-code changes — as long as dependencies haven't changed, this whole stage (the slowest part of any Node build) is skipped on rebuild. `npm ci` (not `npm install`) installs exactly what `package-lock.json` specifies, byte-for-byte, and fails outright if the lockfile and `package.json` disagree — the correct choice for a reproducible CI build, where "whatever the latest compatible version happens to be today" is exactly what you don't want. `--omit=dev` skips `devDependencies` entirely (test frameworks, linters — nothing a running container needs). `npm cache clean --force` clears npm's own download cache from this stage's filesystem layer; it doesn't shrink the final image (this whole stage is discarded), but it does keep this intermediate layer itself smaller, which matters for CI build/cache-push time (`docs/CICD.md`'s `cache-to: type=gha,mode=max` persists every layer, this one included).

**Stage 2 — `runtime`.** Starts from a fresh `node:22-alpine`, not `FROM deps` — nothing from stage 1 except `node_modules` (copied explicitly below) makes it into the final image; the `deps` stage's own `npm` cache, build tools, and layer history are gone.

- `apk upgrade --no-cache` patches any OS-level packages in the base image that have security fixes since that image tag was published, without leaving apk's own package index cached in the layer.
- `addgroup -S appgroup && adduser -S appuser -G appgroup` creates a dedicated, unprivileged system user (`-S`: no password, no home directory, not meant for interactive login) instead of running as the image's default `root`. This is the Dockerfile half of a two-part non-root story — see [Pairing with Kubernetes](#pairing-with-kubernetes-securitycontext) below for the other half.
- `COPY --from=deps --chown=appuser:appgroup /app/node_modules ./node_modules` pulls in exactly the production dependencies installed in stage 1, owned by the new user from the moment they land in this layer (not `COPY` then a separate `RUN chown`, which would double the layer size by writing the files twice).
- `COPY --chown=appuser:appgroup . .` copies the actual application source (respecting `.dockerignore`, below).
- The `rm -f package-lock.json package.json && rm -rf .../npm .../npx .../corepack` line is the most unusual part of this template: it deletes the lockfile and manifest from the final image, then deletes `npm`, `npx`, and `corepack` themselves from the base image's own install location. Once `npm ci` has already run and `node_modules` is populated, nothing at runtime needs `npm` at all — `node index.js` doesn't shell out to it. Removing it is a real, if modest, attack-surface reduction: no package manager present means no plausible path to "an attacker with code execution inside this container runs `npm install <malicious-package>`" — there's no `npm` binary left to run.
- `USER appuser` switches the effective user for every instruction after this line, and for the container process itself, away from root.
- `EXPOSE 3000` is documentation, not enforcement — every backend service's Express app listens on `3000` (`api-gateway`'s own public-facing port is different at the Kubernetes `Service`/`Ingress` layer, but the container itself still listens on `3000` internally).
- `HEALTHCHECK` is a Docker-native liveness check, independent of Kubernetes' own `livenessProbe`/`readinessProbe` (defined separately in each service's `k8s/services/<name>/base/deployment.yaml`) — this one matters for anyone running the image directly with `docker run` or `docker compose` outside Kubernetes entirely (e.g. local development), where nothing else would be watching container health. `wget` is used because Alpine's minimal image doesn't ship `curl` by default and adding it just for a healthcheck isn't worth the extra layer.
- `CMD ["node", "index.js"]` runs the app directly — no `npm start` wrapper, which would spawn an extra shell/npm process for no benefit once `npm` itself has been removed from the image anyway.

## The frontend Dockerfile

`client/Dockerfile` is structurally different from the backend template because it does two genuinely different jobs: compile a React app into static files, then serve those files with nginx — a webserver, not a Node process.

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

**Stage 1 — `builder`.** `npm ci` here installs *all* dependencies, not `--omit=dev` like the backend template — a React build genuinely needs its dev toolchain (the bundler, Babel, etc.) to produce the static output; none of that matters once the build is done, since this whole stage is discarded. `COPY . .` happens *after* `npm ci`, same cache-friendly ordering as the backend template.

The `ARG`/`ENV` pair is the one part of this Dockerfile that needs explaining, because it's easy to assume a React app's API URL could be configured at container *runtime* the way a backend service's environment variables are — it can't. Create React App inlines every `REACT_APP_*` variable directly into the compiled JavaScript bundle at `npm run build` time; there is no runtime `process.env` inside a browser. That means `REACT_APP_API_URL` has to be known and baked in at **image build time**, which is exactly what `ARG REACT_APP_API_URL` (a build-time input, set via `docker build --build-arg`) followed by `ENV REACT_APP_API_URL=$REACT_APP_API_URL` (making that same value visible to the `npm run build` process, since `ARG` alone isn't exported to child processes) accomplishes. In this project's CI (`.github/workflows/ci-cd.yml`), that build arg is populated from the `API_URL` GitHub secret — meaning **a new frontend image must be built any time the gateway's public URL changes**, since the old image's bundle would keep pointing at whatever URL was baked in when it was built. There is no way to point an already-built frontend image at a different API URL without rebuilding it.

**Stage 2 — `runner`.** Starts fresh from `nginx:1.27-alpine`, a purpose-built webserver image, not another `node:22-alpine` — there's no reason to carry a full Node runtime into an image whose only job is serving already-compiled static files.

- `COPY --from=builder /app/build /usr/share/nginx/html` copies just the compiled output (typically a few hundred KB to a few MB of HTML/JS/CSS) — nothing from `node_modules`, no source `.jsx` files, none of the build tooling.
- `COPY nginx.conf /etc/nginx/nginx.conf` replaces nginx's own default config entirely with this project's own (below).
- The `chown -R` block, followed by `touch`+`chown` on the pid file specifically, exists because nginx's default image runs a startup sequence that expects to *write* to `/var/cache/nginx`, `/var/log/nginx`, and its own pid file — all of which need to belong to `appuser` before `USER appuser` takes effect a few lines later, or nginx would fail to start under a non-root user with a permission error on its very first write.
- `EXPOSE 8080`, not the conventional `80` — nginx normally binds `80` by default, but binding any port below `1024` requires root privileges on Linux (the `CAP_NET_BIND_SERVICE` capability), which this container deliberately doesn't have (see [Pairing with Kubernetes](#pairing-with-kubernetes-securitycontext)). `8080` is nginx's own listen port, configured to match in `nginx.conf`.
- `CMD ["nginx", "-g", "daemon off;"]` runs nginx in the foreground (`daemon off`) — a containerized process manager (Docker, and in turn Kubernetes) needs to be able to see and manage the actual server process directly, not a background daemon it forked and then exited, which would make the container appear to have "finished" immediately after start.

### `nginx.conf`

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

Every `*_temp_path` directive, plus the `pid` directive itself, points at `/tmp` — nginx's own defaults point these at locations under `/var/run` and `/var/lib/nginx` that this container's Kubernetes `securityContext` (below) won't let it write to. Redirecting all of them to `/tmp` (backed by a writable `emptyDir` volume at runtime — see the next section) is what actually makes `readOnlyRootFilesystem: true` viable for an nginx container at all; without this, nginx would fail on its first request the moment it needed a temp file for a proxied or buffered response.

`location / { try_files $uri $uri/ /index.html; }` is the standard single-page-app fallback: any URL that doesn't match a real file on disk (e.g. a client-side route like `/cart` typed directly into the address bar, or a page refresh) gets served `index.html` instead of nginx's own 404, letting React Router take over and render the right page client-side.

`location /health` is what both this Dockerfile's own `HEALTHCHECK` and the Kubernetes `readinessProbe`/`livenessProbe` in `k8s/base/frontend/deployment.yaml` actually call — a static `200 ok` response that proves nginx itself is alive and serving, independent of whether a real user's request would succeed.

The four `add_header` lines are baseline security headers: `X-Frame-Options: SAMEORIGIN` blocks this site from being embedded in another site's `<iframe>` (clickjacking defense), `X-Content-Type-Options: nosniff` stops the browser from guessing a different MIME type than what the server declared (an XSS vector if a browser decides to treat an uploaded file as HTML), `X-XSS-Protection` enables browsers' built-in (now largely legacy, but still checked by some) reflected-XSS filter, and `Referrer-Policy: strict-origin-when-cross-origin` limits how much of this site's own URLs leak into the `Referer` header of outbound requests to other origins.

## Pairing with Kubernetes `securityContext`

Every one of this project's Dockerfiles creates its own unprivileged `appuser` and switches to it with `USER appuser` — but that alone doesn't fully lock a container down. Docker's `USER` instruction sets the *default* user the container process starts as; nothing stops a Kubernetes pod spec from overriding it back to root, and nothing in the Dockerfile itself prevents privilege escalation, capability abuse, or a writable root filesystem. The actual enforcement is the *pairing* of both halves — the Dockerfile makes non-root the natural, working default, and each service's `securityContext` in `k8s/services/<name>/base/deployment.yaml` (or `k8s/base/frontend/deployment.yaml` for the frontend) makes it a hard requirement the Kubernetes API rejects the pod outright for violating:

```yaml
securityContext:            # pod-level
  runAsNonRoot: true
  runAsUser: 1001           # 101 for frontend
  runAsGroup: 1001          # 101 for frontend
  seccompProfile:
    type: RuntimeDefault
containers:
  - securityContext:         # container-level
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
```

`runAsNonRoot: true` makes Kubernetes itself refuse to start the pod if the resolved user ID is `0` (root) — a backstop against the Dockerfile's own `USER appuser` line ever being silently reverted or overridden. `readOnlyRootFilesystem: true` is why the frontend's `nginx.conf` redirects every writable path to `/tmp`, and why that same deployment mounts three `emptyDir` volumes at `/tmp`, `/var/cache/nginx`, and `/var/run` specifically — an `emptyDir` is ephemeral, node-local scratch storage that Kubernetes provisions per-pod, giving the container the *specific*, *limited* writable paths it actually needs without making the whole filesystem writable. `capabilities: drop: ["ALL"]` removes every Linux capability (including ones root itself would normally have, like binding privileged ports or changing file ownership) from the container process, and `allowPrivilegeEscalation: false` blocks any `setuid`/`setgid` binary or capability-granting mechanism from letting the process regain privileges it started without. `seccompProfile: RuntimeDefault` applies the container runtime's default syscall filter, blocking a range of rarely-needed, historically exploit-prone syscalls.

None of this is optional or best-effort in this project: `k8s/base/limitrange.yaml` and each service's own `LimitRange` combine with a Semgrep SAST rule in CI (`.github/workflows/ci-cd.yml`'s `sast` job) that fails the build outright if any container manifest is missing `securityContext` fields matching this shape — see `docs/TROUBLESHOOTING.md` for the specific incident (a schema-init Job's `securityContext` being entirely absent) that this check exists to catch.

## `.dockerignore`

Every Dockerfile's build context has a matching `.dockerignore` (`client/.dockerignore`, and one per backend service). The backend template's:

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

`node_modules` is excluded from the build *context* sent to the Docker daemon — not the same thing as the final image not containing it (the image gets a fresh, `npm ci`-installed `node_modules` inside the `deps` stage instead). Skipping it here matters for build speed: without this, every `docker build` would first upload a potentially enormous local `node_modules` directory to the Docker daemon before the build even starts, only to have every byte of it ignored anyway. `.env`/`.env.*` (with `!.env.example` re-including the one dotenv file that's meant to be checked in and safe to ship) is a defense-in-depth measure against ever accidentally baking real secrets into an image layer — this project's actual secrets come from Kubernetes `ExternalSecret`s at runtime, never from a `.env` file inside the image, but excluding them from the build context means there's no path by which a stray local `.env` with real credentials could end up copied into an image by a `COPY . .` instruction, even by accident.

## How CI builds and ships these images

`.github/workflows/ci-cd.yml`'s `build-and-push` job builds all six images on every push to `main`/`improvements`/`observability`, using `docker/build-push-action` with `docker/setup-buildx-action` (BuildKit, not the legacy builder) and GitHub Actions' own build cache (`cache-from`/`cache-to: type=gha`) — a service whose dependencies haven't changed reuses the `deps`/`builder` stage's cached layers across CI runs, keeping most rebuilds fast even though nothing is cached between different services (each has its own cache scope).

Each image is built with `push: false, load: true` first — built and loaded into the runner's local Docker daemon, *not* pushed to ECR yet — specifically so **Trivy can scan it before anything reaches the registry**. `aquasecurity/trivy-action` scans for `CRITICAL`/`HIGH` severity CVEs (`ignore-unfixed: true`, since a CVE with no available fix yet can't be actioned by changing anything in this repo) and hard-fails the whole job (`exit-code: "1"`) if any are found — an image with a known-fixable critical vulnerability never gets pushed to ECR at all, let alone deployed. Only after a scan passes does a separate `docker push` step ship that specific image. `docs/CICD.md` covers the full pipeline (SAST, the `deploy` job's GitOps commit, ArgoCD sync) this build step feeds into.

## Related

- [`CICD.md`](CICD.md) — the full pipeline these builds run inside
- [`KUBERNETES.md`](KUBERNETES.md) — the manifests each image's `securityContext` pairs with
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — how these six images map to the platform's services
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — OBS-019 (a `devDependencies`-vs-`dependencies` bug that shipped a broken production image), OBS-033 (`docker-compose-plugin` not in Ubuntu's default apt repo, relevant to the monitoring EC2's own Docker Compose setup, not these Dockerfiles directly), OBS-041 (Docker's own apt repo never adds a user to the `docker` group, unlike `docker.io`)
