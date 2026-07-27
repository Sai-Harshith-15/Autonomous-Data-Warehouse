import sys, os

# Remove Hermes venv from sys.path — it injects broken pydantic_core
# into every Python process via PYTHONPATH/sitecustomize
hermes_paths = [p for p in sys.path if 'hermes' in p.lower()]
for p in hermes_paths:
    sys.path.remove(p)

# Ensure project root is on sys.path for 'from main import app'
project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if project_root not in sys.path:
    sys.path.insert(0, project_root)
