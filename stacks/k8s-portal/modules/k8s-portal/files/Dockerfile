FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm install --no-audit --no-fund
COPY . .
RUN npm run build

FROM node:22-alpine
WORKDIR /app
# The runtime only runs `node build`, so drop the npm CLI the base image ships.
# Its bundled dependencies (tar, pacote, sigstore, brace-expansion, picomatch,
# ip-address) carry HIGH CVEs that even the newest npm release has not
# picked up yet.
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx
COPY --from=build /app/build ./build
COPY --from=build /app/package.json ./
COPY --from=build /app/node_modules ./node_modules
ENV PORT=3000
EXPOSE 3000
CMD ["node", "build"]
