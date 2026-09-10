# Packages the GraphenePush App into an uploadable .zip - no node/npm on the host, no registry, no
# Rocket.Chat credentials. From this directory:
#
#   sudo docker build --output dist .
#
# leaves dist/graphene-push_<version>.zip here, ready for Marketplace → Private Apps → Upload private app.

FROM docker.io/node:20-alpine AS build

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY app.json tsconfig.json icon.png ./
COPY GraphenePushApp.ts ./
COPY lib ./lib

# rc-apps exits 0 even when packaging fails (e.g. "X is not a constructor"), so success is judged by
# the "finished!" it prints only on its success path - otherwise a broken build would still pass.
RUN npx rc-apps package > package.log 2>&1; \
	cat package.log; \
	grep -q 'finished!' package.log

FROM scratch AS export
COPY --from=build /app/dist/ /
