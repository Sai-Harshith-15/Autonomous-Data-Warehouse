import sys, os
# Strip Hermes venv from sys.path (PYTHONPATH isolation)
hermes_paths = [p for p in sys.path if 'hermes' in p.lower()]
for p in hermes_paths: sys.path.remove(p)
# Add backend to path for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'backend'))
