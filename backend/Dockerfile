# Build stage
FROM --platform=linux/amd64 node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# Production stage
FROM --platform=linux/amd64 node:20-alpine AS production
WORKDIR /app

# Install curl for health checks
RUN apk add --no-cache curl

COPY package*.json ./
RUN npm ci --only=production
COPY --from=builder /app/dist ./dist
EXPOSE 3000
CMD ["node", "dist/server.js"]
