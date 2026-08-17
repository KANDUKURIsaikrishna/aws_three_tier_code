# The Architecture, Explained Like You're Teaching It

This file exists for one reason: so you can explain this project out loud, to a person who has never seen it, without stumbling. Not "what does the code do" — "why does the code do it this way, and what would you have done differently if you couldn't." If you can't answer the "why," you don't actually know it yet, you've just read it. So every section below leads with the plain-English idea, then the AWS mechanics, then the questions someone will actually ask you.

**The one-sentence version, if someone stops you in a hallway:** *"It's an online bookstore split into small independent services, running on Kubernetes on AWS, where every piece — the network, the database, the monitoring, the deployments — is defined as code, not clicked together by hand."*

That single sentence contains the three ideas everything else hangs off of:
1. **Microservices** — not one big program, several small ones that each own one job.
2. **Kubernetes on AWS (EKS)** — a system that keeps those small programs running, restarts them when they crash, and gives them a network to talk to each other over.
3. **Infrastructure as Code (Terraform)** — the AWS resources (network, database, servers) aren't created by clicking in the AWS Console, they're described in text files, and a tool builds exactly what the text says, every time, identically.

Everything below expands on those three ideas.

---

## Part 1: What is this thing, actually?

It's a bookstore. Someone can browse books, register an account, log in, add books to a cart, check out, and see their order history. That's the entire product. The interesting part isn't the bookstore — it's *how* it's built, because it's built the way a real company would build something that needs to stay up, scale, and be safe to change.

### Why split it into 5 services instead of 1 program?

The old version of this project was one program (a "monolith") that did everything — served the webpage, handled logins, handled the book catalog, handled orders. That's simpler to build but has a real cost: if you want to change how logins work, you have to redeploy the *entire* program, including the catalog code that has nothing to do with logins. If the order code has a memory leak, it can crash the whole thing, including the part that just shows book listings.

This project deliberately split into 5 independent programs, each doing exactly one job:

| Service | Its one job | Talks to |
|---|---|---|
| `catalog-service` | Store and serve the list of books (CRUD) | its own database only |
| `user-service` | Register/login, issue login tokens | its own database only |
| `order-service` | Shopping cart, checkout, order history | its own database, calls `notification-service` |
| `notification-service` | Record "an order happened, notify someone" | its own database only, called by `order-service` |
| `api-gateway` | The single front door — every request from the browser goes through here first | all four services above, nothing else |

Plus a `frontend` — the actual webpage (React), which is just static files (HTML/CSS/JS) served to the browser. The browser's JavaScript then talks to `api-gateway` directly.

**Why this specific split, and not some other split?** Each service owns exactly one business capability and one database. If `order-service` has a bug, you can fix and redeploy *only* `order-service` — nobody touches catalog code, nobody restarts the login system. If checkout traffic spikes on launch day, you can run more copies of *just* `order-service` and `api-gateway`, without wasting money running more copies of `notification-service`, which nobody's hammering.

**The tradeoff, and you should say this out loud if asked "why not more services or fewer":** more services means more network calls between them, more things that can go wrong independently, more deployments to coordinate. Five is a deliberate middle ground — enough to isolate the real business boundaries (identity, catalog, ordering, notification, and the public-facing router), not so many that you're managing complexity for its own sake. The project's own design notes explicitly ruled out going further (a message queue instead of a direct HTTP call, separate database *servers* instead of separate database *schemas* on one shared server, a service mesh for encrypted service-to-service traffic) — not because those are bad ideas, but because they're not needed yet, and adding them now would be solving a problem you don't have.

### Why does every request go through one "gateway" instead of the browser talking to each service directly?

Picture the alternative: the browser knows 4 different addresses (one per backend service) and has to decide which one to call for which action, and each of those 4 services has to independently check "is this person logged in?" That's four places to get security wrong, four places to configure CORS, four public URLs to expose to the internet.

Instead: the browser only ever knows one address — `api-gateway`. The gateway is the only service that's reachable from outside the cluster (through the load balancer and the ingress controller). It does exactly two jobs: **check the login token**, then **forward the request** to whichever internal service owns that data. The internal services (`catalog-service`, `user-service`, `order-service`, `notification-service`) are not reachable from the internet at all — a Kubernetes NetworkPolicy (explained in Part 3) makes that a hard technical rule, not just a convention nobody bothers to violate.

**This is called the "API Gateway pattern."** It's one of the most common patterns in real microservice systems, and it's the right thing to name if someone asks "what pattern is this."

### How does login actually work, end to end?

This is the single most-asked "walk me through it" question, so know it cold:

1. User types email/password into the React login page, clicks submit.
2. The browser sends `POST /auth/login` to `api-gateway`.
3. `api-gateway` sees `/auth/*` requires no token (you can't be logged in yet if you're trying to log in) and forwards the raw request to `user-service`.
4. `user-service` looks up the email in its own database, checks the password against a stored *hash* (never the plaintext — more on this below), and if it matches, creates a **JWT** — a signed token containing the user's ID and email, valid for 1 hour — and sends it back.
5. The browser saves that token (in `localStorage`) and attaches it to every future request as an `Authorization: Bearer <token>` header.
6. From then on, every request to `api-gateway` gets its token checked. If valid, the gateway extracts the user ID from inside the token and passes it along to whichever internal service handles the request, via a custom header (`x-user-id`) — so `order-service`, for instance, always knows *whose* cart it's touching, without ever seeing the password or needing to independently verify the login.

