FROM node:22-alpine AS base

RUN apk upgrade --no-cache

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY --chown=appuser:appgroup . .

# Remove lock file after all COPYs — it is not needed at runtime and Trivy reads
# it to flag dev-only packages (picomatch, brace-expansion via nodemon) as if
# they were installed in the production image.
RUN rm -f package-lock.json

USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:3000/ || exit 1

CMD ["node", "index.js"]
