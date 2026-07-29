#!/usr/bin/env bash
set -euo pipefail

# scaffold-web.sh — Initialize a web stack (Vite + React 18 + Node.js backend)
# Usage: bash scaffold-web.sh [project-name]
# Requires: node, npm/npx

PROJECT_NAME="${1:-web-app}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB_DIR="${REPO_ROOT}/${PROJECT_NAME}"
BACKEND_DIR="${REPO_ROOT}/backend"

echo "[scaffold-web] Creating Vite + React 18 project: $PROJECT_NAME"

if ! command -v node &>/dev/null; then
    echo "[ERROR] Node.js not found."
    exit 1
fi

# ── Frontend (Vite + React 18 + TypeScript) ───────────
npm create vite@latest "$PROJECT_NAME" -- --template react-ts 2>/dev/null || {
    echo "[WARN] create-vite failed. Creating manually..."
    mkdir -p "$WEB_DIR"
}

cd "$WEB_DIR"

npm install 2>/dev/null || true

npm install --save \
    react-router-dom \
    @tanstack/react-query \
    axios \
    zustand 2>/dev/null || true

npm install --save-dev \
    tailwindcss@3 postcss autoprefixer \
    vitest @testing-library/react @testing-library/jest-dom \
    eslint @typescript-eslint/eslint-plugin @typescript-eslint/parser \
    prettier 2>/dev/null || true

# Create project structure
mkdir -p src/components src/pages src/hooks src/services src/stores src/utils src/types tests/unit tests/e2e

# Tailwind v3 config
cat > tailwind.config.js << 'EOF'
/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{js,ts,jsx,tsx}'],
  theme: {
    extend: {
      colors: {
        primary: { 50: '#e0f7fa', 500: '#00bcd4', 700: '#00838f' },
        surface: '#0a0a0f',
        'surface-2': '#14141f',
      },
    },
  },
  plugins: [],
};
EOF

# PostCSS config
cat > postcss.config.js << 'EOF'
export default {
  plugins: {
    tailwindcss: {},
    autoprefixer: {},
  },
};
EOF

# Update index.css with Tailwind
cat > src/index.css << 'EOF'
@tailwind base;
@tailwind components;
@tailwind utilities;

body {
  margin: 0;
  font-family: 'Inter', system-ui, -apple-system, sans-serif;
  background-color: #0a0a0f;
  color: #e0e0e0;
}
EOF

# React Router wrapper
cat > src/App.tsx << 'EOF'
import { BrowserRouter, Routes, Route } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';

const queryClient = new QueryClient();

function Home() {
  return (
    <div className="min-h-screen bg-surface flex items-center justify-center">
      <div className="text-center">
        <h1 className="text-4xl font-bold text-cyan-400 mb-4">Web App</h1>
        <p className="text-gray-400">Built with React 18 + Vite + Tailwind</p>
      </div>
    </div>
  );
}

function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <Routes>
          <Route path="/" element={<Home />} />
        </Routes>
      </BrowserRouter>
    </QueryClientProvider>
  );
}

export default App;
EOF

# ── Backend (Node.js + Express + TypeScript) ──────────
echo "[scaffold-web] Creating Node.js backend..."
mkdir -p "$BACKEND_DIR"
cd "$BACKEND_DIR"

cat > package.json << 'EOF'
{
  "name": "backend",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "tsx watch src/index.ts",
    "build": "tsc",
    "start": "node dist/index.js",
    "test": "vitest run",
    "lint": "eslint src/"
  }
}
EOF

npm install --save \
    express cors helmet morgan dotenv zod 2>/dev/null || true

npm install --save-dev \
    typescript @types/node @types/express @types/cors @types/morgan \
    tsx vitest supertest @types/supertest 2>/dev/null || true

mkdir -p src/routes src/middleware src/services src/db src/utils tests

cat > tsconfig.json << 'EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist", "tests"]
}
EOF

cat > src/index.ts << 'EOF'
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import morgan from 'morgan';
import { config } from 'dotenv';

config();

const app = express();
const PORT = process.env.PORT || 3001;

app.use(helmet());
app.use(cors());
app.use(morgan('dev'));
app.use(express.json());

app.get('/api/health', (_req, res) => {
  res.json({ status: 'healthy', timestamp: new Date().toISOString() });
});

app.listen(PORT, () => {
  console.log(`[backend] Server running on port ${PORT}`);
});

export default app;
EOF

echo "[scaffold-web] ✓ Web scaffold ready"
echo "  Frontend: $WEB_DIR — cd $WEB_DIR && npm run dev"
echo "  Backend:  $BACKEND_DIR — cd $BACKEND_DIR && npm run dev"
