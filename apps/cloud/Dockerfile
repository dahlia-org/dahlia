FROM node:24-alpine AS build
RUN corepack enable
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps/cloud/package.json ./apps/cloud/package.json
COPY apps/site/package.json ./apps/site/package.json
RUN pnpm install --frozen-lockfile
COPY apps/cloud ./apps/cloud
RUN pnpm --filter @dahlia/cloud build

FROM node:24-alpine AS runtime
ENV NODE_ENV=production
RUN corepack enable
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps/cloud/package.json ./apps/cloud/package.json
COPY apps/site/package.json ./apps/site/package.json
RUN pnpm install --frozen-lockfile --prod
COPY --from=build /app/apps/cloud/dist ./apps/cloud/dist
COPY --from=build /app/apps/cloud/drizzle ./apps/cloud/drizzle
COPY --from=build /app/apps/cloud/auth-migrations ./apps/cloud/auth-migrations
WORKDIR /app/apps/cloud
EXPOSE 3000
VOLUME ["/app/apps/cloud/.data"]
CMD ["sh", "-c", "pnpm run db:migrate:prod && exec node dist/server/node.js"]
