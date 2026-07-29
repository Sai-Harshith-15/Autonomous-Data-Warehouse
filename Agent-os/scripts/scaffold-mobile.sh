#!/usr/bin/env bash
set -euo pipefail

# scaffold-mobile.sh — Initialize a Flutter or React Native project
# Usage: bash scaffold-mobile.sh [--flutter|--react-native] [project-name]
# Default: Flutter (preferred stack)

MODE="flutter"
PROJECT_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --flutter|--rn|--react-native) MODE="react-native"; shift ;;
        --help|-h) echo "Usage: scaffold-mobile.sh [--flutter|--react-native] [name]"; exit 0 ;;
        *) PROJECT_NAME="$1"; shift ;;
    esac
done

PROJECT_NAME="${PROJECT_NAME:-mobile_app}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="${REPO_ROOT}/${PROJECT_NAME}"

echo "[scaffold-mobile] Mode: ${MODE}"
echo "[scaffold-mobile] Creating: ${PROJECT_NAME}"

# ─── FLUTTER (default, preferred) ──────────────────────────
if [[ "$MODE" == "flutter" ]]; then
    if ! command -v flutter &>/dev/null; then
        echo "[ERROR] Flutter SDK not found. Install from https://flutter.dev"
        exit 1
    fi

    echo "[scaffold-mobile] Creating Flutter project..."
    flutter create --org com.app --project-name "$PROJECT_NAME" "$TARGET_DIR" --platforms android,ios,web 2>/dev/null || {
        echo "[WARN] flutter create failed. Using existing dir..."
        mkdir -p "$TARGET_DIR"
    }

    cd "$TARGET_DIR"

    # Install baseline packages
    echo "[scaffold-mobile] Installing packages..."
    flutter pub add flutter_bloc bloc_concurrency equatable get_it go_router dartz dio flutter_secure_storage shared_preferences 2>/dev/null || true
    flutter pub add --dev bloc_test mocktail flutter_lints 2>/dev/null || true

    # Create feature-first clean architecture structure
    mkdir -p lib/config/routes lib/config/theme
    mkdir -p lib/core/error lib/core/network lib/core/storage lib/core/usecase lib/core/utils lib/core/widgets
    mkdir -p lib/di/modules
    mkdir -p lib/features/splash/data/datasources lib/features/splash/data/models lib/features/splash/data/repositories
    mkdir -p lib/features/splash/domain/entities lib/features/splash/domain/repositories lib/features/splash/domain/usecases
    mkdir -p lib/features/splash/presentation/bloc lib/features/splash/presentation/pages lib/features/splash/presentation/widgets
    mkdir -p lib/shared/widgets
    mkdir -p test/features/splash test/helpers test/integration

    # Core DI container
    cat > lib/di/injection_container.dart << 'DART'
import 'package:get_it/get_it.dart';

final sl = GetIt.instance;

Future<void> initDependencies() async {
  // Core services
  // Features — register in dependency order
}
DART

    # App entry
    cat > lib/main.dart << 'DART'
import 'package:flutter/material.dart';
import 'app.dart';
import 'di/injection_container.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initDependencies();
  runApp(const HealthApp());
}
DART

    cat > lib/app.dart << 'DART'
import 'package:flutter/material.dart';

class HealthApp extends StatelessWidget {
  const HealthApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Health App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.cyan,
        useMaterial3: true,
      ),
      home: const Scaffold(
        body: Center(child: Text('Health App', style: TextStyle(fontSize: 24))),
      ),
    );
  }
}
DART

    echo "[scaffold-mobile] ✓ Flutter project ready at: $TARGET_DIR"
    echo "  Run: cd $TARGET_DIR && flutter run"
    echo "  Architecture: feature-first clean (BLoC + GetIt + GoRouter + Dio)"
fi

# ─── REACT NATIVE (fallback) ──────────────────────────────
if [[ "$MODE" == "react-native" ]]; then
    if ! command -v npx &>/dev/null; then
        echo "[ERROR] Node.js/npx not found."
        exit 1
    fi

    npx create-expo-app@latest "$TARGET_DIR" --template blank-typescript --yes 2>/dev/null || {
        mkdir -p "$TARGET_DIR"
    }

    cd "$TARGET_DIR"
    npm install --save expo-router expo-linking expo-status-bar @react-navigation/native @react-navigation/bottom-tabs zustand axios 2>/dev/null || true
    npm install --save-dev @types/react @types/react-native jest @testing-library/react-native 2>/dev/null || true

    mkdir -p app src/components src/screens src/hooks src/services src/state src/utils
    echo "[scaffold-mobile] ✓ React Native project ready at: $TARGET_DIR"
fi

echo "[scaffold-mobile] Done"
