"""Exercise the same bounded native process runner used by recovery UI."""
from pathlib import Path
import subprocess
import tempfile

root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="lightisle-recovery-runner-") as temp:
    binary=Path(temp)/"runner-tests"
    subprocess.run(["swiftc","-swift-version","5","-parse-as-library",
        str(root/"apps/macos/Sources/LightIsle/OfflineRecoveryRunner.swift"),
        str(root/"tests/OfflineRecoveryRunnerTests.swift"),"-o",str(binary)],check=True,timeout=60)
    subprocess.run([str(binary)],check=True,timeout=15)