**Why a JWT and not, say, a database-backed session?** A JWT is self-contained and signed — any service holding the shared secret can verify "yes, this token is genuine and says userId=42" without making a database call or a network call to `user-service` to ask "is this session still valid?" That's what makes the stateless, horizontally-scalable microservice pattern work: no service needs to share session state with any other service. The tradeoff, worth knowing cold: **a bare JWT can't be instantly revoked** — a plain, single-token design (which this project used to run) means a stolen token keeps working until it naturally expires, no "kill this session now" button, because there's no session, just a signed piece of paper.

**What this project actually does about it now — short-lived access token + rotating refresh token:** the JWT (`token`) that gets attached to every API call is now short-lived — 15 minutes, not the original 1 hour — which shrinks how long a stolen one stays dangerous, but doesn't by itself give you a revoke button. The revoke button is a *second*, completely different kind of token, the **refresh token**: 48 random bytes, never a JWT, never decoded or trusted on its own — every single use is looked up directly against a database table (`user_db.refresh_tokens`), by the SHA-256 hash of the token (never the raw value — same reasoning as password hashing: a stolen database row shouldn't be a usable credential). Logging in returns *both* tokens. When the short-lived access token expires, the frontend silently exchanges the refresh token for a new pair — the user never notices, no re-login prompt — through a new `POST /auth/refresh` endpoint. And now there genuinely is a "kill this session" button: `POST /auth/logout` marks that one refresh token's database row revoked, and from that instant it can never mint another access token — the only thing that still works for a few more minutes is whatever access token had already been issued off it, not a fresh hour-long grant.

**Why rotate the refresh token on every use, instead of reusing the same one for 7 days?** Every call to `/auth/refresh` revokes the refresh token that was just presented and issues a brand-new one in the same response. That means a refresh token can only ever be used exactly once before it's replaced — if an attacker ever managed to steal one but the real user's browser refreshes first (which happens automatically, silently, every 15 minutes), the stolen copy is already dead the moment they try to use it. This is the standard "refresh token rotation" pattern, and knowing to name it that is worth doing if asked.

**Why a refresh-token pattern instead of a blocklist (the other standard answer to "how would you add revocation")?** A blocklist needs to be checked on *every single request* that verifies a token — and in this system, that's almost entirely `api-gateway`, which is deliberately designed to be a pure, stateless reverse proxy with **no database connection of its own at all**. Giving the gateway a database just to check a blocklist would be a bigger, more invasive architectural change than adding two endpoints to `user-service`, which already owns both the database and the entire auth story. Refresh tokens keep the gateway exactly as stateless as it always was — the only thing that changed is how the *client* gets a new access token, not how any service verifies one. That's the kind of tradeoff reasoning worth walking someone through, not just naming the pattern you picked.

**Why is the password hashed, and what does "hashed" actually mean here?** The database never stores the password itself — it stores the output of a one-way function (`bcrypt`) run on the password. You cannot reverse a bcrypt hash back into the original password; the only way to check a password is correct is to hash the *attempt* and compare hashes. If the database were ever stolen, an attacker gets a pile of hashes, not passwords. `bcrypt` is deliberately *slow* (by design — it does thousands of internal rounds), which is a feature: it makes brute-forcing millions of guesses per second computationally expensive, unlike a fast hash like MD5 or SHA-256, which would be a bad choice for passwords specifically.

**One more subtlety worth knowing:** when someone logs in with an email that doesn't exist at all, the service still runs a fake bcrypt comparison against a dummy hash before returning "invalid credentials" — instead of returning that error instantly. Why? If a wrong-password attempt takes 200ms (real bcrypt work) but a wrong-email attempt returns instantly, an attacker can tell the two failures apart just by timing the response — which email addresses exist in your system just from how long the server takes to say no. This is called a **timing attack**, and the dummy-hash trick closes it.

### How does checkout work, end to end?

The second most-asked "walk me through it":

1. Browser sends `POST /orders/checkout` (no request body — it operates on whatever's already in the user's cart).
2. Gateway checks the JWT, forwards to `order-service` with the user's ID attached.
3. `order-service` reads every row in that user's cart, and if the cart is empty, stops here and returns an error.
4. If there's something to order: it opens a **database transaction** — meaning "do all of the following as one atomic unit, and if anything fails partway through, undo everything" — inserts one `orders` row per cart item, then deletes all the cart rows, then commits the transaction.
5. It immediately responds `201 Created` to the browser with the new orders. **The browser gets its answer right here — the user is not waiting on anything that happens next.**
6. *After* that response has already gone out, `order-service` makes a best-effort call to `notification-service` (`POST /notify`) for each order, to log that a notification should go out. This call has a 2-second timeout, and if it fails for any reason, nothing rolls back and the user never even knows — it just increments an internal failure counter that shows up in monitoring.

