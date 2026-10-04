# Build from the repository root: docker build -f apps/server/Dockerfile -t dahlia-server .
FROM node:24-alpine AS build
RUN corepack enable
WORKDIR /workspace
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps/server/package.json apps/server/
COPY packages/ui/package.json packages/ui/
RUN pnpm install --frozen-lockfile --filter @dahlia-ai/server...
COPY apps/server apps/server
COPY packages/ui packages/ui
# The bundled UI package is a devDependency; deploy copies the runtime files and production dependencies only.
RUN pnpm --filter @dahlia-ai/server run build && pnpm --filter @dahlia-ai/server deploy --legacy --prod /app

FROM node:24-alpine AS runtime
ENV NODE_ENV=production
RUN corepack enable
WORKDIR /app
COPY --from=build /app ./
RUN pnpm --version
EXPOSE 3000
VOLUME ["/app/.data"]
CMD ["sh", "-c", "pnpm run db:migrate:prod && exec node dist/server/node.js"]
