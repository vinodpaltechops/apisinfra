# frontend — Vite build, then a static nginx runtime.
FROM node:20-alpine AS builder

WORKDIR /build

# Copy the lockfile-bearing manifests first so dependency installs stay cached
# across source-only changes.
COPY package.json package-lock.json* ./
RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi

COPY index.html vite.config.js ./
COPY src ./src
RUN npm run build


# nginx-unprivileged runs as uid 101 and listens on 8080 — no root, no
# CAP_NET_BIND_SERVICE, works with the deployment's restricted securityContext.
FROM nginxinc/nginx-unprivileged:1.27-alpine AS runtime

# Where /api/* is proxied when this pod is reached directly (compose, or a
# cluster without the ingress rule). Overridden by the deployment's env.
ENV BACKEND_URL=http://backend:8000

COPY --from=builder /build/dist /usr/share/nginx/html
COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template

USER 101
EXPOSE 8080