**Why is the notification call "fire-and-forget" instead of something the user waits on?** Because sending a notification is not essential to the order succeeding — the order is real and paid for the moment the database transaction commits. If `notification-service` were down, you would *not* want checkout to fail just because a receipt email couldn't be logged. This is a deliberate design choice called **decoupling non-critical side effects from the critical path**. The honest tradeoff to name if asked: today this is a direct HTTP call with a timeout, not a durable queue — if `notification-service` is down for the whole 2-second window, that notification is just gone, nothing retries it later. A production system that actually needed guaranteed delivery would put a real message queue (SQS, for example) between the two services, so the notification survives even if the receiving service is temporarily down. This project's own roadmap notes that as a known, deliberately deferred next step — not a bug nobody noticed.

**Why does the transaction matter here specifically?** Imagine the alternative: insert order rows one by one, then delete cart rows one by one, no transaction. If the server crashed halfway, you could end up with *some* items ordered and *others* still sitting in the cart and *also* already ordered — the user could pay twice for the same book, or lose an item entirely. The transaction guarantees it's all-or-nothing: either every item that was in the cart becomes an order and the cart is emptied, or (if anything goes wrong) none of it happens and the cart is untouched, ready to retry.

---

## Part 2: The AWS services — what we use, and why that one and not an alternative

This is the part most likely to get grilled in an interview: for every AWS service, know what it does, and know what the *next-most-obvious alternative* would have been and why it wasn't chosen.

### Amazon EKS (Elastic Kubernetes Service) — where the code actually runs

**What it is, plainly:** Kubernetes is a system for running lots of small programs (containers) across a group of servers, automatically restarting them if they crash, spreading them across servers for reliability, and giving them a private network to find and talk to each other. EKS is AWS's managed version of Kubernetes — AWS runs and patches the hard, fiddly "control plane" part (the brain that makes scheduling decisions) so you don't have to.

