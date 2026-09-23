# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------- deps
# The workspace is a pnpm monorepo, so the install needs the lockfile and every manifest
# it references — copied before the sources so a code change does not invalidate the
# dependency layer.
FROM node:22-alpine AS deps
WORKDIR /app
RUN corepack enable

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps/api/package.json          apps/api/
COPY apps/dashboard/package.json    apps/dashboard/
COPY packages/contracts/package.json packages/contracts/

# --frozen-lockfile: the image must be built from exactly the dependency set that CI tested.
RUN pnpm install --frozen-lockfile --filter @pharmaet/api... --filter @pharmaet/contracts...

# --------------------------------------------------------------------------- build
FROM deps AS build
WORKDIR /app
COPY packages/contracts packages/contracts
COPY apps/api apps/api
RUN pnpm --filter @pharmaet/contracts build \
 && pnpm --filter @pharmaet/api exec nest build

# Strip dev dependencies from the tree that ships.
RUN pnpm install --frozen-lockfile --prod --filter @pharmaet/api... --filter @pharmaet/contracts...

# ------------------------------------------------------------------------- runtime
FROM node:22-alpine AS runtime
WORKDIR /app

# Runs unprivileged. The process needs no root capability, and a container that cannot write
# outside its own tree is one fewer thing to reason about after an incident.
RUN addgroup -S pharmaet && adduser -S pharmaet -G pharmaet

ENV NODE_ENV=production
ENV PORT=3000

COPY --from=build --chown=pharmaet:pharmaet /app/node_modules ./node_modules
COPY --from=build --chown=pharmaet:pharmaet /app/packages/contracts/dist ./packages/contracts/dist
COPY --from=build --chown=pharmaet:pharmaet /app/packages/contracts/package.json ./packages/contracts/
COPY --from=build --chown=pharmaet:pharmaet /app/packages/contracts/node_modules ./packages/contracts/node_modules
COPY --from=build --chown=pharmaet:pharmaet /app/apps/api/dist ./apps/api/dist
COPY --from=build --chown=pharmaet:pharmaet /app/apps/api/package.json ./apps/api/
COPY --from=build --chown=pharmaet:pharmaet /app/apps/api/node_modules ./apps/api/node_modules
COPY --chown=pharmaet:pharmaet apps/api/docker-entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint

USER pharmaet
EXPOSE 3000

# /api/health reports liveness AND the contract versions this instance serves, so a rolling
# deploy can be checked for the N-1 window still being honoured (ADR-009).
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

WORKDIR /app/apps/api
ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["serve"]
