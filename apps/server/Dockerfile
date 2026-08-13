FROM node:24-alpine AS build
RUN corepack enable
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps/server/package.json ./apps/server/package.json
COPY apps/site/package.json ./apps/site/package.json
RUN pnpm install --frozen-lockfile
COPY apps/server ./apps/server
RUN pnpm --filter dahlia-ai build

FROM node:24-alpine AS runtime
ENV NODE_ENV=production
RUN corepack enable
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps/server/package.json ./apps/server/package.json
COPY apps/site/package.json ./apps/site/package.json
RUN pnpm install --frozen-lockfile --prod
COPY --from=build /app/apps/server/dist ./apps/server/dist
COPY --from=build /app/apps/server/drizzle ./apps/server/drizzle
COPY --from=build /app/apps/server/auth-migrations ./apps/server/auth-migrations
WORKDIR /app/apps/server
EXPOSE 3000
VOLUME ["/app/apps/server/.data"]
CMD ["sh", "-c", "pnpm run db:migrate:prod && exec node dist/server/node.js"]