**Why EKS instead of, say, plain EC2 instances with a load balancer, or AWS's simpler container service (ECS)?** Three real reasons, in order of how likely you are to be asked:
1. Kubernetes is the industry-standard way to run microservices at any real scale, and this project exists partly as a learning/reference platform for that pattern — so it's the "if you're going to learn one thing, learn the one everyone uses" choice.
2. It gives you self-healing (a crashed pod gets automatically replaced), rolling updates (deploy a new version without downtime), and horizontal auto-scaling (more copies of a service under load) essentially for free, as built-in primitives — you'd have to hand-build all of that yourself on raw EC2.
3. ECS (AWS's own alternative) is real and simpler, but it's AWS-proprietary — the skills and manifests don't transfer to another cloud. Kubernetes runs the same way on any cloud, which matters if "portable, industry-standard skills" is part of the point.

**The honest cost/complexity tradeoff to name:** Kubernetes has a real learning curve and a real minimum operational overhead — the control plane alone (which AWS runs for you) costs money per hour regardless of how small your workload is, and a 3-node cluster like this one is genuinely oversized for a bookstore with a handful of users. That's a known, accepted cost of choosing "the way real companies do it" over "the cheapest possible way to serve one webpage."

### Amazon VPC (Virtual Private Cloud) — the private network everything lives inside

**Plainly:** before you can run anything in AWS, you need a private network — an isolated slice of AWS's network, with your own address ranges, that nothing outside can reach unless you explicitly allow it. That's a VPC. This project's VPC uses the address range `170.20.0.0/16`, which is just a way of saying "every address from 170.20.0.0 to 170.20.255.255 belongs to us" — about 65,000 possible addresses, split up into smaller chunks called subnets.

**Why subnets, and why 8 of them?** A subnet is a smaller slice of that address range, tied to one physical Availability Zone (AWS's term for an independent physical data center — see below). This project has:
- 2 **public** subnets (one per AZ) — anything here can have a direct path to the internet. This is where the load balancer and the monitoring server live.
- 6 **private** subnets (4 for Kubernetes worker nodes, 2 for the database) — nothing here has a direct internet address. They can *reach out* to the internet (for things like pulling container images) only through a controlled choke point (the NAT Gateway, below), and nothing on the internet can reach *in* to them directly.

**Why split private subnets between EKS nodes and RDS specifically, instead of one shared private subnet?** Two separate reasons worth naming: (1) it lets you write a tight security rule — "only things in the EKS-node subnets may talk to the database on port 3306" — instead of a looser "anything in any private subnet" rule; and (2) RDS Multi-AZ (explained below) specifically wants its two copies in two different subnets in two different AZs, so it needs its own dedicated pair.

**What's an Availability Zone, and why does this project use two?** An AZ is effectively a separate physical building — its own power, cooling, network — inside one AWS Region. If one AZ has a power outage or a fire, the other one is unaffected. Spreading resources across two AZs means the whole system doesn't go down because of one building's bad day. This project has resources in `us-west-1a` and `us-west-1c`.

### The Internet Gateway and the NAT Gateway — two different doors, don't confuse them

This is a very commonly confused pair, and knowing the difference cleanly is worth memorizing.

**Internet Gateway (IGW):** attaches to the VPC itself, once, and is the door that lets traffic flow *both directions* — in and out — for anything in a *public* subnet. It's how the internet reaches the load balancer, and how the load balancer reaches back out.

**NAT Gateway:** sits inside a public subnet, and its job is to let things in *private* subnets reach *out* to the internet (to pull a container image from ECR, for instance) **without** the internet being able to reach *in* to them. Traffic from a private subnet goes: private subnet → NAT Gateway → Internet Gateway → internet. The private resource's real address is never exposed — the NAT Gateway's address is what the outside world sees, and any response comes back the same traced path.

**Why does this project have only one NAT Gateway instead of one per AZ (the normal production recommendation)?** Cost, explicitly and admittedly. A NAT Gateway has an hourly cost *and* a per-gigabyte data-processing cost, and running two doubles both. Having only one means: if that NAT Gateway's Availability Zone has a problem, *outbound* internet access breaks for private-subnet resources in the *other* AZ too, even though those resources themselves are fine. This is a real, acknowledged single point of failure, kept as a deliberate cost tradeoff for what's explicitly a demo/reference deployment — say so plainly if asked, don't pretend it's not a gap.

**What's the S3 Gateway Endpoint that got added later, and why?** ECR (where container images live) actually stores the image *data* in S3 behind the scenes. Without a special exception, every image pull from a private-subnet Kubernetes node would travel out through the NAT Gateway, incurring its per-gigabyte fee, just to reach an AWS service that's not really "the internet" at all — it's another part of AWS. A **VPC Gateway Endpoint** is a free, direct private route from your VPC straight to S3 that never touches the NAT Gateway or the public internet at all. Adding it was a pure cost optimization: same functionality, less money, because it removes real (paid) traffic from the NAT Gateway's data-processing bill.

### Elastic Load Balancing — three load balancer types in this project's history, and why the story doesn't end at "pick a better one"

**Plainly:** a load balancer sits in front of your application and spreads incoming traffic across however many copies of your app are running, and also gives you one stable public address instead of exposing individual servers directly.

This is one of the best real examples in the whole project of a fact changing out from under a decision that seemed settled — worth knowing the full arc, not just where it landed, because "I found the real problem was bigger than the first fix" is a much stronger interview answer than just naming the final architecture.

**Chapter 1 — the Classic ELB, an accident, not a choice.** This project's load balancer used to be AWS's **Classic Load Balancer** — the oldest, least capable type AWS offers (no static IP, weaker health-check model, generally considered legacy). Kubernetes' built-in "give me a load balancer" mechanism defaults to the Classic type unless you explicitly tell it otherwise, and this project originally didn't. Multiple older versions of this project's own documentation incorrectly called it an "NLB" the whole time — a documentation bug that only got caught once someone actually checked with the AWS CLI what was really running.

**Chapter 2 — a real, working NLB fix, planned but never applied.** The obvious next step: one Service annotation (`service.beta.kubernetes.io/aws-load-balancer-type: nlb`) on the same Service the ingress controller already ran, no new component to install. ALB was considered and rejected at this point specifically because it can only be provisioned through the AWS Load Balancer Controller via a native `Ingress` object — not a plain `type: LoadBalancer` Service — which looked like a much bigger change than the actual problem (wrong load-balancer type) justified. This fix was fully written and validated... and then never applied, because of Chapter 3.

**Chapter 3 — the real problem was one level up: the ingress controller itself, not just its default load-balancer type.** A direct follow-up question — "isn't the ingress controller itself outdated?" — led to checking, and the answer was a serious, time-sensitive fact: **ingress-nginx, the controller this project had run its entire history, was officially retired by the Kubernetes project on 2026-03-31.** The repository is read-only. No more bug fixes. No more CVE patches, ever, for a component that terminates TLS and sits directly on the public internet — roughly half of all cloud-native environments ran this exact controller. AWS's own official migration guidance names the fix directly: install the **AWS Load Balancer Controller** and move to it. The moment that became the real, dominant issue, Chapter 2's NLB annotation stopped being the right fix — it would have kept the actual problem (an unmaintained, unpatched, internet-facing component) fully in place, just fronted by a marginally better load-balancer type. And once a controller replacement was unavoidable anyway, **ALB stopped being the "bigger" option and became the natural one** — it's the first-class path the AWS Load Balancer Controller is built around, the one AWS's own guidance leads with; installing the controller was work that had to happen regardless of NLB vs. ALB, so the earlier "ALB means a bigger change" reasoning no longer applied once that premise changed.

**The mechanical result:** TLS moved too — off cert-manager and Let's Encrypt (which had exactly one consumer in this project, the ingress certificate, and nothing left to do once that consumer was gone) and onto a real ACM certificate the AWS Load Balancer Controller auto-discovers by matching Ingress hostnames, no manual wiring needed. And a real, separate bug got caught in the process, purely by *building* the Kubernetes manifests and reading the output instead of just diffing source: the NetworkPolicy files still only allowed ingress from a pod in an `ingress-nginx` namespace — but an ALB in direct-to-pod mode doesn't route through any pod or namespace at all, it connects from its own network interfaces sitting in the VPC. Left as-is, that would have silently blocked all real traffic to the app the moment it went live, a very different and much worse kind of outage than "the annotation is wrong."

**The real cost of making a fix like this on a live system, worth naming if asked "why not fix this immediately when you found it":** changing how a Kubernetes Service or Ingress provisions its load balancer makes the cloud provider tear down the old one and provision a brand-new one — with a **new DNS name**. That's real, several-minutes downtime while the swap happens, true of both the abandoned NLB fix and the real ALB one that replaced it, and it's why this project's own docs explicitly flagged it as "not a change to make casually on a live stack," reviewed a `terraform plan` first, and held for an explicit go-ahead before ever running it — not fixed reflexively the moment either version was noticed.

**Chapter 4 — the plan being "validated" didn't mean the plan was complete; three more real bugs only showed up when it actually ran.** `terraform plan` and `terraform validate` catch syntax and dependency-graph problems — they cannot catch "this AppProject was never wired into Terraform at all" or "this wildcard certificate doesn't cover a second-level subdomain," because both of those are only wrong at *runtime*, against real DNS and a real cluster, not at plan time. All three surfaced on the very next from-scratch `terraform destroy` + `apply` cycle, the first time this exact migration was tested end-to-end rather than just planned:

- **The registrar wasn't pointed at the new zone.** `terraform destroy` deletes the Route53 public hosted zone along with everything else; the next `apply` creates a *brand-new* zone with brand-new, randomly-assigned nameserver values — Route53 never reuses a domain's old ones. ACM's DNS validation checks *public* DNS resolution, not Route53 directly, so until the domain's registrar (GoDaddy, here) was manually pointed at the new zone's NS values, no public resolver could ever see the validation records, and the ACM certificate sat in `PENDING_VALIDATION` for over an hour — well past ACM's typical few-minutes validation time — before anyone noticed why.
- **The ArgoCD `AppProject` had never actually been wired into Terraform.** `k8s/argocd/appproject.yaml` (see the Kubernetes doc's section on it) was written with a manual bootstrap instruction in its own header comment — apply it by hand, once, before the `Application`/`ApplicationSet`. `argocd.tf` got updated to Terraform-manage those other two files at the time, but never this one. Invisible on a long-lived cluster, where the AppProject just sits there once created by hand — it became a real outage the moment the whole cluster came up from scratch, because nothing this time ever created it, and every ArgoCD `Application` in the project failed validation with `InvalidSpecError: Application referencing project bookstore which does not exist`.
- **The wildcard certificate covered one subdomain level, not two.** `ingress-cert.tf`'s ACM certificate requested `*.<domain>` as its wildcard SAN — which matches `bookstore.<domain>` (one label deep, the frontend's host) but not `api.bookstore.<domain>` (two labels deep, the gateway's host); TLS wildcards never match more than one additional label, by design, not an AWS quirk. The AWS Load Balancer Controller correctly refused to build a listener for the gateway's Ingress with no matching certificate, which meant that one Ingress simply never got an ALB — while the frontend's Ingress, one label shallower, worked perfectly, making the symptom look host-specific rather than certificate-specific until someone actually read the controller's reconcile-error events.

None of these are exotic mistakes — a missed bootstrap step, a stale zone assumption, an off-by-one-subdomain-level SAN. What they share is the same lesson: a `terraform plan` that shows a clean, reviewed diff tells you the *changes* are internally consistent, not that the *resulting system* is complete. That only gets proven by actually running it against real DNS, a real cluster, and real traffic.

### Amazon RDS (Relational Database Service) — the database

**Plainly:** RDS is a managed MySQL/Postgres/etc. server — AWS handles patching, backups, and failover, so you're not SSH-ing into a box to run `apt upgrade mysql`.

**What "Multi-AZ" means and why it's on:** the database runs as a primary copy in one AZ and a continuously-synchronized standby copy in a different AZ. If the primary's AZ has a problem, AWS automatically fails over to the standby — the database's network address doesn't even change, so the application doesn't need to know it happened. This is the single most important reliability feature turned on in this whole stack, because the database is the one thing that can't just be "restarted somewhere else" the way a stateless Kubernetes pod can — it holds the actual data.

**Why one shared database instance with 5 separate *schemas*, instead of one instance per service (which is the "more correct" microservices pattern)?** Real cost and complexity, named honestly: a separate RDS instance per service means paying for 4-5 database servers instead of 1, and managing 4-5 sets of backups, patches, and connections instead of one. This project uses **schema-level isolation** instead — one shared MySQL server, but each service gets its own database-within-the-database (`catalog_db`, `user_db`, `order_db`, `notification_db`) and its own least-privilege MySQL user that can only touch its own schema, never anyone else's. It's a deliberate middle ground: you get real access-control isolation (catalog-service's database credentials physically cannot read user-service's data, even though they're on the same server) without paying for 5x the database infrastructure. The project's own roadmap explicitly names full instance-level isolation as a "when you actually outgrow this" next step, not a mistake.

**Why is there no foreign-key constraint between, say, `orders.user_id` and the `users` table, even though they're logically related?** Because they're not even in the same schema anymore, and in a stricter microservices setup they could be on entirely different database servers — a SQL foreign key can't reach across that boundary. This is normal and expected in a microservices world: relationships that used to be enforced by the database are now enforced by *application code* instead (each service trusts that the ID it was given is real). It's a real tradeoff — you lose the database's automatic "you can't delete a user who still has orders" protection — that every microservices architecture accepts as the cost of independent services owning independent data.

### AWS Secrets Manager + External Secrets Operator — how passwords get into the cluster without ever touching git

**The problem being solved:** every service needs a database password, and the JWT signing key needs to exist somewhere. Where does that live? Not in the code, not in a config file checked into git — because anyone who can read the git history can read a secret that was ever committed, even if it's "removed" in a later commit.

**The actual mechanism, worth being able to draw:**
1. Terraform generates a strong random password for each service and writes it into **AWS Secrets Manager** (a secure, access-controlled vault for exactly this purpose) — the value never appears in any file you'd commit.
2. Inside the cluster, a component called the **External Secrets Operator** watches for a special Kubernetes object (`ExternalSecret`) that says "go fetch the value at this path in Secrets Manager and turn it into a real Kubernetes Secret."
3. The Operator authenticates to AWS using **IRSA** (IAM Roles for Service Accounts) — a mechanism that lets a specific Kubernetes identity assume a specific, narrowly-scoped AWS permission (in this case: "you may read anything under `/bookstore/*` in Secrets Manager, and nothing else") without any AWS access key ever being stored inside the cluster at all.
4. The resulting native Kubernetes Secret gets mounted into each service's container as an environment variable, the normal way any app reads configuration.

**Why this instead of Kubernetes' own built-in Secrets (just base64-encoded values you `kubectl apply` by hand)?** Plain Kubernetes Secrets have to be created *somehow* — usually that means a human typing a password into a YAML file at some point, which is exactly the "secret ends up in git" risk this whole mechanism avoids. Using Secrets Manager as the single source of truth means the actual passwords are generated by Terraform (nobody ever typed them), stored in a system built for exactly this, and rotatable centrally without touching Kubernetes manifests at all.

### AWS KMS (Key Management Service) — encrypting the encryption

**Plainly:** by default, Kubernetes Secrets are stored at rest inside the cluster's underlying storage in a way that's *technically* encrypted (because the disk itself is encrypted) but not encrypted at the Kubernetes API layer specifically — meaning if someone got a raw copy of the cluster's internal database (etcd), the secret values inside it wouldn't have an extra layer of protection beyond disk encryption. KMS envelope encryption adds exactly that extra layer: EKS uses a dedicated encryption key (that you control and can rotate) to encrypt Secret contents specifically, on top of whatever the underlying storage already does. This is a defense-in-depth measure lifted straight from the official CIS Kubernetes security benchmark — not something that fixes an active problem, but the kind of thing a security review specifically checks for.

### IAM + GitHub OIDC — how the CI pipeline gets AWS access without a password

**The old, bad pattern this avoids:** store a permanent AWS access key + secret key as a GitHub secret, and have every CI run use that same static credential forever. If that credential ever leaks (accidentally logged, a compromised dependency exfiltrates it), it's valid until someone notices and manually revokes it — potentially forever.

**What this project does instead — OIDC federation:** GitHub Actions can present a short-lived, cryptographically signed identity token proving "this is a run of workflow X, on branch Y, in repo Z" directly to AWS. AWS has a pre-configured trust relationship (an IAM role whose trust policy says "I'll accept tokens from GitHub, but only ones claiming to be from this exact repo, on these exact branches") and, if the token matches, hands back *temporary* credentials that expire on their own after the job finishes. There is no static secret anywhere to leak — even if someone read every GitHub secret in the repo, there'd be nothing there, because there's nothing stored.

### GitOps with ArgoCD — how a `git push` turns into a real deployment

**The chain, worth drawing on a whiteboard:** a developer pushes code → GitHub Actions builds a container image, scans it for vulnerabilities, and pushes it to ECR (AWS's container image registry) → **but GitHub Actions never touches the Kubernetes cluster directly.** Instead, it makes one small, boring change: it edits a text file in the git repo that says "the image tag for `catalog-service` is now `abc123`," and commits that change back to git. That's it — CI's job ends there.

Separately, and asynchronously, **ArgoCD** — a piece of software running inside the cluster — polls the git repository every 3 minutes, notices that text file changed, and applies the new configuration to the cluster itself, pulling the new image and doing a rolling update.

**Why this two-step, decoupled design instead of having CI just run `kubectl apply` directly at the end of the pipeline?** This is called **GitOps**, and the core idea is: *git is the single source of truth for what should be running*, and a separate, cluster-internal controller is the only thing with permission to actually change the cluster, reconciling it to match what git says. Benefits worth naming: the cluster's actual state can never silently drift from what's declared in git, because ArgoCD continuously re-checks and self-heals any manual changes back to what git says; there's a full audit trail of every deployment as git commits; and CI pipelines never need broad "modify anything in the cluster" credentials at all — they only need permission to push a git commit and push an image, a much smaller blast radius if the pipeline itself were ever compromised.

### Prometheus, Grafana, Loki, Alertmanager — monitoring, and why it's *not* running inside Kubernetes

**What each one does, in one line:**
- **Prometheus** — scrapes metrics (numbers over time: request counts, CPU usage, error rates) from every service and node, on a schedule, and stores them.
- **Grafana** — turns those stored metrics into dashboards and graphs a human actually looks at.
- **Loki** — the same idea as Prometheus, but for *logs* (text lines services print) instead of numeric metrics.
- **Alertmanager** — watches Prometheus for rules like "error rate above X for 5 minutes" and, when one fires, sends a real notification (this project wires it to send email via Amazon SES).

**Why do all four of these run on a plain EC2 server via Docker Compose, instead of inside the Kubernetes cluster the way you'd usually see in a real company?** Because it was tried inside the cluster first, and it didn't fit: the full Prometheus/Grafana stack (`kube-prometheus-stack`) is genuinely resource-heavy, and on the small, cost-constrained node group this project runs, installing it starved every other pod of CPU/memory and the install itself kept timing out. Moving monitoring to its own dedicated, separately-sized EC2 instance solved that immediately, at the cost of a real, worth-naming tradeoff: **the thing monitoring this system doesn't live inside the system it's monitoring** — if the EKS cluster's networking has a serious problem, your dashboards might be affected by the very thing you're trying to diagnose. In a well-resourced production environment, running monitoring in-cluster (or better, using a managed service like Amazon Managed Prometheus/Grafana) would usually be preferred; this project's choice is a direct, explicit response to a real resource constraint, not a general recommendation.

### Amazon SES — how alert emails actually get delivered

Alertmanager needs to send real email. **SES (Simple Email Service)** is AWS's outbound-email service, authenticated over SMTP with a username/password pair specifically derived from an IAM access key using AWS's own published algorithm (an HMAC-based transformation — the raw IAM secret key is *not* the SMTP password; they're mathematically related but not identical, and Terraform computes the real one and stores it separately). Worth knowing: new SES accounts start in "sandbox mode," which requires *both* the sending and receiving address to be pre-verified — a safeguard against spam from brand-new accounts — so this project uses the same address for both, meaning exactly one verification email needs to be clicked before alerts actually deliver.

### CloudTrail + GuardDuty — the "did something bad happen, and who did it" services

**CloudTrail** records every API call made against your AWS account — who did what, when, from where — into a durable, encrypted log. It's not prevention, it's an audit trail: if something goes wrong, CloudTrail is how you reconstruct exactly what happened.

**GuardDuty** is a threat-*detection* service — it continuously watches account activity, S3 access patterns, and (in this project's config) Kubernetes audit logs and EBS volumes for malware, and flags things that look like an actual attack (a compromised credential being used unusually, a port scan, etc.), using AWS's own threat intelligence.

**The distinction worth being crisp about if asked:** CloudTrail tells you *what happened*; GuardDuty tells you *if something happening looks malicious*. They're complementary, not overlapping — one's a logbook, the other's a guard dog.

### CloudFront — present in the code, off by default

CloudFront is AWS's CDN (Content Delivery Network) — it caches your static content at edge locations physically close to users worldwide, so a user in Tokyo doesn't have to wait on a round-trip to `us-west-1` for a JavaScript file. This project has real, working Terraform code for it, but it's **disabled by default** — a deliberate choice to keep the default deployment simple, with the option available the moment it's actually needed (e.g., if the site had a real, geographically spread-out userbase where that latency mattered).

---

## Part 3: Networking and security, connected together

This section is specifically about how the pieces above connect and protect each other — the part that shows you understand the *system*, not just a list of services.

### The full request path, one more time, as a single diagram to describe out loud

```
Browser
  → Route 53 (turns bookstore.example.com into an IP address)
  → ALB (the AWS load balancer, sitting in a public subnet)
  → NGINX Ingress Controller (inside the cluster, routes by hostname)
  → api-gateway (checks the JWT, decides which internal service owns this request)
  → catalog-service / user-service / order-service (the one that actually does the work)
  → RDS MySQL (the shared database, only reachable from the EKS-node subnets)
```

Every arrow in that chain is a real network hop, and every hop after the load balancer happens *inside* the private network — nothing after the ELB is directly reachable from the public internet.

### Defense in depth: why there isn't just one security control, there are five layered ones

A good architecture doesn't rely on a single gate. Here, from outside in:

1. **Security Groups** (AWS-level firewall) — the database's security group only accepts connections on port 3306 from the specific IP ranges of the EKS-node subnets. Not from the internet, not even from the rest of the VPC.
2. **NetworkPolicies** (Kubernetes-level firewall) — inside the cluster, every namespace has a "deny everything by default" rule, with narrow, explicit exceptions layered on top (e.g., "catalog-service will only accept incoming connections from api-gateway, on exactly its app port, nothing else"). This only actually gets *enforced* because the VPC CNI's built-in network-policy feature is turned on — without that one setting, these objects exist in Kubernetes but do nothing at all, silently.
3. **Pod Security Admission** (`restricted` level) — every namespace refuses to run a pod that tries to run as root, escalate privileges, or use capabilities it doesn't need. This is enforced at the moment a pod is *created*, before it ever runs.
4. **IAM + IRSA** — every AWS-facing permission (reading a secret, writing a log) is scoped to the single narrow thing that component actually needs, using temporary, automatically-rotated credentials, never a long-lived key.
5. **JWT verification** at the one true entry point (`api-gateway`) — nothing gets into the internal services without a valid, unexpired, correctly-signed token (except the specific public routes, like browsing books or logging in, that are meant to be public).

**Why this matters as an answer, not just a list:** if you're asked "what happens if one of these fails," the honest answer is: the system is designed so that *no single failure* exposes the database or the internal services to the internet. A misconfigured NetworkPolicy still leaves the Security Group in place. A compromised pod still can't reach anything its NetworkPolicy doesn't explicitly allow, even if it somehow got root (which Pod Security Admission was already trying to prevent). That layering, not any one control, is "defense in depth," and it's the correct answer to "is this secure" — no single yes/no answer is honest, only "here are the independent layers and what each one covers."

### Disaster Recovery — what actually exists, and what's just a plan

Be precise here, because it's easy to over-claim. This project has a **primary region** (`us-west-1`) running 100% of the live system, and a **secondary region** (`us-west-2`) that today holds essentially nothing.

**What genuinely exists in the secondary region, all opt-in and off by default:**
- The database's automated backups *can* be replicated there (needs a real encryption key created in that region first — AWS's default database encryption key can't cross regions, only a customer-managed one can).
- Container images and some secrets *can* be replicated there.
- A DNS failover record *can* point there — but it points at nothing, because there's no load balancer or cluster running in `us-west-2` to point at.

**The honest one-liner:** *"Today, DR here means 'if the primary region disappeared, our backups would still exist somewhere else' — it does not mean 'traffic would automatically fail over to a running system,' because there is no running system in the second region. Building that out — a second EKS cluster, a strategy for keeping the database in sync, DNS that actually has something healthy to fail over to — is real, deliberately deferred future work, not a currently-working feature."* Saying this plainly, instead of implying more than exists, is exactly the kind of honesty that makes someone trust the rest of what you say about the system.

**Why is even the backup-replication piece *off* by default, when it sounds purely beneficial?** Because it was found, during a review, to have been silently turned on for *everyone*, always — the flag controlling it was accidentally tied to "is a secondary region name configured at all," which was always true (since the Terraform code needs a secondary region string regardless, for other reasons), rather than to a real, deliberate "yes I want this" decision. It was changed to a genuinely separate, default-off switch. That's a good, specific example to have ready if asked "tell me about a bug you'd have caught in review" — a flag that looked like it was doing what its name said, but wasn't.

---

## Questions you should be ready for, with the short honest answer

**"Why microservices instead of a monolith, for something this small?"**
Because the point of this project isn't "build the simplest possible bookstore," it's "demonstrate the architecture a real company would use once a bookstore *isn't* small anymore." Named honestly: for the actual current traffic this app gets, a monolith would be simpler and cheaper. The complexity here is intentional, for the learning/reference value.

**"What's the biggest single point of failure in this system?"**
Two honest answers, both real: the single NAT Gateway (all private-subnet outbound traffic dies if its AZ has a problem), and — until a recent fix — the single-replica ingress controller that every request passes through (now running 2 replicas specifically because of that risk). Naming a real, specific SPOF, and how it was addressed or why it's an accepted tradeoff, is a much stronger answer than "I don't think there is one."

**"How would you scale this if traffic increased 100x?"**
Name the real levers in order: (1) the Horizontal Pod Autoscalers already exist for every service and would add more pod replicas automatically as CPU/memory usage rose; (2) but the underlying EKS node group is currently a *fixed* size (min=max in practice today, pinned even further by an AWS account quota limit) — so pods would eventually have nowhere to schedule; the real next step is a node autoscaler (Karpenter or Cluster Autoscaler) so node count follows real demand, not just pod count; (3) the database is the part that doesn't horizontally scale at all in this design — it's one Multi-AZ instance, and at real scale you'd eventually need read replicas or a move toward per-service database instances.

**"What would you change if you were starting over?"**
A good, honest answer draws from the real, known gaps rather than inventing new criticism: add a real node autoscaler (Karpenter/Cluster Autoscaler), replace the fire-and-forget notification call with a real message queue once delivery guarantees matter, and decide deliberately about the DR story instead of leaving it as backup-only. (The load balancer type and JWT revocation used to be on this list too — both got fixed for real: the LB is a real ALB behind the AWS Load Balancer Controller now, replacing an ingress-nginx setup that turned out to be not just "outdated" but genuinely EOL and unpatched — not just an accidental Classic ELB — and login issues a short-lived access token plus a rotating, revocable refresh token instead of one unrevocable hour-long JWT. Good material if asked "tell me about something you found and actually fixed," not just identified — especially the load balancer one, where the first fix chosen turned out to be solving the wrong-sized problem once a bigger fact came in.)

**"Is this secure?"**
Never answer yes/no. Answer with the layers (Part 3 above), name what's genuinely strong (no static AWS credentials anywhere, in CI or in the cluster; encrypted secrets at rest and in transit to Secrets Manager; a real default-deny network posture), and name what's an accepted tradeoff for a demo/reference deployment rather than a production system handling real payment data (e.g., the monitoring dashboards are open to `0.0.0.0/0` by default, meant to be restricted per-deployment; SES starts in sandbox mode with real send-volume limits).

## Related

- [`TERRAFORM_EXPLAINED.md`](TERRAFORM_EXPLAINED.md) — every `.tf` file, what it creates, why
- [`KUBERNETES_EXPLAINED.md`](KUBERNETES_EXPLAINED.md) — every folder and file under `k8s/`, why organized that way
- [`DOCKER_EXPLAINED.md`](DOCKER_EXPLAINED.md) — the six Dockerfiles behind these images, stage by stage
- The real docs this was built from: `../docs/ARCHITECTURE.md`, `../docs/ARCHITECTURE_DIAGRAM_PROMPT.md`, `../docs/TROUBLESHOOTING.md`, `../docs/UML.md`
