"""Exercise the native root model without opening a window or touching user data."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="lightisle-root-model-") as temporary:
    binary = Path(temporary) / "root-model-regression"
    subprocess.run([
        "swiftc", "-swift-version", "5", "-parse-as-library",
        str(ROOT / "apps/macos/Sources/LightIsle/RootManagement.swift"),
        str(ROOT / "tests/RootManagementRegression.swift"), "-o", str(binary),
    ], check=True, cwd=ROOT)
    subprocess.run([str(binary)], check=True, cwd=ROOT)
