# Doublespot Example Template — AI Agent Instructions

## Summary
Build a minimal end-to-end example repo that proves:
- Local dev works via Docker Compose
- Backend image builds and runs (ALB-ready health check)
- GitHub Actions CI/CD deploys backend to **ECR → ECS (Fargate)** using **OIDC**
- Frontend builds and deploys to **S3 + CloudFront** (separate workflow)

> Keep everything simple but production-shaped. No real secrets committed.

---

## 1) Target Architecture
### Backend (runtime path)
GitHub Actions → ECR → ECS (Fargate) → ALB → (optional) RDS MySQL

### Frontend (static path)
GitHub Actions → S3 → CloudFront → Browser

---

## 2) Repo Structure (Monorepo)
Create this structure:

```
doublespot-example/
  README.md
  docker-compose.yml
  .gitignore

  backend/
    src/
      server.ts
      app.ts
      routes/health.route.ts
      config/env.ts
    package.json
    package-lock.json
    tsconfig.json
    Dockerfile
    .dockerignore
    .env.example
    taskdef.template.json

  frontend/
    src/
      App.tsx
      main.tsx
    index.html
    package.json
    package-lock.json
    vite.config.ts
    .dockerignore
    .env.example

  .github/workflows/
    backend-ci-cd.yml
    frontend-deploy.yml
```

---

## 3) Backend Requirements (must be ALB-ready)
### Functional requirements
- Node.js 20 + TypeScript + Express
- Listen on `0.0.0.0` and `process.env.PORT` (default `3000`)
- Implement:
  - `GET /health` returns **200** and body `"ok"`
- Provide a minimal env loader in `backend/src/config/env.ts`

### Backend file behaviors
- `src/routes/health.route.ts` exports a router
- `src/app.ts` wires middlewares + routes
- `src/server.ts` starts the server and logs a startup line

### backend/.env.example
Include placeholders only:
```
PORT=3000
NODE_ENV=production

DB_HOST=localhost
DB_USER=root
DB_PASSWORD=password
DB_NAME=doublespot
```

### Dockerfile requirements
- Multi-stage build
- Final image runs `node dist/server.js`
- Expose port 3000
- Production dependencies only in final image

---

## 4) Frontend Requirements (simple + deployable)
### Functional requirements
- Vite + React + TypeScript
- Display a simple UI and a “Health Check” result
- Use `VITE_API_BASE_URL` and call:
  - `${VITE_API_BASE_URL}/health`

### frontend/.env.example
```
VITE_API_BASE_URL=http://localhost:3000
```

---

## 5) Local Dev (must work)
### docker-compose.yml (root)
Must support:
- `docker compose up --build`
- Backend reachable at `http://localhost:3000/health`
- Frontend reachable at `http://localhost:5173`

DB is optional:
- If included, keep it minimal and clearly marked “optional”.

### Acceptance checks
- `curl localhost:3000/health` returns 200
- Frontend loads and displays backend health response

---

## 6) AWS / CI-CD Assumptions (do NOT create AWS resources)
Assume these exist already, and treat them as inputs:
- AWS region (e.g., `us-west-2`)
- ECR repository for backend (e.g., `doublespot-backend`)
- ECS cluster + ECS service (Fargate)
- Task execution role already set on ECS
- ALB + target group configured with health check path `/health`
- GitHub OIDC IAM role already created (trusts GitHub)

---

## 7) GitHub Actions Inputs (variables/secrets)
Use GitHub **Variables** (or Env) for non-sensitive:
- `AWS_REGION`
- `ECR_REPOSITORY`
- `ECS_CLUSTER`
- `ECS_SERVICE`
- `CONTAINER_NAME`
- `S3_BUCKET`
- `CLOUDFRONT_DISTRIBUTION_ID`
- `VITE_API_BASE_URL`

Use GitHub **Secrets** only for sensitive (if any). Prefer none.

Required secret/variable for OIDC role:
- `AWS_ROLE_TO_ASSUME` (role ARN)

---

## 8) Backend CI/CD Workflow (required)
Create `.github/workflows/backend-ci-cd.yml`

### Trigger
- On push to `main`
- Only when `backend/**` changes (path filter)

### Steps (must)
1. Checkout
2. Setup Node 20
3. `npm ci` + `npm run build` in backend
4. Configure AWS credentials via OIDC:
   - use `aws-actions/configure-aws-credentials`
   - role = `${{ vars.AWS_ROLE_TO_ASSUME }}` or `${{ secrets.AWS_ROLE_TO_ASSUME }}`
5. Login to ECR
6. Build and push Docker image:
   - tag with commit SHA
7. Render task definition with new image URI
8. Deploy to ECS service and wait for stability

### Task definition strategy
Provide `backend/taskdef.template.json` with an obvious placeholder token for image:
- Example placeholder: `__IMAGE_URI__`
The workflow replaces it with the actual image URI.

---

## 9) Frontend Deploy Workflow (required)
Create `.github/workflows/frontend-deploy.yml`

### Trigger
- On push to `main`
- Only when `frontend/**` changes

### Steps (must)
1. Checkout
2. Setup Node 20
3. `npm ci` and `npm run build`
   - Provide `VITE_API_BASE_URL` at build time from GitHub variable
4. Configure AWS credentials via OIDC
5. Sync `dist/` to S3
6. Invalidate CloudFront distribution

---

## 10) README (required)
Write a clear `README.md` that includes:
- Local dev steps
- How to build backend image locally
- How to deploy with GitHub Actions (what vars to set)
- Health check endpoint and ALB configuration note (`/health`)
- A simple flow diagram for backend and frontend pipelines

---

## 11) Quality Bar / Acceptance Criteria
The output is complete only if:
- `docker compose up --build` works
- Backend health endpoint works and is ALB-ready
- Workflows are valid YAML and follow OIDC best practices
- No real secrets are committed; only `.env.example` exists
- README is clear enough for a teammate to run in <30 minutes
